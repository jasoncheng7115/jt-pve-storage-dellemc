# 命名慣例

English: [NAMING_CONVENTIONS.md](NAMING_CONVENTIONS.md)

命名規則實作於 `Common::Naming`，PowerStore 的限制在 `PowerStore::Naming`。`t/01-naming.t` 涵蓋雙向轉換與歸屬檢查。

## 前綴隔離

外掛在儲存伺服器上建立的每個物件都以 `<前置字串>-<storeid>-` 命名，而**除非該 storage 設定了 `dell-name-prefix`，否則前置字串就是 `pve`**。所有列舉、刪除與清理路徑都先以此前綴過濾。沒有這個前綴的物件一律不讀取、不改名、不刪除 —— 這是讓外掛能與其他工作負載共用同一台儲存伺服器的安全邊界。

以下表格一律使用 `pve`，那是從未設定過這個選項的 storage 所使用的值，也就是目前每一個既有安裝的值。

### 為什麼前置字串可以設定

命名空間是 **storage id**，所以兩個都把 storage 取名為 `ps1` 的 Proxmox 叢集，對同一個 VMID 會產生相同的名稱，共用每一個磁碟區，兩邊都會列出對方的磁碟。在同一個叢集內，外掛會拒絕兩個會撞名的 storage；但它讀的是本機的 `storage.cfg`，看不到另一個叢集。

`dell-name-prefix` 把它們分開。Kubernetes CSI 針對同一個問題採用的是同樣的解法：`external-provisioner` 有 `--volume-name-prefix` 參數，預設為 `pvc`。

這個前置字串**刻意不從叢集名稱推導**。推導出來的名稱勢必要截斷才塞得進 PowerVault 的 32 字元上限，而兩個截斷後相同的叢集名稱會再次撞名，卻看起來像是已經解決了。

## 從「前置字串還不可設定」的版本升級

**什麼都不會變，也什麼都不用做。** 沒有 `dell-name-prefix` 的 storage 會解析成 `pve`，也就是這個選項存在之前外掛寫死的那個字串，所以儲存伺服器上既有的每一個磁碟區都保持原名、也仍然被認得。這一點由生命週期測試驗證（那些測試從頭到尾用的都是舊名稱），另外還有一個測試專門斷言「預設值與舊有字串逐位元組相同」。

具體來說，在 0.8.29 以後的外掛上：

| 由舊版建立的物件 | 是否仍被認得 |
|---|---|
| `pve-ps1-100-disk0` | 是，視為 VM 磁碟 |
| `pve-ps1-100-efidisk0`、`-tpmstate0`、`-cloudinit` | 是 |
| `pve-ps1-100-vmconf-before` | 是，視為設定備份 |
| `pve-ps1-100-disk0.pve-snap-before` | 是，視為快照 |
| `pve-ps1-100-disk0.pve-base` | 是，視為範本標記 |

沒有任何路徑會在無人值守的情況下動到舊磁碟區。孤兒回收器只處理節點自己的裝置，從不刪除儲存伺服器上的磁碟區；暫時複製回收器依據的是外掛自己寫下的狀態檔，而舊磁碟區不在其中；每 VM 一個 volume group 預設關閉，而且不會把既有磁碟區追溯加入群組。

升級之後有兩件事的行為會不同，而兩者都是修正：

- **第一次使用時可能會建立 multipath map。** 舊版可能接受單一的 `/dev/sdX`，讓客體沒有任何路徑備援。從 0.8.28 起會認領 WWID 並等待 map 出現。在日誌中看到對既有磁碟區執行 `multipath -a`，是預期的。
- **加入既有 storage 時會警告該前綴下已經有磁碟區。** 那是跨叢集檢查；對於你自己重新加入的 storage，這是預期的，訊息裡也寫明了這種讀法。

**不要對已經有磁碟區的 storage 設定 `dell-name-prefix`。** 那會讓外掛再也找不到它們。`pvesm set` 正是因此會拒絕；前置字串只能在建立 storage 時決定。

## 對照表

| PVE 物件 | 儲存伺服器物件 | 命名樣式 |
|---|---|---|
| VM 磁碟 | Volume | `pve-{storeid}-{vmid}-disk{n}` |
| Container rootfs | Volume | `pve-{storeid}-{vmid}-disk{n}` |
| Cloud-init | Volume | `pve-{storeid}-{vmid}-cloudinit` |
| EFI disk | Volume | `pve-{storeid}-{vmid}-efidisk{n}` |
| TPM state | Volume | `pve-{storeid}-{vmid}-tpmstate{n}` |
| RAM state（vmstate） | Volume | `pve-{storeid}-{vmid}-state-{snapname}` |
| VM 設定備份 | Volume（1 MB、ext4） | `pve-{storeid}-{vmid}-vmconf-{snapname}`（僅 PowerStore） |
| 快照 | Volume snapshot | `{volume}.pve-snap-{snapname}` |
| 範本標記 | Volume snapshot | `{volume}.pve-base` |
| PVE 節點 | Host | `pve-{cluster}-{node}` |
| 共享 host | Host group | `pve-{cluster}-shared` |

名稱中的 storeid 會先經過清洗：`[A-Za-z0-9_-]` 以外的字元變成 `_`，連字號也變成底線。底線轉換的用意，是避免某個儲存的前綴包含另一個儲存的前綴 —— 否則 `ps` 與 `ps-1` 會得到 `pve-ps-` 與 `pve-ps-1-`，儲存 `ps` 就會把 `ps-1` 的 volume 當成自己的。

**那個折疊是有損的，而本外掛選擇拒絕它的後果，而不是與它共存。** `ps-1`、`ps.1`、`ps+1`、`ps@1`、`ps__1` 全都會變成 `ps_1`；`ps1_`、`_ps1`、`ps1!` 也全都變成 `ps1`。兩個這樣的儲存放在同一台儲存伺服器上，會共用**每一個** volume 名稱：彼此都會列出對方的磁碟，從其中一個刪除磁碟就等於從另一個刪除，而且所有權閘門對兩者都會通過。

這在名稱裡無法修 —— PowerVault 的整個 volume 名稱只有 32 個字元、PowerFlex 只有 31，沒有多餘的空間可用。因此改由 `on_add_hook` 拒絕建立「前綴與既有儲存相同」的儲存，並指名是與哪一個相撞、以及該改什麼。在那個當下 storage id 還可以自由更改；一個已經存放了 volume 的儲存則不然。

PowerStore 自身的名稱長度與字元限制仍待實機確認，請見 [TESTING_zh-TW.md](TESTING_zh-TW.md)。

## 儲存伺服器上原本就有的 host 物件

上面那個名稱是外掛**產生**的名稱，不一定是它實際使用的名稱：在外掛跑起來之前，儲存伺服器上
通常每台節點都已經有一個 host 物件，以它自己的命名持有該節點的 initiator，而一個
initiator 只能屬於一個 host 物件。

在 PowerStore 上，當產生的名稱底下沒有 host 時，外掛會問儲存伺服器「本節點的 initiator 在哪
個 host 上」，改用那一個 —— 並記錄在 `/var/lib/pve-storage-dellemc/{storeid}-host`，
這是節點本機的檔案，因為一個 host 物件代表的就是一台節點。它只會採用 initiator 是本節點
子集的 host；細節見 `docs/CONFIGURATION_zh-TW.md`。

產生的形式對叢集仍然重要：磁碟區要預先對應到其他節點，是以 `pve-{叢集}-` 前置字串搜尋
的。採用了別的名稱的節點不會被別處預先對應 —— 它會在自己啟用儲存時完成對應，而那發生在
遷移完成之前。

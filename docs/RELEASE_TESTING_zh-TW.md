# 發布前測試計畫

English: [RELEASE_TESTING.md](RELEASE_TESTING.md)

每次發布之前都要先跑完這份計畫。第 1〜3 階段不需要儲存伺服器，每次發布都必須全部通過，沒有例外。第 4 階段需要實機；在還沒有儲存伺服器可用的期間，請如實記錄為「未執行」，而不是默默跳過 —— 發行說明必須誠實反映「測了什麼」。

---

## 第 1 階段 —— 自動化檢查

```bash
make release-check
```

它會執行下列項目，且必須全部通過：

| 檢查 | 能抓到什麼 |
|---|---|
| `make check-multipath-flush` | 全系統 flush 指令出現在專案任何位置 |
| `make syntax` | 無法編譯的模組 |
| `make unit` | 所有單元測試 |
| 版本一致性 | `Makefile`、`debian/changelog`、`bin/pve-dell-config-get` 三者版本不一致 |
| 變更紀錄 | `CHANGELOG.md` 或 `CHANGELOG_zh-TW.md` 缺少新版本的條目 |

另外請在**Proxmox VE 節點**上再跑一次 `make syntax`。在沒有 PVE 的機器上，繼承 `PVE::Storage::Plugin` 的模組會回報為「已跳過」—— 那是誠實的結果，但不是覆蓋率：

```bash
make syntax
# 在 PVE 節點上的預期結果：每個模組都是 "... OK"，沒有任何跳過
```

---

## 第 2 階段 —— 套件

```bash
make deb
dpkg-deb -c ../jt-pve-storage-dellemc_*_all.deb | grep -E 'perl5|bin/'
```

預期：四個 plugin 模組、`DellEMC/` 目錄樹，以及權限為 0755 的 `/usr/bin/pve-dell-config-get`。

```bash
dpkg-deb -I ../jt-pve-storage-dellemc_*_all.deb | grep -E 'Version|Depends'
```

預期：版本與 `debian/changelog` 相符，且 Depends 包含 `proxmox-ve`、四個 Perl 模組、`open-iscsi`、`multipath-tools`、`sg3-utils`、`psmisc`。

---

## 第 3 階段 —— 安裝到 Proxmox VE 節點

請使用一台**已經設定了其他儲存**的節點。這個階段的重點就是：安裝本套件不會對它們造成任何影響。

```bash
pvesm status > /tmp/before.txt          # 基準
apt install ./jt-pve-storage-dellemc_*_all.deb
```

預期：postinst 印出 multipath 安全規則、回報 iscsid 與 multipathd 狀態，並在無錯誤的情況下重載 PVE 服務。

### 3.1 既有儲存不受影響

```bash
pvesm status > /tmp/after.txt
diff /tmp/before.txt /tmp/after.txt
```

預期：沒有任何儲存改變狀態。若在此處發生 `duplicate property` 失敗，該節點上的**每一個**儲存都會停止運作，因此這個 diff 是整份計畫中最重要的一項檢查。

### 3.2 四個 type 都已註冊

```bash
perl -e 'use PVE::Storage;
  my $p = PVE::Storage::Plugin->private()->{plugins};
  print join(", ", grep { /dell/ } sort keys %$p), "\n";'
```

預期：`dellpowerflex, dellpowerstore, dellpowervault`

### 3.3 Schema 驗證

```bash
pvesm add dellpowerstore t1
# 預期：missing value for required option 'dell-username'

pvesm add dellpowervault t2 --dell-portal 1.2.3.4 --dell-username u \
    --dell-password p --pvault-tier-affinity bogus
# 預期：value 'bogus' does not have a value in the enumeration

pvesm add dellpowerflex t3 --dell-portal 1.2.3.4 --dell-username u \
    --dell-password p
# 預期：missing value for required option 'pflex-storage-pool'

pvesm add dellpowerflex t4 --dell-portal 1.2.3.4 --dell-username u \
    --dell-password p --pflex-storage-pool p1 --pflex-nvme-ctrl-loss-tmo 9999
# 預期：value must have a maximum value of 600
```

### 3.4 儲存伺服器不可達時要乾淨地失敗

```bash
pvesm add dellpowerstore t5 --dell-portal 10.255.255.1 --dell-username u \
    --dell-password p --dell-status-timeout 2 --content images
```

預期：建立失敗，訊息中指出儲存名稱與位址，而且 `/etc/pve/storage.cfg` 中**不會**留下任何條目。

```bash
time pvesm status
```

預期：數秒內回應，且其他儲存全部維持 active。慢的儲存不可以餓死鄰居 —— 這正是 `dell-status-timeout` 存在的目的。

### 3.5 災難復原工具

```bash
pve-dell-config-get --help
pve-dell-config-get nosuchstore 100
# 預期：指出儲存名稱，並建議改用 recover 模式
```

---

## 第 4 階段 —— 實機

依系列進行，只有搭配真實儲存伺服器才有意義。完整的 26 項矩陣在 [TESTING_zh-TW.md](TESTING_zh-TW.md)：某個系列首次發布時請跑完整份矩陣；若該版本只改動共用程式碼，跑下列子集即可。

### 4.1 共用程式碼變更的子集

| # | 測試項 | 通過標準 |
|---|---|---|
| 1 | `pvesm status` | 容量與儲存伺服器自身 UI 的誤差在 1% 以內 |
| 2 | 建立磁碟 | 儲存伺服器上出現 volume，節點上出現裝置 |
| 3 | 寫入後讀回 | `dd` 寫入與讀出，checksum 相符 |
| 4 | 快照後還原 | 資料回到快照當下的狀態 |
| 5 | 從範本做連結複製 | 以秒計完成，不是以分鐘計 |
| 6 | 刪除磁碟 | volume 消失，且無殘留裝置或 map |
| 7 | 線上遷移 | 完成且 I/O 無中斷 |
| 8 | 拔掉一條路徑 | I/O 持續；該路徑顯示為失效 |
| 9 | 重開一台節點 | 自動登入且裝置自動出現 |

### 4.1a 由客戶的儲存伺服器找出、而主機端測不到的項目

這幾項列在這裡，是因為每一項都躲過了所有不涉及實機的測試，而且重跑的成本都很低。

| # | 測試項 | 通過標準 | 來源 |
|---|---|---|---|
| 10 | 在 `find_multipaths strict`（**預設值**）的節點上建立磁碟 | 不需要任何人手動去動 `/etc/multipath/wwids`，map 就會出現。確認 WWID 已被加入：`grep <wwid> /etc/multipath/wwids` | issue #6 |
| 11 | 對虛擬機建快照、刪快照，然後連續建立數顆磁碟 | 之後 `dmesg` 裡不應出現 `LUN assignments on this target have changed`。那句話代表有 sd 路徑活得比它的 LUN 久，而被重用的 ID 撞上了它 | issue #7 |
| 12 | 對啟用 guest agent 的**執行中**虛擬機建快照，並計時 | 客體失去回應的時間應遠小於一秒，而不是一次設定備份的長度。`qm snapshot` 何時返回不是判準，要在過程中持續 ping 客體 | issue #2 |
| 13 | 在 PowerStore Manager 刪掉一個磁碟區（讓它留在回收筒），再用同一個 VMID 建立虛擬機 | 配置應在下一個磁碟 ID 上成功。它不可以重試同一個名字；若真的失敗，訊息必須指出回收筒，而不是歸咎於其他節點 | issue #9 |
| 14 | 把一台 UEFI 虛擬機遷移到這個儲存 | EFI 磁碟要能建立。它是 540672 位元組，低於 PowerStore 的 1 MiB 下限，而且本來就是 8 KiB 的整數倍，所以只有下限救得了它 | issue #1 |
| 15 | 在一台屬於叢集的節點上執行 `pvesm add`，且**不加** `--dell-cluster-name` | 回頭看儲存設定，裡面應帶著 `corosync.conf` 中的真實叢集名稱。接著用 `pvesm set` 改一個不相干的選項，確認那個名稱**不會**變動：重新推導會讓儲存找不到自己的 host 物件 | issue #4 |
| 16 | 在沒有 `corosync.conf` 的單機節點上做同樣的事 | 儲存能被加入，並退回使用 `pve`。這不可以是錯誤 | issue #4 |

#### 4.1b 使用 `dell-host-mode host-group` 時

危險的是第三種情況。它沒有實機就測不出來，因為整個問題就在於「儲存伺服器怎麼描述
那些不是本外掛建立的 host」。

| # | 測試項 | 通過標準 |
|---|---|---|
| 17 | 在 host **不屬於任何群組**的節點上啟用 | 出現一個 `pve-<叢集>-cluster` 群組，本節點的 host 在裡面，而且它的描述帶有所有權標記 |
| 18 | 在**第二台**節點上啟用 | 它會加入同一個群組。不會建立第二個群組，而且兩台節點的 host 都是成員 |
| 19 | 在群組存在的狀態下建立磁碟 | 對應是建立在**群組**上，而不是 host 上。在 PowerStore Manager 中檢視該磁碟區，確認一次對應就涵蓋兩台節點 |
| 20 | **先把某台節點的 host 放進你自己建立的群組**，然後啟用 | 該 host 會**被留在你的群組裡**，不會有任何東西被移除，也不會為它建立我們的群組，而且日誌會說明一次。磁碟區仍然會被對應，透過你的群組 |
| 21 | 刪掉最後一個磁碟區，然後移除儲存 | 本外掛建立的群組可以被移除；**你**建立的群組永遠不會被動到，即使裡面每一台 host 都是我們的 |
| 22 | 讓儲存伺服器的管理介面斷線，然後啟用 | 啟用仍應成功，磁碟區仍應以逐 host 的方式對應。一個無法完成的分組步驟，絕不能讓佈建失敗 |

時間不夠時，第 20 項是最該先跑的。做錯會把一台 host 從某個群組裡拿出來，而那個群組
可能正把別人的生產儲存對應給它，而外掛沒有任何辦法把它放回去。

第 17、20、22 項可以先用 `t/fake/powerstore.py` 這個假儲存伺服器演練，它會強制執行
與真機相同的「一台 host 只能屬於一個群組」規則。它不能取代實機 —— 它證明的是外掛
**送出了什麼**、以及被拒絕時如何反應，而不是 PowerStore 實際會怎麼處理那個請求 ——
但發行前這幾條路徑就是這樣檢查的，而且它能立刻抓到往危險方向的退化。

### 4.2 各系列另需確認

**PowerStore** —— 反覆對應與解除對應 300 次之後，LUN ID 仍維持在低位且密集（這正是外掛要迴避的 Dell 缺陷）。

**PowerStore，且設定 `pstore-volume-group-per-vm 1`** —— 一台虛擬機的磁碟會落在同一個名為 `pve-<storeid>-<vmid>-vg` 的群組裡；設定備份磁碟區與任何暫時快照複製**不會**進去；刪除該虛擬機最後一顆磁碟時群組會被移除；而若在 PowerStore Manager 上替該群組掛了保護原則，同樣的刪除動作不會移除它，並且會記錄原因。用 `qm move_disk --target-vmid` 把磁碟改指派給另一台虛擬機，確認群組會跟著換。另外，把外掛的某個磁碟區放進你自己的群組，確認它仍然刪得掉：儲存伺服器會拒絕刪除仍是成員的磁碟區，所以一個外掛不肯移出的磁碟區，就是一個沒有人刪得掉的磁碟區。

**PowerVault ME** —— 使用長到會超過 32 bytes 的 storage id 時，建立階段就被拒絕並指出長度限制，而不是被截斷。

**PowerFlex** —— `nvme list-subsys` 顯示一個 subsystem 有多條路徑，ANA 狀態為 `optimized`／`non-optimized`，且 `cat /sys/module/nvme_core/parameters/multipath` 為 `Y`。若使用 SDC，則 `drv_cfg --query_vols` 應能列出該 volume。

### 4.3 長時間測試，僅在 1.0.0 之前

- 連續 72 小時的 pvestatd 輪詢，沒有誤報 `inactive`，journal 也沒有錯誤累積
- 管理網路中斷 10 分鐘後恢復：儲存自行回到 `active`，執行中的 VM 全程沒有 I/O 中斷

---

## 第 5 階段 —— 發布

只有在第 1〜3 階段全數通過，且第 4 階段已完成或明確記錄為未執行之後，才進行發布。

```bash
# 1. 版本。小版號逐次遞增，到 .99 才進位到次版號：
#    0.7.0、0.7.1、……、0.7.99，然後 0.8.0。
#    以下三處要同步更新：
#      Makefile                 VERSION
#      debian/changelog         最上方新增一則條目
#      bin/pve-dell-config-get  $VERSION
#
# 2. 變更紀錄，**兩種語言都要**
#      CHANGELOG.md  CHANGELOG_zh-TW.md
#
# 3. 帶著新版本再跑一次檢查
make release-check

# 4. 建置並把套件保留在 repository 中。每一版都要留著：
#    releases/ 就是封存區，測試者才能取得他手上正在跑的那一份建置。
#    只新增檔案，絕不取代舊的。
make deb
cp ../jt-pve-storage-dellemc_<version>_all.deb releases/

# 5. Commit、打 tag、推送
git add -A && git commit
git tag -a v<version> -m 'Release <version>'
git push origin main --tags
```

推送 tag 同時會觸發 GitHub release，附上相同的 `.deb` 與 `SHA256SUMS`。若 tag 與 `debian/changelog` 的版本不一致，workflow 會拒絕發布。

### 發布之後

```bash
# 在節點上安裝「已發布的套件」，而不是本地建置的版本
apt install ./jt-pve-storage-dellemc_<version>_all.deb
pvesm status        # 每個儲存都仍為 active
```

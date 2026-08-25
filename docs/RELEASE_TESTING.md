# Release Test Plan

繁體中文：[RELEASE_TESTING_zh-TW.md](RELEASE_TESTING_zh-TW.md)

Every release runs this plan first. Stages 1 to 3 need no array and must pass
on every release without exception. Stage 4 needs hardware; while no array is
available, record it as not executed rather than skipping it silently — the
release notes have to stay honest about what was tested.

---

## Stage 1 — Automated checks

```bash
make release-check
```

That runs, and must all pass:

| Check | What it catches |
|---|---|
| `make check-multipath-flush` | the system-wide flush appearing anywhere in the tree |
| `make syntax` | a module that will not compile |
| `make unit` | every unit test |
| version consistency | `Makefile`, `debian/changelog` and `bin/pve-dell-config-get` disagreeing |
| changelog presence | the new version missing from `CHANGELOG.md` or `CHANGELOG_zh-TW.md` |

Run `make syntax` on a **Proxmox VE node** as well. On a machine without PVE
the modules that subclass `PVE::Storage::Plugin` report as skipped, which is
honest but not coverage:

```bash
make syntax
# Expected on a PVE node: every module "... OK", nothing skipped
```

---

## Stage 2 — Package

```bash
make deb
dpkg-deb -c ../jt-pve-storage-dellemc_*_all.deb | grep -E 'perl5|bin/'
```

Expected: the four plugin modules, the `DellEMC/` tree, and
`/usr/bin/pve-dell-config-get` at mode 0755.

```bash
dpkg-deb -I ../jt-pve-storage-dellemc_*_all.deb | grep -E 'Version|Depends'
```

Expected: the version matches `debian/changelog`, and Depends lists
`proxmox-ve`, the four Perl modules, `open-iscsi`, `multipath-tools`,
`sg3-utils`, `psmisc`.

---

## Stage 3 — Install on a Proxmox VE node

Use a node that already has other storages configured. The point of this
stage is that installing the package changes nothing for them.

```bash
pvesm status > /tmp/before.txt          # baseline
apt install ./jt-pve-storage-dellemc_*_all.deb
```

Expected: postinst prints the multipath safety rules, reports iscsid and
multipathd, and reloads the PVE services without error.

### 3.1 Existing storages are unaffected

```bash
pvesm status > /tmp/after.txt
diff /tmp/before.txt /tmp/after.txt
```

Expected: no storage changed state. A `duplicate property` failure at this
point takes down **every** storage on the node, so this diff is the single
most important check in the whole plan.

### 3.2 All four types register

```bash
perl -e 'use PVE::Storage;
  my $p = PVE::Storage::Plugin->private()->{plugins};
  print join(", ", grep { /dell/ } sort keys %$p), "\n";'
```

Expected: `dellpowerflex, dellpowerstore, dellpowervault`

### 3.3 Schema validation

```bash
pvesm add dellpowerstore t1
# Expected: missing value for required option 'dell-username'

pvesm add dellpowervault t2 --dell-portal 1.2.3.4 --dell-username u \
    --dell-password p --pvault-tier-affinity bogus
# Expected: value 'bogus' does not have a value in the enumeration

pvesm add dellpowerflex t3 --dell-portal 1.2.3.4 --dell-username u \
    --dell-password p
# Expected: missing value for required option 'pflex-storage-pool'

pvesm add dellpowerflex t4 --dell-portal 1.2.3.4 --dell-username u \
    --dell-password p --pflex-storage-pool p1 --pflex-nvme-ctrl-loss-tmo 9999
# Expected: value must have a maximum value of 600
```

### 3.4 An unreachable array fails cleanly

```bash
pvesm add dellpowerstore t5 --dell-portal 10.255.255.1 --dell-username u \
    --dell-password p --dell-status-timeout 2 --content images
```

Expected: creation fails with a message naming the storage and the address,
and **no** entry is left in `/etc/pve/storage.cfg`.

```bash
time pvesm status
```

Expected: answers in a couple of seconds and every other storage is still
active. A slow storage must not starve its neighbours — that is what
`dell-status-timeout` exists for.

### 3.5 The recovery tool

```bash
pve-dell-config-get --help
pve-dell-config-get nosuchstore 100
# Expected: names the storage, and suggests recover mode
```

---

## Stage 4 — On hardware

Per family, and only meaningful with a real array. The full 26-item matrix is
in [TESTING.md](TESTING.md); run it in full for a family the first time that
family is released, and run the subset below for a release that only changes
shared code.

### 4.1 Subset for a shared-code change

| # | Test | Pass criteria |
|---|---|---|
| 1 | `pvesm status` | capacity matches the array's own UI within 1% |
| 2 | Create a disk | volume on the array, device on the node |
| 3 | Write and read back | `dd` in and out, checksums match |
| 4 | Snapshot, then roll back | data returns to the snapshot state |
| 5 | Linked clone from a template | completes in seconds, not minutes |
| 6 | Delete the disk | volume gone, no device or map left behind |
| 7 | Live migration | completes with no I/O interruption |
| 8 | Pull one path | I/O continues; the path shows as failed |
| 9 | Reboot a node | logs in and devices reappear automatically |

### 4.1a Cases a customer's array found, and the host side did not

These are here because each was invisible to every test that did not involve
real hardware, and each is cheap to repeat.

| # | Test | Pass criteria | From |
|---|---|---|---|
| 10 | On a node with the DEFAULT `find_multipaths strict`, create a disk | a map appears without anyone touching `/etc/multipath/wwids` by hand. Confirm the WWID was added: `grep <wwid> /etc/multipath/wwids` | issue #6 |
| 11 | Snapshot a VM, then delete the snapshot, then create several more disks | no `LUN assignments on this target have changed` in `dmesg` afterwards. That message means an sd path outlived its LUN and a reused id ran into it | issue #7 |
| 12 | Snapshot a RUNNING VM with the guest agent enabled, timing it | the guest is unresponsive for well under a second, not for the length of a config backup. `qm snapshot` returning is not the measure; ping the guest through it | issue #2 |
| 13 | Delete a volume in PowerStore Manager, leaving it in the recycle bin, then create a VM with that VMID | the allocation succeeds on the next disk id. It must not retry the same name, and any failure must name the recycle bin rather than blaming other nodes | issue #9 |
| 14 | Migrate a UEFI VM onto the storage | the EFI disk is created. It is 540672 bytes, which is below PowerStore's 1 MiB minimum and already 8 KiB aligned, so only the floor saves it | issue #1 |
| 15 | `pvesm add` a storage on a node that is in a cluster, without `--dell-cluster-name` | the storage config comes back carrying the cluster's real name from `corosync.conf`. Then `pvesm set` something unrelated and confirm the name does **not** change: re-deriving it would make the storage stop finding its host object | issue #4 |
| 16 | The same on a standalone node, which has no `corosync.conf` | the storage is added and falls back to `pve`. This must not be an error | issue #4 |

#### 4.1b With `dell-host-mode host-group`

The dangerous case is the third one. It cannot be exercised without an array
because the whole question is what the array reports about hosts it did not
get from this plugin.

| # | Test | Pass criteria |
|---|---|---|
| 17 | Activate on a node whose host is in **no** group | a group `pve-<cluster>-cluster` appears, this node's host is in it, and its description carries the ownership marker |
| 18 | Activate the **second** node | it joins the same group. No second group is created, and both nodes' hosts are members |
| 19 | Create a disk while the group exists | the mapping is made to the GROUP, not the host. `show` the volume in PowerStore Manager and confirm one mapping covers both nodes |
| 20 | **Put a node's host into a group of your own first**, then activate | the host is **left in your group**, nothing is removed from it, no group of ours is created for that host, and the journal says so once. Volumes are still mapped, through your group | 
| 21 | Delete the last volume, then remove the storage | the group this plugin created may be removed; a group **you** created is never touched, even if every host in it is ours |
| 22 | Take the array's management interface down, then activate | activation still succeeds and volumes still map per host. A grouping step that cannot complete must never fail provisioning |

Test 20 is the one to run first if time is short. Getting it wrong takes a
host out of a group that may be mapping somebody else's production storage to
it, and the plugin has no way to put that back.

Tests 17, 20 and 22 can be rehearsed without an array using the fake in
`t/fake/powerstore.py`, which enforces the one-group-per-host rule the real
array does. That is not a substitute for the array — it proves what the plugin
sends and how it reacts to a refusal, not what a PowerStore actually does with
the request — but it is how these paths were checked before release, and it
catches a regression in the dangerous direction immediately.

### 4.2 Per family, additionally

**PowerStore** — after 300 attach/detach cycles, LUN ids are still low and
dense (this is the Dell defect the plugin works around).

**PowerStore, with `pstore-volume-group-per-vm 1`** — a VM's disks land in one
group named `pve-<storeid>-<vmid>-vg`; the config backup volume and any
temporary snapshot clone do NOT; deleting the VM's last disk removes the group;
and a group with a protection policy attached in PowerStore Manager survives
the same deletion, with the reason logged. Reassign a disk to another VM
(`qm move_disk --target-vmid`) and confirm it moves group. Put one of the
plugin's volumes into a group of your own and confirm it can still be deleted:
the array refuses to delete a member, so a volume it will not remove is a
volume nobody can delete.

**PowerVault ME** — a storage id long enough to overflow 32 bytes is refused
at creation with a message naming the limit, not truncated.

**PowerFlex** — `nvme list-subsys` shows one subsystem with several paths in
`optimized`/`non-optimized` ANA state, and
`cat /sys/module/nvme_core/parameters/multipath` is `Y`. With SDC instead,
`drv_cfg --query_vols` lists the volume.

### 4.3 Soak, before 1.0.0 only

- 72 hours of pvestatd polling with no false `inactive` and no error
  accumulation in the journal
- management network cut for 10 minutes and restored: the storage returns to
  `active` on its own and running VMs see no I/O interruption

---

## Stage 5 — Publish

Only after stages 1 to 3 pass and stage 4 is either done or explicitly
recorded as not executed.

```bash
# 1. Version. The patch number increments per release and runs to .99
#    before the minor number moves: 0.7.0, 0.7.1, ... 0.7.99, then 0.8.0.
#    Update all three, in step:
#      Makefile                 VERSION
#      debian/changelog         a new entry at the top
#      bin/pve-dell-config-get  $VERSION
#
# 2. Changelog, in BOTH languages
#      CHANGELOG.md  CHANGELOG_zh-TW.md
#
# 3. Re-run the checks with the new version in place
make release-check

# 4. Build and keep the package in the repository. Every release stays:
#    releases/ is the archive, so a tester can fetch exactly the build
#    they are running. Add the new file, never replace the old one.
make deb
cp ../jt-pve-storage-dellemc_<version>_all.deb releases/

# 5. Commit, tag, push
git add -A && git commit
git tag -a v<version> -m 'Release <version>'
git push origin main --tags
```

The tag also triggers a GitHub release with the same `.deb` and a
`SHA256SUMS` attached. The workflow refuses to publish when the tag and
`debian/changelog` disagree.

### After publishing

```bash
# On a node, install the published package rather than a local build
apt install ./jt-pve-storage-dellemc_<version>_all.deb
pvesm status        # every storage still active
```

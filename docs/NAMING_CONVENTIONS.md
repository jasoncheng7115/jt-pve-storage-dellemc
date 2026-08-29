# Naming Conventions

繁體中文：[NAMING_CONVENTIONS_zh-TW.md](NAMING_CONVENTIONS_zh-TW.md)

Implemented in `Common::Naming`, with the PowerStore limits in
`PowerStore::Naming`. `t/01-naming.t` covers the round trips and the
ownership gate.

## Prefix isolation

Every object the plugin creates on the array is named
`<prefix>-<storeid>-...`, where the prefix is **`pve` unless the storage sets
`dell-name-prefix`**. Every list, delete and cleanup path filters on that
prefix first. Objects that do not carry it are never read, renamed or deleted —
this is the safety boundary that lets the plugin share an array with other
workloads.

The tables below use `pve`, which is what a storage that has never set the
option uses, and therefore what every existing installation has.

### Why the prefix is configurable

The namespace is the **storage id**, so two Proxmox clusters that both call a
storage `ps1` produce the same names for the same VMID and share every volume.
Each would list the other's disks. Within one cluster the plugin refuses two
storages that would collide; it reads the local `storage.cfg` and cannot see
another cluster.

`dell-name-prefix` separates them. Kubernetes CSI solved the identical problem
the same way: `external-provisioner` takes `--volume-name-prefix`, defaulting
to `pvc`.

The prefix is **not** derived from the cluster name, deliberately. A derived
name would have to be truncated to fit PowerVault's 32-character limit, and two
clusters whose names truncate alike would collide again while appearing not to.

## Upgrading from a version before the prefix was configurable

**Nothing changes and nothing needs doing.** A storage with no
`dell-name-prefix` resolves to `pve`, which is the literal the plugin used
before the option existed, so every volume already on the array keeps its name
and stays recognised. This is verified by the lifecycle tests, which use the
old names throughout, and by a test that asserts the default is byte-identical
to the old literal.

Concretely, on a plugin at 0.8.29 or later:

| Object created by an older version | Still recognised |
|---|---|
| `pve-ps1-100-disk0` | yes, as a VM disk |
| `pve-ps1-100-efidisk0`, `-tpmstate0`, `-cloudinit` | yes |
| `pve-ps1-100-vmconf-before` | yes, as a config backup |
| `pve-ps1-100-disk0.pve-snap-before` | yes, as a snapshot |
| `pve-ps1-100-disk0.pve-base` | yes, as a template marker |

Nothing acts on old volumes unattended. The orphan reaper touches only the
node's own devices and never deletes an array volume; the temporary-clone
reaper works from a state file this plugin wrote, which old volumes are not in;
and per-VM volume groups are off by default and never add existing volumes
retroactively.

Two things do behave differently after an upgrade, and both are fixes:

- **A multipath map may be built on first use.** Older versions could accept a
  single `/dev/sdX` and leave the guest with no failover. From 0.8.28 the WWID
  is claimed and the map is waited for. Seeing `multipath -a` in the journal
  for an existing volume is expected.
- **Adding an existing storage warns that volumes already exist** under its
  prefix. That is the cross-cluster check; for a storage you are re-adding it
  is expected, and the message says so.

**Do not set `dell-name-prefix` on a storage that already has volumes.** It
would leave the plugin unable to find any of them. `pvesm set` refuses it for
that reason; the prefix can only be chosen when the storage is created.

## Mapping

| PVE object | Array object | Name pattern |
|---|---|---|
| VM disk | Volume | `pve-{storeid}-{vmid}-disk{n}` |
| Container rootfs | Volume | `pve-{storeid}-{vmid}-disk{n}` |
| Cloud-init | Volume | `pve-{storeid}-{vmid}-cloudinit` |
| EFI disk | Volume | `pve-{storeid}-{vmid}-efidisk{n}` |
| TPM state | Volume | `pve-{storeid}-{vmid}-tpmstate{n}` |
| RAM state (vmstate) | Volume | `pve-{storeid}-{vmid}-state-{snapname}` |
| VM config backup | Volume (1 MB, ext4) | `pve-{storeid}-{vmid}-vmconf-{snapname}` (PowerStore only) |
| Snapshot | Volume snapshot | `{volume}.pve-snap-{snapname}` |
| Template marker | Volume snapshot | `{volume}.pve-base` |
| PVE node | Host | `pve-{cluster}-{node}` — or the name of an existing host object the array already had for this node, see below |
| Shared host | Host group | `pve-{cluster}-shared` |

The storeid inside a name is sanitized: characters outside `[A-Za-z0-9_-]`
become `_`, and hyphens become underscores. The underscore conversion is what
keeps one storage's prefix from containing another's — `ps` and `ps-1` would
otherwise yield `pve-ps-` and `pve-ps-1-`, and storage `ps` would claim
`ps-1`'s volumes.

**That folding is lossy, and the plugin refuses the consequence rather than
living with it.** `ps-1`, `ps.1`, `ps+1`, `ps@1` and `ps__1` all become
`ps_1`; so do `ps1_`, `_ps1` and `ps1!` become `ps1`. Two such storages on one
array would share every volume name: each would list the other's disks, and
deleting a disk from one would delete it from the other, with the ownership
gate passing for both.

It cannot be fixed inside the name — PowerVault allows 32 characters for a
whole volume name and PowerFlex 31, and there is nothing to spend. So
`on_add_hook` refuses to create a storage whose prefix matches one that
already exists, naming the other storage and what to change. The storage id is
free at that moment; a storage that already holds volumes is not.

PowerStore's own name length and character limits are still to be confirmed
against hardware; see [TESTING.md](TESTING.md).

## A host object the array already had

The name above is what this plugin GENERATES. It is not always the name it
uses: an array usually has a host object for each node before the plugin ever
runs, holding that node's initiators under a name of its own, and an initiator
belongs to only one host object.

On PowerStore, when there is no host under the generated name, the plugin asks
which host holds this node's initiators and uses that one — recording it in
`/var/lib/pve-storage-dellemc/{storeid}-host`, which is node-local because a
host object represents one node. It adopts only a host whose initiators are a
subset of this node's; see `docs/CONFIGURATION.md`.

The generated form still matters for the cluster: volumes are pre-mapped to
the other nodes by searching for the `pve-{cluster}-` prefix. A node whose host
was adopted under another name is not pre-mapped from elsewhere — it maps
itself when it activates the storage, which happens before a migration
completes.

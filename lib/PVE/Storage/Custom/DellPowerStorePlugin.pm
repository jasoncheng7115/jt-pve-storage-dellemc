# Dell PowerStore storage plugin for Proxmox VE
# Copyright (c) 2026 Jason Cheng (Jason Tools)
# Licensed under the MIT License

package PVE::Storage::Custom::DellPowerStorePlugin;

use strict;
use warnings;

use base qw(PVE::Storage::Custom::DellEMC::Common::BlockBase);

use Time::Local ();

use PVE::Storage::Custom::DellEMC::PowerStore::API;
use PVE::Storage::Custom::DellEMC::PowerStore::Naming;
use PVE::Storage::Custom::DellEMC::Common::FC qw(get_fc_wwpns);
use PVE::Storage::Custom::DellEMC::Common::ISCSI qw(get_initiator_name);

# The PowerStore half of the plugin: everything here is about translating
# between the array's REST objects and what BlockBase asks for. The host-side
# work — device discovery, multipath, orphan reaping — lives in BlockBase and
# the Common modules.
#
# PowerStore addresses objects by id while PVE and BlockBase work in names,
# so most methods here start by resolving a name to an id.

# PVE marks a storage type as shared-capable through this list. Without it the
# GUI refuses to set 'shared 1', which live migration needs.
push @PVE::Storage::Plugin::SHARED_STORAGE, 'dellpowerstore';

sub type { 'dellpowerstore' }

sub naming { 'PVE::Storage::Custom::DellEMC::PowerStore::Naming' }

# NOT YET VERIFIED against hardware. Confirm the exact strings with
#   sg_inq /dev/sdX
# or `multipathd show config`, and narrow this before relying on it; the
# vendor gate decides which devices the plugin will ever touch.
sub multipath_vendor  { 'DellEMC' }
sub multipath_product { 'PowerStore' }

# Dell's Linux host connectivity guidance for PowerStore. Every value here
# still needs checking against the current guide for the firmware in use.
# multipath-tools ships a built-in for DellEMC/PowerStore: group_by_prio,
# prio alua, failback immediate, no_path_retry 3, fast_io_fail_tmo 15 - and
# no hardware_handler. PowerStore is a true ALUA array, so unlike Unity
# (whose CLARiiON-family built-in this plugin must follow), every deviation
# below is a same-category tuning choice, not a correction: a longer
# no_path_retry so a brief SP outage does not fail a guest's I/O, a shorter
# fast_io_fail so path failover starts sooner, and the explicit alua
# handler the kernel would auto-attach anyway.
sub multipath_defaults {
    return {
        path_selector        => 'queue-length 0',
        path_grouping_policy => 'group_by_prio',
        prio                 => 'alua',
        hardware_handler     => '1 alua',
        failback             => 'immediate',
        # Never 'queue': with every path down, queued I/O that can never
        # complete puts processes into uninterruptible sleep and the node
        # needs a reboot.
        no_path_retry        => 30,
        fast_io_fail_tmo     => 5,
        dev_loss_tmo         => 60,
        detect_prio          => 'yes',
        rr_min_io_rq         => 1,
        max_sectors_kb       => 1024,
    };
}

sub multipath_config_version { 1 }

sub capacity_scope { 'array' }

# PowerStore volumes are thin, always: the array has no thick provisioning to
# ask for, so an unwritten region reads as zeroes.
sub new_volumes_read_as_zeroes { return 1 }

sub identity_suffix {
    my ($class, $scfg) = @_;
    return $scfg->{'pstore-appliance'} // '';
}

# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------

sub family_properties {
    return {
        'pstore-appliance' => {
            description => "Name or id of the appliance new volumes are placed"
                . " on, in a multi-appliance cluster. Leave unset to let"
                . " PowerStore choose.",
            type => 'string',
            optional => 1,
        },
        'pstore-volume-group' => {
            description => "Place every volume of this storage in the named"
                . " volume group, which gives them a namespace on the array"
                . " and lets protection policies apply to them as a unit. The"
                . " group must already exist. Mutually exclusive with"
                . " 'pstore-volume-group-per-vm': a PowerStore volume belongs"
                . " to at most one volume group, so both are claiming the same"
                . " slot.",
            type => 'string',
            optional => 1,
        },
        'pstore-volume-group-per-vm' => {
            description => "Put each VM's disks in a volume group of their own,"
                . " created and removed by this plugin, so that array-side"
                . " protection policies and consistent group snapshots can be"
                . " applied per VM from PowerStore Manager. Off by default:"
                . " a volume belongs to at most one volume group, so turning"
                . " this on claims a slot an operator may be using. It applies"
                . " to disks created from that point on and never moves"
                . " existing volumes, and only ever touches groups this plugin"
                . " created. Auxiliary objects (the config backup volume, the"
                . " temporary clones used to read a snapshot) are left out of"
                . " the groups.",
            type => 'boolean',
            default => 0,
            optional => 1,
        },
        'pstore-performance-policy' => {
            description => "Performance policy applied to new volumes.",
            type => 'string',
            enum => ['High', 'Medium', 'Low'],
            default => 'Medium',
            optional => 1,
        },
        'pstore-protection-policy' => {
            description => "Protection policy (snapshot and replication rules)"
                . " applied to new volumes. The policy must already exist on"
                . " the array.",
            type => 'string',
            optional => 1,
        },
        'pstore-lun-id-base' => {
            description => "Lowest LUN id this plugin assigns when attaching a"
                . " volume. The plugin assigns LUN ids itself because"
                . " PowerStore's automatic REST-side sequence starts at 200 and"
                . " never reuses an id, which eventually exceeds what the host"
                . " scans. Raise this only if something else on the array"
                . " already uses the low ids on these hosts.",
            type => 'integer',
            minimum => 1,
            maximum => 200,
            default => 1,
            optional => 1,
        },
    };
}

sub family_options {
    return {
        'pstore-appliance'          => { optional => 1 },
        'pstore-volume-group'        => { optional => 1 },
        'pstore-volume-group-per-vm' => { optional => 1 },
        'pstore-performance-policy' => { optional => 1 },
        'pstore-protection-policy'  => { optional => 1 },
        'pstore-lun-id-base'        => { optional => 1 },
    };
}

# ---------------------------------------------------------------------------
# API client
# ---------------------------------------------------------------------------

my %API_CACHE;

# The process this module was compiled in; see _api.
my $BOOT_PID = $$;
use constant API_CACHE_TTL => 300;

# How long to wait for an object the array has accepted but not yet published.
use constant AWAIT_OBJECT_TIMEOUT => 30;

# The health path (activate_storage and the foreground of status) gets a
# short-timeout, single-attempt client; everything else gets the resilient
# one. They are cached separately so neither replaces the other.
sub _api {
    my ($class, $scfg, %opts) = @_;

    my $health = $opts{status} ? 1 : 0;

    # $scfg carries no storage id, so key on everything that actually
    # distinguishes one client from another. Two storages pointing at the same
    # array with different credentials must not share a session.
    # Cache only in the process that loaded this module.
    #
    # A client kept in a package hash lives until the process ends. A PVE
    # worker ends with POSIX::_exit, which runs no DESTROY and no END, so a
    # cached client in a forked child is a session the storage server never
    # gets back — and 'forked child' is not only PVE's own worker: run_fork,
    # a timeout wrapper, or a future change to how pvestatd polls all produce
    # one. is_worker answers PVE's question, not ours.
    #
    # $BOOT_PID is the process this module was compiled in — pvestatd,
    # pvedaemon, or the pvesm command itself. Anything else got here through
    # fork, and is treated as short-lived: build a client for the call, let it
    # be freed when the call returns, and DESTROY gives the session back well
    # before any _exit.
    my $forked = ($$ != $BOOT_PID) ? 1 : 0;
    my $worker = $forked || (eval { PVE::RESTEnvironment->is_worker() } ? 1 : 0);

    # The storeid is part of the key, not only of the object.
    #
    # The client carries the storeid — every message it writes names it — and
    # the PASSWORD, which since 0.7.86 is read per storage out of
    # /etc/pve/priv/storage/<storeid>.pw. A key without the storeid therefore
    # hands storage B the client built for storage A: B's failures are logged
    # under A's name, _warn_once throttles them under A's key, and B
    # authenticates with A's password. The last one is the one that bites —
    # two storages on one array with the same username and a password that
    # has been rotated on only one of them means repeated failed logins with
    # a stale credential, and an array account that locks out takes every
    # storage on that array with it.
    my $key = join("\0",
        $opts{storeid} // '',
        $scfg->{'dell-portal'}   // '',
        $scfg->{'dell-username'} // '',
        $scfg->{'dell-ssl-verify'} // 0,
        $health,
        $health ? $class->_status_timeout($scfg) : '',
    );

    if (!$worker && (my $cached = $API_CACHE{$key})) {
        # A forked worker must not reuse the parent's session.
        if ((time() - $cached->{created}) < API_CACHE_TTL && $cached->{pid} == $$) {
            return $cached->{api};
        }
    }

    my %args = (
        portal     => $scfg->{'dell-portal'},
        username   => $scfg->{'dell-username'},
        password   => $class->_password($scfg, $opts{storeid}),
        ssl_verify => $scfg->{'dell-ssl-verify'} // 0,
        type       => $class->type(),
        storeid    => $opts{storeid},
    );

    if ($health) {
        $args{timeout} = $class->_status_timeout($scfg);
        $args{retries} = 1;
    }

    my $api = PVE::Storage::Custom::DellEMC::PowerStore::API->new(%args);

    $API_CACHE{$key} = { api => $api, created => time(), pid => $$ }
        unless $worker;

    return $api;
}

# PowerStore timestamps are ISO 8601 in UTC. PVE wants epoch seconds; handing
# the string through renders snapshot dates in the GUI as nonsense.
# PowerStore timestamps look like '2022-01-06T05:41:59.381459+00:00' — Dell's
# own module shows exactly that. The fractional seconds are dropped and the
# zone offset is applied, rather than assumed to be zero: a snapshot list eight
# hours out is the kind of wrong that looks like a bug in PVE, and this plugin
# is written for nodes in UTC+8.
sub _to_epoch {
    my ($class, $value) = @_;

    return 0 unless defined $value && length $value;
    return $value + 0 if $value =~ /^\d+$/;

    return 0 unless $value =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/;

    my $epoch = eval { Time::Local::timegm($6, $5, $4, $3, $2 - 1, $1) };
    return 0 unless defined $epoch;

    # 'Z' and a missing offset both mean UTC, which is what timegm gave.
    if ($value =~ /([+-])(\d{2}):?(\d{2})\z/) {
        my $shift = ($2 * 3600) + ($3 * 60);
        $epoch += ($1 eq '+') ? -$shift : $shift;
    }

    return $epoch;
}

# Two options claiming one slot.
#
# A volume belongs to at most one volume group, so 'pstore-volume-group' (put
# everything in this named group) and 'pstore-volume-group-per-vm' (put each
# VM in its own) cannot both apply. Refused where the configuration is still
# free to change, rather than discovered later by whichever of the two lost -
# lesson 41's shape, where a wrong protocol was accepted at 'pvesm add' and
# only surfaced on first use, with the storage already added.
sub _check_volume_group_options {
    my ($class, $storeid, $config) = @_;

    my $named = $config->{'pstore-volume-group'};
    return 1 unless defined $named && length $named;
    return 1 unless $config->{'pstore-volume-group-per-vm'};

    die "Storage '$storeid': 'pstore-volume-group' and"
      . " 'pstore-volume-group-per-vm' cannot both be set. A PowerStore volume"
      . " belongs to at most one volume group, so the two are claiming the"
      . " same slot: set the first to place every volume in the named group"
      . " '$named', or the second to give each VM a group of its own.\n";
}

sub on_add_hook {
    my ($class, $storeid, $scfg, %param) = @_;

    $class->_check_volume_group_options($storeid, $scfg);

    return $class->SUPER::on_add_hook($storeid, $scfg, %param);
}

# The merged view is what has to be checked, not the update alone: setting
# per-VM grouping on a storage that already names a group is exactly the
# conflict, and the update by itself mentions only one of the two.
sub on_update_hook_full {
    my ($class, $storeid, $scfg, $update, $delete, $sensitive) = @_;

    my %merged = (%{ $scfg // {} }, %{ $update // {} });

    my @dropped = !defined $delete    ? ()
                : ref($delete) eq 'ARRAY' ? @$delete
                : split(/\s*,\s*/, $delete);
    delete $merged{$_} for @dropped;

    $class->_check_volume_group_options($storeid, \%merged);

    return $class->SUPER::on_update_hook_full($storeid, $scfg, $update,
        $delete, $sensitive);
}

# ---------------------------------------------------------------------------
# Per-VM volume groups  ('pstore-volume-group-per-vm')
#
# One volume group per VM, so an operator can apply a protection policy or take
# a consistent group snapshot per VM from PowerStore Manager without
# maintaining the membership by hand. Requested in issue #3.
#
# The whole design follows from one fact: a PowerStore volume belongs to AT
# MOST ONE volume group. Dell's own ansible module reads volume_groups[0] and
# refuses to reassign a group for an existing volume. So this is not an
# additive label, it claims a slot an operator may be using, and that is why
# the feature is off by default and why nothing here ever touches a group it
# did not create.
#
# Four rules hold the rest of it up:
#
#   1. It may never fail a provisioning operation. A group that cannot be
#      created or found leaves the volume ungrouped and warns; a disk creation
#      that fails because a COSMETIC grouping failed would be a worse bug than
#      the one this feature fixes. That also makes the unknown ceiling on
#      volume groups per cluster harmless: past it, disks keep being created.
#   2. Only VM disks join. The config backup volume is created and deleted on
#      every single snapshot, and the temporary clones used to read a snapshot
#      live for the length of a backup; both would churn the membership and
#      make "is this group empty" a moving target. decode_volume_name already
#      names the object kind, so the rule is expressed once, on the type.
#   3. Membership follows the VMID, because the group is named after it. The
#      only PVE operation that renames a volume ACROSS vmids is reassigning a
#      disk to another VM (qm move_disk --target-vmid), and there the volume is
#      taken out of the old group first: a volume in no group has lost an
#      enhancement, a volume in the WRONG group tells an operator it belongs
#      to a VM it does not, and would carry that VM's protection policy.
#   4. Cleanup runs even when the option has since been switched off, the same
#      way volume_snapshot_delete cleans up config volumes for a storage that
#      no longer makes them. Turning a feature off is not a reason to abandon
#      what it created.
# ---------------------------------------------------------------------------

# Written into the group's description when this plugin creates it, and read
# back before this plugin ever removes a member or deletes a group.
#
# Ownership is proven by something WE WROTE, never inferred from the name.
# Anything can produce a matching name, including an operator who liked the
# convention, and lesson 40 is what happens when a name is used as an
# object-kind check.
use constant VG_OWNER_MARK => '[pve-dellemc-per-vm]';

# The object kinds that belong to a VM for as long as the VM does. Everything
# else decode_volume_name can name - 'vmconf', 'state', 'fleece', 'efienroll' -
# is transient, and an unnamed object (a temporary snapshot clone) is too.
my %VG_MEMBER_TYPE = map { $_ => 1 } qw(disk cloudinit efidisk tpmstate);

sub _vg_per_vm_enabled {
    my ($class, $scfg) = @_;
    return $scfg->{'pstore-volume-group-per-vm'} ? 1 : 0;
}

# The vmid whose group this array object belongs in, or undef when it belongs
# in none.
sub _vg_vmid_of {
    my ($class, $name) = @_;

    my $parsed = eval { $class->naming->decode_volume_name($name) };
    return undef unless ref($parsed) eq 'HASH';
    return undef unless defined $parsed->{type} && $VG_MEMBER_TYPE{ $parsed->{type} };
    return undef unless defined $parsed->{vmid} && $parsed->{vmid} =~ /^\d+\z/;

    return $parsed->{vmid};
}

sub _vg_name_for {
    my ($class, $storeid, $vmid) = @_;
    return eval { $class->naming->encode_volume_group_name($storeid, $vmid) };
}

sub _vg_is_ours {
    my ($class, $group) = @_;

    return 0 unless ref($group) eq 'HASH';
    my $desc = $group->{description};
    return 0 unless defined $desc && length $desc;

    return index($desc, VG_OWNER_MARK) >= 0 ? 1 : 0;
}

# The group for this volume, created if it is not there yet. Returns undef
# rather than dying: see rule 1 above.
sub _vg_resolve_id {
    my ($class, $scfg, $storeid, $name, %opts) = @_;

    my $vmid = $class->_vg_vmid_of($name);
    return undef unless defined $vmid;

    my $vg_name = $class->_vg_name_for($storeid, $vmid);
    unless (defined $vg_name) {
        $class->_warn_once($storeid, 'vg-name',
            "Storage '$storeid': a per-VM volume group name could not be built"
          . " ($@). Volumes are being created without a group.");
        return undef;
    }

    # Check-then-create is not atomic and PVE allocates in parallel, so both
    # halves are inside the loop - rule 22, the same shape alloc_image needed.
    # A second disk of the same VM, or a second node, races for this exact
    # group.
    my $api = $class->_api($scfg, storeid => $storeid, %opts);
    my $err;

    for my $attempt (1 .. 3) {
        my $group = eval { $api->volume_group_get_by_name($vg_name, %opts) };
        $err = $@;

        if (ref($group) eq 'HASH' && defined $group->{id} && length $group->{id}) {
            # Somebody else's group under our name. Refuse to use it: adding a
            # volume would put this VM's disk under whatever policy they set.
            unless ($class->_vg_is_ours($group)) {
                $class->_warn_once($storeid, "vg-foreign-$vmid",
                    "Storage '$storeid': the volume group '$vg_name' exists but"
                  . " was not created by this plugin, so it is left alone."
                  . " VM ${vmid}'s disks are being created without a group.");
                return undef;
            }
            return $group->{id};
        }

        # An error above is NOT "there is no such group" (rule 21a). Creating
        # one on the strength of a failed lookup is how a duplicate appears.
        next if $err;

        my $id = eval {
            $api->volume_group_create($vg_name,
                description => $class->_vg_description($storeid, $vmid), %opts);
        };
        $err = $@;
        return $id if !$err && defined $id && length $id;

        # A losing racer sees the winner's group on the next pass.
    }

    $class->_warn_once($storeid, "vg-create-$vmid",
        "Storage '$storeid': could not create or find the volume group"
      . " '$vg_name'" . ($err ? ": $err" : '') . "  VM ${vmid}'s disks are being"
      . " created without a group; this does not affect the disks themselves.");

    return undef;
}

sub _vg_description {
    my ($class, $storeid, $vmid) = @_;
    return "Proxmox VE VM $vmid on storage $storeid " . VG_OWNER_MARK;
}

# Take a volume out of its volume group(s). Returns the ids it was removed
# from, for the caller to consider reaping. Never dies, and deliberately not
# gated on the option: a storage that had it enabled still has the groups
# (rule 4 above).
#
# Two modes, and the difference is whether the volume survives:
#
#   leaving => 1  the volume is being DELETED. PowerStore refuses to delete a
#                 volume that is still a member - confirmed on a customer's
#                 array in issue #3 - so removal is mandatory and must work
#                 even for a group this plugin did not create. Taking OUR OWN
#                 volume out of somebody's group is not damage: the volume is
#                 about to stop existing. Refusing to, on the other hand,
#                 would leave a disk PVE has asked to delete undeletable
#                 forever.
#
#   default       the volume survives, and is only being moved between VMs.
#                 Here a group this plugin did not create is left alone: an
#                 operator put the volume there deliberately, and a rename is
#                 not a reason to overrule them.
sub _vg_release {
    my ($class, $scfg, $storeid, $name, $volume_id, %opts) = @_;

    my $leaving = delete $opts{leaving};

    my $api = $class->_api($scfg, storeid => $storeid, %opts);

    # The groups the volume is ACTUALLY in, not the one it would have been
    # given. An operator may have moved it, and on the delete path that is
    # exactly the case that must still work.
    my $groups = eval { $api->volume_groups_of($volume_id, %opts) };
    if ($@) {
        warn "Could not read the volume group membership of '$name': $@";
        return [];
    }
    return [] unless ref($groups) eq 'ARRAY' && @$groups;

    my @touched;
    for my $group (@$groups) {
        my $gid = $group->{id};

        unless ($leaving) {
            # Only ours are moved when the volume is staying. _vg_is_ours
            # needs the description, which the nested listing does not carry,
            # so the group is read for it.
            my $full = eval { $api->volume_group_get($gid, %opts) };
            next unless $class->_vg_is_ours($full);
        }

        eval { $api->volume_group_remove_members($gid, [$volume_id], %opts) };
        if ($@) {
            # On the delete path this is not cosmetic: the delete below will
            # be refused by the array, and the operator needs to know why.
            warn "Could not remove '$name' from volume group '"
               . ($group->{name} // $gid) . "': $@";
            next;
        }

        push @touched, $gid;
    }

    return \@touched;
}

# Delete the group if the volume just removed was the last thing in it.
#
# Three conditions, and each of them is a defect this project has already
# paid for somewhere:
#
#   - the group is ours, proven by the marker we wrote (lesson 40);
#   - the array ANSWERED, and answered empty. A listing that failed and a
#     group that is empty are indistinguishable once the error is swallowed,
#     and the reported fork does exactly that with `$vginfo->{volumes} // []`,
#     which deletes the group whenever the array is briefly unreachable
#     (rule 21a);
#   - nothing is protecting it. A protection policy on the group means an
#     operator has taken it over, and turning per-VM grouping on is not
#     permission to delete their policy.
sub _vg_reap_if_empty {
    my ($class, $scfg, $storeid, $group_id, %opts) = @_;

    return unless defined $group_id && length $group_id;

    my $api = $class->_api($scfg, storeid => $storeid, %opts);

    my $group = eval { $api->volume_group_get($group_id, %opts) };
    if ($@) {
        # Could not ask. Leaving an empty group behind costs an operator one
        # tidy-up; deleting one on a failed read can cost them a policy.
        warn "Volume group '$group_id' was left in place: its membership could"
           . " not be read ($@)";
        return;
    }

    return unless ref($group) eq 'HASH';          # already gone
    return unless $class->_vg_is_ours($group);

    my $members = $group->{volumes};
    return unless ref($members) eq 'ARRAY';       # the array did not say

    # Only primaries count. Whether PowerStore lists a member's snapshots here
    # is NOT VERIFIED, and this makes both answers safe: if it does, they are
    # skipped; if it does not, nothing changes.
    my @live = grep {
        ref($_) eq 'HASH'
            && (!defined $_->{type} || $_->{type} eq 'Primary')
    } @$members;
    return if @live;

    if (defined $group->{protection_policy_id}
        && length $group->{protection_policy_id}) {
        warn "Volume group '" . ($group->{name} // $group_id) . "' is empty but"
           . " carries a protection policy, so it has been left in place."
           . " Remove it by hand if it is no longer wanted.\n";
        return;
    }

    eval { $api->volume_group_delete($group_id, %opts) };
    warn "Empty volume group '" . ($group->{name} // $group_id)
       . "' could not be removed: $@" if $@;

    return;
}

# ---------------------------------------------------------------------------
# Name to id resolution
# ---------------------------------------------------------------------------

sub _volume_id {
    my ($class, $scfg, $name, %opts) = @_;

    my $vol = $class->_api($scfg, %opts)->volume_get_by_name($name, %opts);

    return $vol ? $vol->{id} : undef;
}

sub _require_volume_id {
    my ($class, $scfg, $name, %opts) = @_;

    my $id = $class->_volume_id($scfg, $name, %opts);
    die "Volume '$name' does not exist on the array\n" unless $id;

    return $id;
}

sub _snapshot_id {
    my ($class, $scfg, $name, %opts) = @_;

    my $snap = $class->_api($scfg, %opts)->snapshot_get_by_name($name, %opts);

    return $snap ? $snap->{id} : undef;
}

sub _host_id {
    my ($class, $scfg, $host_name, %opts) = @_;

    my $host = $class->_api($scfg, %opts)->host_get_by_name($host_name, %opts);

    return $host ? $host->{id} : undef;
}

# (id, host_group_id) for a host, in one lookup.
#
# The group matters because a LUN id is unique per host and a mapping made to
# a host GROUP occupies one on every host in it. This plugin never creates a
# group, but nothing stops an operator putting its host into one.
sub _host_identity {
    my ($class, $scfg, $host_name, %opts) = @_;

    my $host = $class->_api($scfg, %opts)->host_get_by_name($host_name, %opts)
        or return (undef, undef);

    return ($host->{id}, $host->{host_group_id});
}

# A row from the array turned into what BlockBase expects.
sub _volume_row {
    my ($class, $row) = @_;

    # ref() first: a row that is not a hash would die on the -> below, and a
    # listing this client cannot parse should come back empty, not fatal.
    return undef unless ref($row) eq 'HASH' && $row->{name};

    my $protection = $row->{protection_data};

    return {
        id    => $row->{id},
        name  => $row->{name},
        size  => $row->{size} // 0,
        used  => $row->{logical_used} // 0,
        wwid  => PVE::Storage::Custom::DellEMC::PowerStore::API->wwn_to_wwid($row->{wwn}),
        ctime => $class->_to_epoch($row->{creation_timestamp}),
        # The object a thin clone or snapshot was created from. Used to report
        # a linked clone under the volid PVE stored for it.
        source_id => ref($protection) eq 'HASH' ? $protection->{source_id} : undef,
    };
}

# ---------------------------------------------------------------------------
# Array operations
# ---------------------------------------------------------------------------

sub _array_ping {
    my ($class, $scfg, %opts) = @_;

    my $cluster = $class->_api($scfg, %opts)->cluster_get(%opts);
    die "the array did not report a cluster object\n" unless $cluster;

    return 1;
}

sub _array_get_capacity {
    my ($class, $scfg, %opts) = @_;
    return $class->_api($scfg, %opts)->get_managed_capacity(%opts);
}

sub _array_get_volume {
    my ($class, $scfg, $name, %opts) = @_;

    my $row = $class->_api($scfg, %opts)->volume_get_by_name($name, %opts);

    return $class->_volume_row($row);
}

sub _array_list_volumes {
    my ($class, $scfg, $storeid, $prefix, %opts) = @_;

    my $rows = $class->_api($scfg, %opts)->volume_list($prefix, %opts) // [];

    my @out;
    for my $row (@$rows) {
        # The array's prefix filter is case-insensitive; ours is not, and the
        # ownership boundary has to be exact.
        next unless defined $row->{name};
        next if defined $prefix && index($row->{name}, $prefix) != 0;
        push @out, $class->_volume_row($row);
    }

    return \@out;
}

sub _array_create_volume {
    my ($class, $scfg, $storeid, $name, $size, %opts) = @_;

    my $api = $class->_api($scfg, %opts);

    my %args;
    $args{appliance_id} = $scfg->{'pstore-appliance'}
        if defined $scfg->{'pstore-appliance'} && length $scfg->{'pstore-appliance'};

    for my $pair (
        ['pstore-volume-group'       => 'volume_group_id'],
        ['pstore-performance-policy' => 'performance_policy_id'],
        ['pstore-protection-policy'  => 'protection_policy_id'],
    ) {
        my ($option, $field) = @$pair;
        my $value = $scfg->{$option};
        $args{$field} = $value if defined $value && length $value;
    }

    # The group is passed at CREATE time, which PowerStore supports directly
    # (Dell's own create_volume takes volume_group_id). That avoids a second
    # call, and with it the window in which a volume exists outside the group
    # it was meant to be in.
    if ($class->_vg_per_vm_enabled($scfg)
        && !(defined $args{volume_group_id} && length $args{volume_group_id})) {
        my $vgid = $class->_vg_resolve_id($scfg, $storeid, $name, %opts);
        $args{volume_group_id} = $vgid if defined $vgid && length $vgid;
    }

    $args{description} = "Proxmox VE storage $storeid" if defined $storeid;

    my $id = $api->volume_create($name, $size, %args);

    # PowerStore answers some requests with 202 and a job id instead of the
    # finished object. The caller looks the volume up by name immediately
    # afterwards, so wait for it to actually be there rather than failing with
    # "does not exist" on a volume that is merely still being created.
    $class->_await_volume($scfg, $name, %opts);

    return $id;
}

# Wait for a named volume to become visible, bounded. Returns 1 as soon as it
# is there; dies with a message that names the volume if it never appears.
sub _await_volume {
    my ($class, $scfg, $name, %opts) = @_;

    my $deadline = time() + ($opts{await_timeout} // AWAIT_OBJECT_TIMEOUT);

    while (1) {
        return 1 if eval { $class->_volume_id($scfg, $name, %opts) };
        last if time() >= $deadline;
        sleep(1);
    }

    die "The array accepted the request but volume '$name' had not appeared"
      . " after " . AWAIT_OBJECT_TIMEOUT . "s. The operation may still be"
      . " running as a background job; check PowerStore Manager before"
      . " retrying.\n";
}

sub _array_delete_volume {
    my ($class, $scfg, $storeid, $name, %opts) = @_;

    my $id = $class->_volume_id($scfg, $name, %opts);
    return 1 unless $id;   # already gone; deletion is idempotent

    # Out of its group first, in case the array refuses to delete a member -
    # and never conditional on the option, because a storage that has since
    # switched it off still has the groups. A failure here is reported and
    # then ignored: a cosmetic grouping must not be able to strand a volume
    # that PVE has asked to delete.
    # PowerStore refuses to delete a volume that is still in a volume group,
    # so this is a required step rather than tidiness (issue #3).
    my $groups = eval {
        $class->_vg_release($scfg, $storeid, $name, $id, %opts, leaving => 1)
    } // [];
    warn "Volume group handling for '$name' failed: $@" if $@;

    my $res = $class->_api($scfg, %opts)->volume_delete($id, %opts);

    # Only once the volume is really gone, so the membership read here is the
    # membership after the delete rather than before it. _vg_reap_if_empty
    # checks ownership itself, so a group somebody else made is safe.
    for my $gid (@$groups) {
        eval { $class->_vg_reap_if_empty($scfg, $storeid, $gid, %opts) };
        warn "Empty volume group cleanup after '$name' failed: $@" if $@;
    }

    return $res;
}

sub _array_resize_volume {
    my ($class, $scfg, $storeid, $name, $size, %opts) = @_;

    my $id = $class->_require_volume_id($scfg, $name, %opts);

    return $class->_api($scfg, %opts)->volume_resize($id, $size, %opts);
}

sub _array_rename_volume {
    my ($class, $scfg, $storeid, $from, $to, %opts) = @_;

    my $id = $class->_require_volume_id($scfg, $from, %opts);

    my $res = $class->_api($scfg, %opts)->volume_rename($id, $to, %opts);

    # Reassigning a disk to another VM ('qm move_disk --target-vmid') is the
    # only PVE operation that renames a volume across vmids: restore and clone
    # both allocate NEW volumes, which land in the right group by themselves.
    # Here the group has to follow, or PowerStore Manager shows this VM's disk
    # under the previous VM and any policy on that group applies to it.
    eval { $class->_vg_follow_rename($scfg, $storeid, $from, $to, $id, %opts) };
    warn "Volume group membership for '$to' was not updated: $@" if $@;

    return $res;
}

# Move a volume from one VM's group to another's, when a rename changed the
# vmid. Both halves are best effort and the ORDER matters: out of the old
# group first.
#
# If the second half fails, the volume is in no group. That is the deliberate
# choice: no group loses an enhancement, whereas the old group states that
# this disk belongs to a VM it no longer belongs to, which is the mix-up the
# feature exists to prevent. Rule 33's shape - nothing is better than the
# neighbouring object.
sub _vg_follow_rename {
    my ($class, $scfg, $storeid, $from, $to, $volume_id, %opts) = @_;

    my $old_vmid = $class->_vg_vmid_of($from);
    my $new_vmid = $class->_vg_vmid_of($to);

    return if !defined $new_vmid && !defined $old_vmid;
    return if defined $old_vmid && defined $new_vmid && $old_vmid == $new_vmid;

    # Leaving the old group is unconditional, for the reason above. It is also
    # what keeps a storage that has switched the option off from accumulating
    # wrong memberships.
    my $old_groups = $class->_vg_release($scfg, $storeid, $from, $volume_id, %opts)
        // [];
    for my $gid (@$old_groups) {
        eval { $class->_vg_reap_if_empty($scfg, $storeid, $gid, %opts) };
    }

    return unless $class->_vg_per_vm_enabled($scfg);
    return unless defined $new_vmid;

    my $new_group = $class->_vg_resolve_id($scfg, $storeid, $to, %opts);
    return unless defined $new_group && length $new_group;

    $class->_api($scfg, storeid => $storeid, %opts)
          ->volume_group_add_members($new_group, [$volume_id], %opts);

    return 1;
}

sub _array_get_wwid {
    my ($class, $scfg, $name, %opts) = @_;

    my $vol = $class->_array_get_volume($scfg, $name, %opts);

    return $vol ? $vol->{wwid} : undef;
}

# ---------------------------------------------------------------------------
# Snapshots
# ---------------------------------------------------------------------------

sub _array_snapshot_create {
    my ($class, $scfg, $storeid, $volume, $snapshot, %opts) = @_;

    my $id = $class->_require_volume_id($scfg, $volume, %opts);

    return $class->_api($scfg, %opts)->snapshot_create($id, $snapshot, %opts);
}

sub _array_snapshot_get {
    my ($class, $scfg, $storeid, $snapshot, %opts) = @_;

    my $row = $class->_api($scfg, %opts)->snapshot_get_by_name($snapshot, %opts);

    return $class->_volume_row($row);
}

sub _array_snapshot_delete {
    my ($class, $scfg, $storeid, $snapshot, %opts) = @_;

    my $id = $class->_snapshot_id($scfg, $snapshot, %opts);
    return 1 unless $id;

    return $class->_api($scfg, %opts)->snapshot_delete($id, %opts);
}

sub _array_snapshot_list {
    my ($class, $scfg, $storeid, $volume, $prefix, %opts) = @_;

    my $api = $class->_api($scfg, %opts);

    my %query;
    if (defined $volume && length $volume) {
        my $id = $class->_volume_id($scfg, $volume, %opts);
        return [] unless $id;
        $query{source_id} = $id;
    }
    $query{prefix} = $prefix if defined $prefix && length $prefix;

    my $rows = $api->snapshot_list(%query, %opts) // [];

    return [ map { $class->_volume_row($_) } grep { $_->{name} } @$rows ];
}

sub _array_snapshot_rollback {
    my ($class, $scfg, $storeid, $volume, $snapshot, %opts) = @_;

    my $volume_id = $class->_require_volume_id($scfg, $volume, %opts);
    my $snap_id   = $class->_snapshot_id($scfg, $snapshot, %opts);
    die "Snapshot '$snapshot' does not exist on the array\n" unless $snap_id;

    return $class->_api($scfg, %opts)->volume_restore($volume_id, $snap_id, %opts);
}

# The source may be a volume or one of its snapshots; both are volume objects
# on PowerStore, so one lookup covers either.
sub _array_clone {
    my ($class, $scfg, $storeid, $source, $target, %opts) = @_;

    my $api = $class->_api($scfg, %opts);

    my $source_id = $class->_volume_id($scfg, $source, %opts)
        // $class->_snapshot_id($scfg, $source, %opts);
    die "Clone source '$source' does not exist on the array\n" unless $source_id;

    my $id = $api->volume_clone($source_id, $target, %opts);

    $class->_await_volume($scfg, $target, %opts);

    # A clone is created by the array from its source, so there is no
    # volume_group_id to pass at creation the way there is for a new volume:
    # it has to be added afterwards. Best effort, as everywhere else here.
    if ($class->_vg_per_vm_enabled($scfg)) {
        eval {
            my $vgid = $class->_vg_resolve_id($scfg, $storeid, $target, %opts);
            if (defined $vgid && length $vgid) {
                my $clone_id = $id // $class->_require_volume_id($scfg, $target, %opts);
                $api->volume_group_add_members($vgid, [$clone_id], %opts);
            }
        };
        warn "Clone '$target' was created but not added to its volume"
           . " group: $@" if $@;
    }

    return $id;
}

# A thin clone carries protection_data.source_id, which for a PVE linked clone
# is the id of a template marker snapshot. Mapping those ids back to the volume
# each one marks gives the clone's base without another query per volume.
sub _array_clone_parents {
    my ($class, $scfg, $storeid, $volumes, %opts) = @_;

    return {} unless ref($volumes) eq 'ARRAY' && @$volumes;
    return {} unless grep { $_->{source_id} } @$volumes;

    my $prefix = $class->naming->volume_prefix($storeid);
    my $snaps = eval {
        $class->_api($scfg, %opts)->snapshot_list(prefix => $prefix, %opts);
    } // [];

    my %base_of;
    for my $snap (@$snaps) {
        my $name = $snap->{name} or next;
        my $id   = $snap->{id}   or next;
        my $decoded = $class->naming->decode_snapshot_name($name) or next;
        $base_of{$id} = $decoded->{volume} if $decoded->{is_base};
    }

    return {} unless %base_of;

    my %parents;
    for my $volume (@$volumes) {
        my $source = $volume->{source_id} // next;
        my $base   = $base_of{$source}    // next;
        $parents{ $volume->{name} } = $base;
    }

    return \%parents;
}

# ---------------------------------------------------------------------------
# Hosts and mappings
# ---------------------------------------------------------------------------

# Initiators of this node, in the shape PowerStore's host object wants.
sub _initiator_records {
    my ($class, $scfg) = @_;

    if ($class->_is_fc($scfg)) {
        # COLON-SEPARATED, and the array checks. Dell's own ansible-powerstore
        # module documents the port name as '21:00:00:24:ff:31:e9:fc', and a
        # PowerStore refuses the run-together form with
        #   "the format of the port name ... is incorrect. Please use a valid
        #    IQN for iSCSI, WWN for FC, or NQN for NVMe. (0xE0A01001002F)"
        # — quoting the HOST name back rather than the port, which is what
        # made this look like a host-naming problem on the first hardware run.
        my $wwpns = get_fc_wwpns(online_only => 1);
        die "No online FC HBA ports found on this node.\n" unless @$wwpns;
        return [ map { { port_name => $_, port_type => 'FC' } } @$wwpns ];
    }

    return [ { port_name => get_initiator_name(), port_type => 'iSCSI' } ];
}

# A WWPN or IQN as a comparison key.
#
# The same port is written several ways: PowerStore shows and requires
# '21:00:f4:c7:aa:a0:a2:50', sysfs reports '0x2100f4c7aaa0a250', and an ME
# takes the run-together form. Nothing that compares two identifiers may care
# which spelling it was handed (lesson 69).
sub _initiator_key {
    my ($class, $value) = @_;
    return '' unless defined $value;
    my $key = lc($value);
    $key =~ s/^0x//;
    $key =~ s/[:\-\s]//g;
    return $key;
}

# Which host object, if any, already owns each of this node's initiators.
# Returns { <port name as this node writes it> => <host name> }.
sub _initiator_owners {
    my ($class, $scfg, $want, %opts) = @_;

    my $hosts = eval { $class->_api($scfg, %opts)->host_list(undef, %opts) } // [];
    return {} unless ref($hosts) eq 'ARRAY';

    my %owner;
    for my $host (@$hosts) {
        next unless ref($host) eq 'HASH' && defined $host->{name};
        for my $initiator (@{ $host->{host_initiators} // [] }) {
            next unless ref($initiator) eq 'HASH';
            my $key = $class->_initiator_key($initiator->{port_name}) or next;
            $owner{$key} = $host->{name};
        }
    }

    my %found;
    for my $mine (@$want) {
        my $key = $class->_initiator_key($mine->{port_name}) or next;
        $found{ $mine->{port_name} } = $owner{$key} if defined $owner{$key};
    }

    return \%found;
}

# The host object on the array that already holds exactly this node's
# initiators, if there is one.
#
# An array usually has one before this plugin ever runs — built by whoever
# zoned the fabric — under a name of its own, holding this node's WWPNs. They
# cannot be registered a second time, so either that object is used or the
# operator has to take it apart.
#
# Adopted ONLY when its initiators are a subset of this node's. A host that
# also carries someone else's ports is a shared or foreign object, and mapping
# a volume to it would hand that volume to whatever else is in it — which is
# not a decision a storage plugin gets to make quietly.
sub _adoptable_host {
    my ($class, $scfg, $want, %opts) = @_;

    my $owners = $class->_initiator_owners($scfg, $want, %opts);
    return undef unless $owners && %$owners;

    my %names = map { $_ => 1 } values %$owners;
    if (keys(%names) > 1) {
        die "This node's initiators are registered to more than one host"
          . " object on the array: "
          . join(', ', map { "$_ -> '$owners->{$_}'" } sort keys %$owners)
          . ".\n  A node is one host object. Consolidate them in PowerStore"
          . " Manager before adding this storage.\n";
    }

    my ($name) = keys %names;
    my $host = eval { $class->_api($scfg, %opts)->host_get_by_name($name, %opts) };
    return undef unless $host;

    my %mine = map { $class->_initiator_key($_->{port_name}) => 1 } @$want;
    my @extra = grep { !$mine{ $class->_initiator_key($_) } }
                map  { $_->{port_name} // () }
                @{ $host->{host_initiators} // [] };

    if (@extra) {
        die "Host '$name' on the array holds this node's initiators together"
          . " with others: " . join(', ', @extra) . ".\n  A volume mapped to"
          . " it would be visible to whatever those belong to, so this plugin"
          . " will not use it. Give this node a host object of its own, or"
          . " use 'dell-host-mode shared' if one object for the whole cluster"
          . " is what you meant.\n";
    }

    return $host;
}

sub _array_ensure_host {
    my ($class, $scfg, $storeid, %opts) = @_;

    my $api       = $class->_api($scfg, %opts);
    my $generated = $class->_generated_host_name($scfg);
    my $name      = $class->_host_name($scfg, $storeid);
    my $want      = $class->_initiator_records($scfg);

    my $host = eval { $api->host_get_by_name($name, %opts) };

    # A recorded name that is no longer on the array: the object was renamed
    # or removed. Forget it rather than creating one under its name.
    if (!$host && $name ne $generated) {
        $class->_forget_resolved_host($storeid);
        $name = $generated;
        $host = eval { $api->host_get_by_name($name, %opts) };
    }

    # No object under the name this plugin uses: before creating one, find out
    # whether this node already IS a host object under another name. Its
    # initiators can only be in one place, so creating would fail anyway.
    if (!$host) {
        my $existing = $class->_adoptable_host($scfg, $want, %opts);
        if ($existing) {
            $class->_warn_once($storeid, 'adopted-host',
                "Storage '$storeid': this node's initiators are already"
              . " registered to host '$existing->{name}' on the array, so"
              . " that object is used instead of creating"
              . " '$generated'. It holds this node's ports and no others."
              . " Volumes are mapped to it as they would be to one this"
              . " plugin had created.");
            $class->_record_resolved_host($storeid, $existing->{name});
            $name = $existing->{name};
            $host = $existing;
        }
    }

    unless ($host) {
        my $id = eval { $api->host_create($name, $want, %opts) };
        if (my $err = $@) {
            # Ask the array WHO has them rather than reading its refusal.
            # PowerStore allows an initiator on exactly one host object, and
            # the refusal names neither the initiator nor the host that holds
            # it — on the first hardware run it quoted the host name back
            # where the port name belonged, which sent the diagnosis in the
            # wrong direction entirely (rule 30, lesson 69).
            my $owners = eval { $class->_initiator_owners($scfg, $want, %opts) };

            if ($owners && %$owners) {
                my $detail = join("\n", map {
                    "    $_ is registered to host '$owners->{$_}'"
                } sort keys %$owners);

                die "Cannot create host '$name' on the array: this node's"
                  . " initiator(s) already belong to another host object, and"
                  . " PowerStore allows each one on exactly one host.\n"
                  . "$detail\n"
                  . "  Either rename that host to '$name' in PowerStore"
                  . " Manager — which keeps its initiators and any mappings —"
                  . " or remove it and let this plugin create its own.\n"
                  . "  The name matters beyond this node: volumes are mapped"
                  . " to every node's host by looking for the '"
                  . 'pve-' . $class->naming->sanitize($class->_cluster_name($scfg), 20) . '-'
                  . "' prefix, so a host outside that convention is not"
                  . " found when another node needs the volume, and live"
                  . " migration to it fails.\n"
                  . "  Set 'dell-cluster-name' if you would rather the"
                  . " generated names carried your own cluster name.\n"
                  . "  Array error: $err";
            }

            die "Failed to create host '$name' on the array: $err\n";
        }
        $class->_publish_resolved_host($storeid, $name);
        return $name;
    }

    # The host exists: make sure this node's initiators are on it. A node that
    # was reinstalled, or that gained an HBA port, otherwise silently sees
    # nothing.
    # Compared by key, not by spelling: the array may write a WWPN with
    # colons where this node writes it without, and a mismatch here re-adds an
    # initiator the host already has — which the array refuses, taking the
    # storage inactive (the shape of lesson 22 on PowerVault).
    my %present;
    for my $initiator (@{ $host->{host_initiators} // [] }) {
        my $port = $initiator->{port_name} // next;
        $present{ $class->_initiator_key($port) } = 1;
    }

    # Published for the other nodes: they pre-map new volumes to every host
    # they can see, and a host adopted under the array's own naming is not
    # findable by this plugin's prefix.
    $class->_publish_resolved_host($storeid, $name);

    my @missing = grep { !$present{ $class->_initiator_key($_->{port_name}) } } @$want;
    return $name unless @missing;

    eval { $api->host_add_initiators($host->{id}, \@missing, %opts) };
    if ($@) {
        my $err = $@;
        my $names = join(', ', map { $_->{port_name} } @missing);
        die "Failed to add this node's initiator(s) to host '$name': $names."
          . " They are most likely registered to another host object on the"
          . " array; remove that registration in PowerStore Manager.\n"
          . "  Array error: $err\n";
    }

    return $name;
}

sub _array_list_hosts {
    my ($class, $scfg, $prefix, %opts) = @_;

    my $hosts = $class->_api($scfg, %opts)->host_list($prefix, %opts) // [];

    return [ map { { name => $_->{name}, id => $_->{id} } }
             grep { $_->{name} } @$hosts ];
}

sub _array_map_to_host {
    my ($class, $scfg, $name, $host_name, %opts) = @_;

    my $api = $class->_api($scfg, %opts);

    my $volume_id = $class->_require_volume_id($scfg, $name, %opts);
    my ($host_id, $group_id) = $class->_host_identity($scfg, $host_name, %opts);
    die "Host '$host_name' is not registered on the array\n" unless $host_id;

    # A host that belongs to a host group is mapped THROUGH the group.
    #
    # PowerStore's own Map dialog offers groups and not the hosts inside them,
    # and one group mapping reaches every member — which is what a PVE cluster
    # wants, and what makes a migration find its disk without a mapping of its
    # own. Attaching the member host instead leaves the other nodes without
    # the volume, which is what a customer saw: a new disk mapped to the node
    # that created it and to nothing else.
    if (defined $group_id && length $group_id) {
        $class->_warn_once($opts{storeid} // '', "hostgroup-$group_id",
            "Host '$host_name' belongs to a host group on the array, so"
          . " volumes are mapped to the GROUP. One mapping serves every host"
          . " in it — which is what a cluster wants, and also means every"
          . " member can see these volumes.");

        return $api->volume_attach($volume_id,
            host_group_id => $group_id,
            host_id       => $host_id,
            lun_base      => $scfg->{'pstore-lun-id-base'} // 1,
            %opts,
        );
    }

    return $api->volume_attach($volume_id,
        host_id  => $host_id,
        group_id => $group_id,
        lun_base => $scfg->{'pstore-lun-id-base'} // 1,
        %opts,
    );
}

sub _array_unmap_from_host {
    my ($class, $scfg, $name, $host_name, %opts) = @_;

    my $api = $class->_api($scfg, %opts);

    my $volume_id = $class->_volume_id($scfg, $name, %opts);
    return 1 unless $volume_id;

    my ($host_id, $group_id) = $class->_host_identity($scfg, $host_name, %opts);
    return 1 unless $host_id;

    # A mapping this plugin made through a host group is removed through the
    # same group — it is the mapping, and leaving it behind is how a deleted
    # volume keeps a live path on every member.
    #
    # The detach names a host or a group, never both: sending a host for a
    # mapping the group holds is refused.
    if (defined $group_id && length $group_id
        && $api->is_mapped($volume_id, undef, %opts, group_id => $group_id)) {
        return $api->volume_detach($volume_id, host_group_id => $group_id,
            %opts);
    }

    return 1 unless $api->is_mapped($volume_id, $host_id, %opts);

    return $api->volume_detach($volume_id, host_id => $host_id, %opts);
}

sub _array_is_mapped {
    my ($class, $scfg, $name, $host_name, %opts) = @_;

    my $volume_id = $class->_volume_id($scfg, $name, %opts) or return 0;
    my ($host_id, $group_id) = $class->_host_identity($scfg, $host_name, %opts);
    return 0 unless $host_id;

    # A mapping made to a host group reaches this node just as well, so it
    # counts: the question here is whether the node can already see the
    # volume, not who made the mapping.
    return $class->_api($scfg, %opts)->is_mapped($volume_id, $host_id,
        %opts, group_id => $group_id);
}

sub _array_mapped_hosts {
    my ($class, $scfg, $name, %opts) = @_;

    my $api = $class->_api($scfg, %opts);

    my $volume_id = $class->_volume_id($scfg, $name, %opts) or return [];
    my $mappings = $api->mapping_list(volume_id => $volume_id, %opts) // [];
    return [] unless @$mappings;

    # One host listing, then a lookup: a per-mapping host query would be N
    # round trips on a path that runs during every delete.
    my $hosts = eval { $api->host_list(undef, %opts) } // [];
    my %name_of = map { $_->{id} => $_->{name} } grep { $_->{id} } @$hosts;

    my %seen;
    my @names;
    for my $mapping (@$mappings) {
        my $host_name = $name_of{ $mapping->{host_id} // '' } // next;
        push @names, $host_name unless $seen{$host_name}++;
    }

    return \@names;
}

sub _array_get_portals {
    my ($class, $scfg, %opts) = @_;
    return $class->_api($scfg, %opts)->iscsi_portals(%opts);
}

1;

__END__

=head1 NAME

PVE::Storage::Custom::DellPowerStorePlugin - Dell PowerStore storage plugin
for Proxmox VE

=head1 SYNOPSIS

In /etc/pve/storage.cfg:

    dellpowerstore: ps1
        dell-portal 192.168.1.50
        dell-username pveadmin
        dell-password SecurePassword
        dell-protocol iscsi
        pstore-volume-group pve-vg
        content images,rootdir
        shared 1

or:

    pvesm add dellpowerstore ps1 \
        --dell-portal 192.168.1.50 \
        --dell-username pveadmin \
        --dell-password 'SecurePassword' \
        --content images,rootdir \
        --shared 1

=head1 DESCRIPTION

One VM disk is one PowerStore volume, so the array's snapshots, thin clones,
compression and replication all act on a single VM disk as their natural unit.

The host-side work — iSCSI and FC login, device discovery, dm-multipath,
orphan reaping — is implemented once in
L<PVE::Storage::Custom::DellEMC::Common::BlockBase>. This module only
translates between PVE's names and PowerStore's REST objects.

=head1 STATUS

Not yet verified against physical hardware. The REST paths and field names,
the SCSI vendor and product strings, and the WWN to WWID conversion are all
still marked unverified in docs/TESTING.md.

=head1 AUTHOR

Jason Cheng (Jason Tools) <jason@jason.tools>

=head1 LICENSE

MIT License

=cut

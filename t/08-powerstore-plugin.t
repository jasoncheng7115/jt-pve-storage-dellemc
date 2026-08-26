#!/usr/bin/perl
# PowerStore plugin registration and mapping tests.
#
# The schema checks here mirror what PVE::SectionConfig::init does at boot. A
# mistake in either one does not break this storage — it dies while PVE is
# building the storage schema, which takes down every storage on the node.
#
# Copyright (c) 2026 Jason Cheng (Jason Tools) - MIT License

use strict;
use warnings;

use Test::More;

use File::Temp qw(tempdir);

# Keep this test out of the node's own state, however it is run.
#
# The Makefile exports PVE_DELLEMC_STATE_DIR and PVE_DELLEMC_RUN_DIR for every
# test target, but running `prove -Ilib t/08-...` by hand bypasses that, and
# _warn_once writes a throttle flag named after the storeid. On a node with a
# storage of the same name that is production state (lesson 67), and it also
# makes the test itself order-dependent: the second run finds the flag from
# the first and the warning never fires. Setting it here means the test is
# safe and repeatable on its own terms rather than on the harness's.
BEGIN {
    eval { require PVE::Storage::Plugin; 1 }
        or plan skip_all => 'PVE::Storage::Plugin is not available (not a Proxmox VE node)';

    my $tmp = File::Temp::tempdir(CLEANUP => 1);
    mkdir "$tmp/lib";
    mkdir "$tmp/run";
    $ENV{PVE_DELLEMC_STATE_DIR} = "$tmp/lib";
    $ENV{PVE_DELLEMC_RUN_DIR}   = "$tmp/run";
}

use PVE::Storage::Custom::DellPowerStorePlugin;
use PVE::Storage::Custom::DellPowerVaultPlugin;

my $P = 'PVE::Storage::Custom::DellPowerStorePlugin';
my $BASE = 'PVE::Storage::Custom::DellEMC::Common::BlockBase';

# ---------------------------------------------------------------------------
# What PVE checks when it loads a third-party plugin
# ---------------------------------------------------------------------------

ok($P->isa('PVE::Storage::Plugin'), 'derived from PVE::Storage::Plugin');
ok($P->can('api'), 'provides api()');
is($P->api, 13, 'implements storage API 13');
ok($P->api <= PVE::Storage::APIVER(), 'not newer than the running PVE')
    if PVE::Storage->can('APIVER');
is($P->type, 'dellpowerstore', 'storage type');

ok(grep({ $_ eq 'dellpowerstore' } @PVE::Storage::Plugin::SHARED_STORAGE),
    'registered as shared-capable, which live migration needs');

# ---------------------------------------------------------------------------
# Schema, checked the way SectionConfig::init checks it
# ---------------------------------------------------------------------------

my $props = $P->properties();
my $opts  = $P->options();
my $base_props = PVE::Storage::Plugin->private()->{propertyList} // {};

# init() dies with "undefined property" if an option names something no
# plugin declared. That is a boot failure for the whole storage layer.
for my $opt (sort keys %$opts) {
    ok($props->{$opt} || $base_props->{$opt},
        "option '$opt' resolves to a declared property");
}

# init() dies with "duplicate property" if we redeclare something PVE already
# owns.
for my $prop (sort keys %$props) {
    ok(!$base_props->{$prop}, "property '$prop' does not collide with PVE's own");
    like($prop, qr/^(?:dell|pstore)-/, "property '$prop' is namespaced");
}

ok($props->{'dell-portal'}, 'the shared options are declared by this plugin');
ok($props->{'pstore-appliance'}, 'and the PowerStore ones too');

ok($opts->{'dell-portal'}{fixed}, 'the portal cannot be changed after creation');
ok(!$opts->{'dell-username'}{optional}, 'username is required');
# Optional in the OPTION list precisely BECAUSE it is sensitive: PVE strips
# a sensitive property out of the parameters before validating them against
# the schema, so a required entry here fails every 'pvesm add' with "missing
# value for required option". PBS declares its password the same way.
ok($opts->{'dell-password'}{optional},
    'password is optional in the schema, because it never reaches the config');
ok($opts->{'pstore-appliance'}{optional}, 'appliance placement is optional');
ok($opts->{content}{optional}, 'content is optional');
ok($opts->{shared}{optional}, 'shared is optional');

# THE thing PVE actually reads. It calls
# PVE::Storage::Plugin::sensitive_properties($type) as a function and looks
# the answer up in plugindata - a sensitive_properties METHOD on the class
# is never called, and one shipped here for months while the password went
# to /etc/pve/storage.cfg in clear text.
{
    my $sensitive = $P->plugindata()->{'sensitive-properties'} // {};
    ok($sensitive->{'dell-password'},
        "plugindata declares the password sensitive - the method form is never called");

    SKIP: {
        # PVE answers from its registry, which is populated when PVE::Storage
        # loads the INSTALLED plugins - so this asks about the installed
        # version, not the working tree, and skips when they differ.
        skip 'PVE::Storage::Plugin::sensitive_properties is not available', 1
            unless PVE::Storage::Plugin->can('sensitive_properties');
        skip 'the installed plugin is older than this tree', 1
            unless eval { require PVE::Storage; 1 };

        my $list = PVE::Storage::Plugin::sensitive_properties($P->type()) // [];
        skip 'this type is not registered on this node', 1 unless @$list;

        ok(grep({ $_ eq 'dell-password' } @$list),
            '... and PVE agrees, asked the way PVE asks')
            or diag('installed plugin predates the sensitive-properties fix;'
                  . ' reinstall and re-run');
    }
}

my $pd = $P->plugindata();
is_deeply($pd->{format}, [{ raw => 1 }, 'raw'], 'raw only: these are block volumes');
ok($pd->{content}[0]{images} && $pd->{content}[0]{rootdir},
    'VM disks and container root filesystems');

like($P->get_identity({ 'dell-portal' => '10.0.0.5' }, 'ps1'),
    qr/^dellpowerstore:10\.0\.0\.5:/, 'identity pins the storage to one array');
like($P->get_identity({ 'dell-portal' => '10.0.0.5', 'pstore-appliance' => 'A1' }, 'ps1'),
    qr/A1$/, 'and to one appliance when set');

# Enumerated options must not silently accept a typo.
is_deeply([sort @{ $props->{'pstore-performance-policy'}{enum} }],
    ['High', 'Low', 'Medium'], 'performance policy enum');
is($props->{'pstore-lun-id-base'}{minimum}, 1, 'LUN base cannot be zero');
is($props->{'pstore-lun-id-base'}{maximum}, 200, 'LUN base stays well under 255');

# ---------------------------------------------------------------------------
# Every abstract method is implemented
#
# An unimplemented one only shows up when that code path runs, which for
# something like _array_snapshot_rollback could be the first time an operator
# needs it in anger.
# ---------------------------------------------------------------------------

my @abstract = qw(
    _array_ping _array_get_capacity
    _array_get_volume _array_list_volumes _array_create_volume _array_delete_volume
    _array_resize_volume _array_rename_volume _array_get_wwid
    _array_snapshot_create _array_snapshot_get _array_snapshot_delete
    _array_snapshot_list _array_snapshot_rollback _array_clone
    _array_ensure_host _array_list_hosts _array_map_to_host _array_unmap_from_host
    _array_is_mapped _array_mapped_hosts _array_get_portals
    multipath_vendor multipath_product multipath_defaults type
);

for my $method (@abstract) {
    my $impl = $P->can($method);
    ok($impl, "$method exists");
    isnt($impl, $BASE->can($method), "$method is implemented, not inherited abstract");
}

# ---------------------------------------------------------------------------
# Multipath settings
#
# These two values are the difference between a failed path and a node that
# has to be power-cycled, so a regression here must fail the build.
# ---------------------------------------------------------------------------

my $mp = $P->multipath_defaults();

isnt($mp->{no_path_retry}, 'queue',
    'no_path_retry is never "queue": queued I/O with no path left is unkillable');
is($mp->{no_path_retry}, 30, 'no_path_retry has a finite value');
isnt($mp->{dev_loss_tmo}, 'infinity',
    'dev_loss_tmo is never "infinity": a dead device must eventually go away');
is($mp->{dev_loss_tmo}, 60, 'dev_loss_tmo is finite');
is($mp->{fast_io_fail_tmo}, 5, 'I/O fails fast on a lost path');
is($mp->{prio}, 'alua', 'ALUA path priority');
is($mp->{hardware_handler}, '1 alua', 'ALUA hardware handler');
is($mp->{failback}, 'immediate', 'failback');

is($P->multipath_vendor, 'DellEMC', 'vendor string');
is($P->multipath_product, 'PowerStore', 'product string');
like($P->_vendor_re, qr/DellEMC/, 'the vendor gate is built from the vendor string');
ok('DellEMC' =~ $P->_vendor_re, 'our devices match the gate');
ok('NETAPP' !~ $P->_vendor_re, 'another vendor does not');

# The generated drop-in must never carry the dangerous forms.
my $conf = $P->_multipath_config_content();
like($conf, qr/dellemc-multipath-config-version: 1/, 'carries a version marker');
like($conf, qr/vendor\s+"DellEMC"/, 'vendor block');
like($conf, qr/product\s+"PowerStore"/, 'product block');
like($conf, qr/path_selector\s+"queue-length 0"/, 'values with spaces are quoted');
unlike($conf, qr/no_path_retry\s+queue/, 'never writes queueing');
unlike($conf, qr/dev_loss_tmo\s+infinity/, 'never writes an infinite dev_loss_tmo');

# ---------------------------------------------------------------------------
# Naming
# ---------------------------------------------------------------------------

is($P->naming, 'PVE::Storage::Custom::DellEMC::PowerStore::Naming',
    'uses the PowerStore naming limits');
is($P->naming->max_volume_name_length, 128, 'PowerStore name length');
is($P->_array_volname('ps1', 'vm-100-disk-0'), 'pve-ps1-100-disk0',
    'PVE volume name to array object name');

# ---------------------------------------------------------------------------
# Row mapping
# ---------------------------------------------------------------------------

my $row = $P->_volume_row({
    id                 => 'v-1',
    name               => 'pve-ps1-100-disk0',
    size               => 34359738368,
    logical_used       => 1073741824,
    wwn                => 'naa.68ccf09800a1b2c3d4e5f60718293a4b',
    creation_timestamp => '2026-07-26T09:00:00.000Z',
});

is($row->{name}, 'pve-ps1-100-disk0', 'name carried through');
is($row->{size}, 34359738368, 'size carried through');
is($row->{used}, 1073741824, 'logical_used becomes used');
is($row->{wwid}, '368ccf09800a1b2c3d4e5f60718293a4b',
    'the WWN is converted to the multipath WWID');
is($row->{ctime}, 1785056400, 'the ISO timestamp becomes epoch seconds');
is($P->_volume_row({}), undef, 'a row without a name is not a volume');
is($P->_volume_row(undef), undef, 'undef row');

# PVE renders a snapshot date from ctime; handing it the raw string or
# milliseconds puts the date tens of thousands of years out.
is($P->_to_epoch('2026-07-26T09:00:00.000Z'), 1785056400, 'ISO 8601 in UTC');

# The exact shape Dell's own module shows for creation_timestamp: fractional
# seconds and an explicit zone offset.
is($P->_to_epoch('2026-07-26T09:00:00.381459+00:00'), 1785056400,
    "the form Dell's sample response uses");
is($P->_to_epoch('2026-07-26T09:00:00'), 1785056400,
    'no zone at all is read as UTC');

# An offset that is not zero must move the answer. A snapshot list eight hours
# out looks like a bug in PVE, and these nodes are in UTC+8.
is($P->_to_epoch('2026-07-26T17:00:00+08:00'), 1785056400,
    'a positive offset is subtracted, not ignored');
is($P->_to_epoch('2026-07-26T01:00:00-08:00'), 1785056400,
    'and a negative one is added');
is($P->_to_epoch('2026-07-26T17:00:00+0800'), 1785056400,
    'with or without the colon');
is($P->_to_epoch('1785056400'), 1785056400, 'an epoch value passes through');
is($P->_to_epoch('nonsense'), 0, 'garbage becomes 0, meaning unknown');
is($P->_to_epoch(undef), 0, 'undef becomes 0');
is($P->_to_epoch(''), 0, 'empty becomes 0');

# ---------------------------------------------------------------------------
# Configuration defaults
# ---------------------------------------------------------------------------

my $scfg = {
    'dell-portal' => '10.0.0.5',
    'dell-username' => 'pveadmin',
    'dell-password' => 'secret',
};

is($P->_host_mode($scfg), 'per-node', 'per-node host mode by default');
is($P->_protocol($scfg), 'iscsi', 'iSCSI by default');
is($P->capacity_scope($scfg), 'array', 'capacity is reported for the array');

# The VM config backup volume costs one extra volume per snapshot of a VM.
# PowerStore's ceilings are high enough to carry that, so it stays on by
# default — but an operator close to a limit must be able to switch it off.
is($P->supports_config_backup(), 1, 'the family offers the config backup');
is($P->_config_backup_enabled($scfg), 1, '... and it is on by default');
is($P->_config_backup_enabled({ %$scfg, 'dell-config-backup' => 0 }), 0,
    '... and can be turned off');
is($P->_config_backup_enabled({ %$scfg, 'dell-config-backup' => 1 }), 1,
    '... and explicitly on stays on');
ok($P->properties()->{'dell-config-backup'}, 'the option is declared');

# ---------------------------------------------------------------------------
# Linked clones are reported under the volid PVE stored for them
# ---------------------------------------------------------------------------

{
    # A thin clone carries protection_data.source_id; for a PVE linked clone
    # that is the id of the template's marker snapshot.
    my $row = $P->_volume_row({
        id => 'v-2', name => 'pve-ps1-101-disk0', size => 1024, wwn => 'naa.6000',
        protection_data => { source_id => 'snap-1' },
    });
    is($row->{source_id}, 'snap-1', 'the clone source id is carried through');

    my $plain = $P->_volume_row({ id => 'v-3', name => 'pve-ps1-102-disk0', size => 1 });
    is($plain->{source_id}, undef, 'a volume without protection data has none');

    # No source ids at all: no query, no map.
    is_deeply($P->_array_clone_parents({}, 'ps1', [$plain]), {},
        'a storage with no clones asks the array nothing');
}

# ---------------------------------------------------------------------------
# Storage API version negotiation
#
# PVE rejects a plugin that claims a version higher than its own — and the
# storage then disappears from the node, taking every guest on it with it.
# Claiming lower than PVE's is accepted but makes PVE warn on every single
# load of PVE::Storage, which is once per pvesm call. PVE 9 raised APIVER
# twice inside the 9.1 point releases, so a hardcoded number is wrong
# somewhere by construction.
# ---------------------------------------------------------------------------

SKIP: {
    skip 'PVE::Storage is not available', 4
        unless eval { require PVE::Storage; defined &PVE::Storage::APIVER };

    my $apiver = PVE::Storage::APIVER();
    my $apiage = PVE::Storage::APIAGE();
    my $claim  = $P->api();

    cmp_ok($claim, '<=', $apiver,
        'never claims a version newer than this PVE (which would be rejected)');
    cmp_ok($claim, '>=', $apiver - $apiage,
        'and never one this PVE considers too old');

    # Anything below PVE's own version means a warning on every load, so on a
    # PVE we have implemented up to, the claim should match exactly.
    my $max = PVE::Storage::Custom::DellEMC::Common::BlockBase::APIVERSION_MAX();
    if ($apiver <= $max) {
        is($claim, $apiver, 'claims exactly what this PVE asks for');
    } else {
        is($claim, $max, 'claims the newest version actually implemented');
    }

    is(PVE::Storage::Custom::DellPowerFlexPlugin->api(), $claim,
        'every family negotiates the same way')
        if eval { require PVE::Storage::Custom::DellPowerFlexPlugin; 1 };
}

{
    # An initiator that already belongs to another host object.
    #
    # PowerStore allows each initiator on exactly one host, and its refusal
    # names neither the initiator nor the holder — on the first hardware run
    # it quoted the HOST name back where the port name belonged. So the
    # plugin asks the array who has them rather than reading the refusal.
    my $P = 'PVE::Storage::Custom::DellPowerStorePlugin';

    my $want = [ { port_name => '21:00:f4:c7:aa:a0:a2:50', port_type => 'FC' },
                 { port_name => '21:00:f4:c7:aa:a0:a2:86', port_type => 'FC' } ];

    {
        package Test::OwnerApi;
        sub new { bless {}, shift }
        sub host_list {
            return [
                { id => 'h1', name => 'tpepve-01-fc', host_initiators => [
                    # The array's spelling, which is not this node's.
                    { port_name => '21:00:F4:C7:AA:A0:A2:50', port_type => 'FC' },
                    { port_name => '2100f4c7aaa0a286',        port_type => 'FC' },
                ] },
                { id => 'h2', name => 'someone-else', host_initiators => [
                    { port_name => '21:00:00:00:00:00:00:01', port_type => 'FC' },
                ] },
            ];
        }
    }

    no warnings 'redefine', 'once';
    my $api = Test::OwnerApi->new;
    local *PVE::Storage::Custom::DellPowerStorePlugin::_api = sub { $api };

    my $owners = $P->_initiator_owners({}, $want);

    is_deeply($owners, {
        '21:00:f4:c7:aa:a0:a2:50' => 'tpepve-01-fc',
        '21:00:f4:c7:aa:a0:a2:86' => 'tpepve-01-fc',
    }, 'both of this node\'s ports are found on the host that holds them,'
     . ' whichever way the array spells them');

    is($P->_initiator_key('0x2100F4C7AAA0A250'), '2100f4c7aaa0a250',
        'a port name compares the same with 0x, with colons and without');
    is($P->_initiator_key('21:00:f4:c7:aa:a0:a2:50'), '2100f4c7aaa0a250',
        '... from either spelling');
}

{
    # Adopting the host object the array already has for this node.
    #
    # An array usually has one before this plugin runs, built by whoever
    # zoned the fabric, holding this node's WWPNs under a name of its own.
    # They cannot be registered twice, so either that object is used or the
    # operator takes it apart. Adopted only when it holds THIS node's ports
    # and no others.
    my $P = 'PVE::Storage::Custom::DellPowerStorePlugin';
    my $want = [ { port_name => '21:00:f4:c7:aa:a0:a2:50', port_type => 'FC' },
                 { port_name => '21:00:f4:c7:aa:a0:a2:86', port_type => 'FC' } ];

    my $mine_only = { id => 'h1', name => 'tpepve-01-fc', host_initiators => [
        { port_name => '21:00:F4:C7:AA:A0:A2:50' },
        { port_name => '2100f4c7aaa0a286' },
    ] };

    my $shared = { id => 'h2', name => 'esx-and-pve', host_initiators => [
        { port_name => '21:00:f4:c7:aa:a0:a2:50' },
        { port_name => '21:00:00:00:00:00:00:99' },
    ] };

    my $split_a = { id => 'h3', name => 'half-one', host_initiators => [
        { port_name => '21:00:f4:c7:aa:a0:a2:50' } ] };
    my $split_b = { id => 'h4', name => 'half-two', host_initiators => [
        { port_name => '21:00:f4:c7:aa:a0:a2:86' } ] };

    my @hosts;
    {
        package Test::AdoptApi;
        sub new { bless {}, shift }
        sub host_list { return [@hosts] }
        sub host_get_by_name {
            my ($self, $name) = @_;
            for my $h (@hosts) { return $h if $h->{name} eq $name }
            return undef;
        }
    }

    no warnings 'redefine', 'once';
    my $api = Test::AdoptApi->new;
    local *PVE::Storage::Custom::DellPowerStorePlugin::_api = sub { $api };

    @hosts = ($mine_only);
    my $found = $P->_adoptable_host({}, $want);
    is($found && $found->{name}, 'tpepve-01-fc',
        'a host holding exactly this node\'s ports is adopted, whichever way'
      . ' the array spells them');

    @hosts = ($shared);
    ok(!eval { $P->_adoptable_host({}, $want); 1 },
        'a host that also holds someone else\'s port is REFUSED — a volume'
      . ' mapped there would be visible to whatever that is');
    like($@ // '', qr/together with others/, 'and says which');
    like($@ // '', qr/21:00:00:00:00:00:00:99/, 'naming the foreign port');

    @hosts = ($split_a, $split_b);
    ok(!eval { $P->_adoptable_host({}, $want); 1 },
        'ports split across two host objects are refused: a node is one host');
    like($@ // '', qr/more than one host/, 'and says so');

    @hosts = ();
    is($P->_adoptable_host({}, $want), undef,
        'nothing to adopt when the array has never seen these ports');
}

{
    # A host inside a host group is mapped THROUGH the group.
    #
    # PowerStore's own Map dialog offers groups and not the hosts inside them:
    # once a host joins a group, the group is the mapping target. One group
    # mapping reaches every member, which is what a PVE cluster wants — and
    # attaching the member host instead is what left a customer with a disk
    # mapped to the node that created it and to nothing else.
    my $P = 'PVE::Storage::Custom::DellPowerStorePlugin';

    my @attached;
    my @detached;
    my $mapped_group = 0;

    {
        package Test::GroupApi;
        sub new { bless {}, shift }
        sub host_get_by_name {
            my ($self, $name) = @_;
            return { id => 'h1', name => $name, host_group_id => 'g-pve-fc' }
                if $name eq 'tpepve-01-fc';
            return undef;
        }
        sub volume_attach {
            my ($self, $vol, %opts) = @_;
            push @attached, { volume => $vol, %opts };
            $mapped_group = 1 if $opts{host_group_id};
            return 1;
        }
        sub volume_detach {
            my ($self, $vol, %opts) = @_;
            push @detached, { volume => $vol, %opts };
            return 1;
        }
        sub is_mapped {
            my ($self, $vol, $host_id, %opts) = @_;
            return 1 if $mapped_group && ($opts{group_id} // '') eq 'g-pve-fc';
            return 0;
        }
        sub mapping_list { return [] }
    }

    no warnings 'redefine', 'once';
    my $api = Test::GroupApi->new;
    local *PVE::Storage::Custom::DellPowerStorePlugin::_api = sub { $api };
    local *PVE::Storage::Custom::DellPowerStorePlugin::_require_volume_id =
        sub { 'v1' };
    local *PVE::Storage::Custom::DellPowerStorePlugin::_volume_id = sub { 'v1' };
    local *PVE::Storage::Custom::DellPowerStorePlugin::_warn_once = sub { 1 };

    $P->_array_map_to_host({}, 'pve-ps1-100-disk0', 'tpepve-01-fc');

    is(scalar(@attached), 1, 'one attach');
    is($attached[0]{host_group_id}, 'g-pve-fc',
        'the volume is attached to the GROUP, which is the only thing'
      . " PowerStore offers once a host is in one");

    # And the same mapping is what has to be removed: leaving it behind is how
    # a deleted volume keeps a live path on every member of the group.
    $P->_array_unmap_from_host({}, 'pve-ps1-100-disk0', 'tpepve-01-fc');

    is(scalar(@detached), 1, 'one detach');
    is($detached[0]{host_group_id}, 'g-pve-fc',
        '... and it names the group, because that is the mapping that exists');
    ok(!exists $detached[0]{host_id},
        '... and not the host: a detach names one or the other, never both');
}

# ---------------------------------------------------------------------------
# Per-VM volume groups (issue #3)
#
# The feature is cosmetic on the array and destructive if it is wrong: it
# deletes groups. Every test below is one of the ways that goes wrong.
# ---------------------------------------------------------------------------

# Which objects belong in a VM's group. The config backup volume is created
# and deleted on EVERY snapshot and the temporary clones live for the length
# of a backup, so letting either in makes the membership churn and makes "is
# this group empty" a moving target.
{
    my $N = $P->naming;

    for my $case (
        ['pve-ps1-104-disk0',            104, 'an ordinary disk'],
        ['pve-ps1-104-efidisk0',         104, 'an EFI disk'],
        ['pve-ps1-104-tpmstate0',        104, 'a TPM state disk'],
        ['pve-ps1-104-cloudinit',        104, 'a cloud-init disk'],
    ) {
        my ($name, $vmid, $what) = @$case;
        is($P->_vg_vmid_of($name), $vmid, "$what joins VM $vmid\x27s group");
    }

    for my $case (
        ['pve-ps1-104-vmconf-snap1',  'the config backup volume'],
        ['pve-ps1-104-state-snap1',   'a vmstate volume'],
        ['pve-ps1-104-fleece0',       'a fleecing volume'],
        ['pve-ps1-104-disk0-tmpsnap-9', 'a temporary snapshot clone'],
        ['someone-elses-volume',      'a volume that is not ours at all'],
    ) {
        my ($name, $what) = @$case;
        is($P->_vg_vmid_of($name), undef, "$what stays out of the group");
    }

    # The group name comes from volume_prefix, so it collides only where the
    # volume names already would - which on_add_hook already refuses.
    is($N->encode_volume_group_name('ps1', 104), 'pve-ps1-104-vg',
        'the group name shares the volume namespace');
}

# Ownership is proven by the marker this plugin wrote, never by the name.
{
    ok($P->_vg_is_ours({ description => $P->_vg_description('ps1', 104) }),
        'a group this plugin created is recognised');
    ok(!$P->_vg_is_ours({ description => 'Finance VMs, do not touch' }),
        "an operator's own group is not");
    ok(!$P->_vg_is_ours({ name => 'pve-ps1-104-vg' }),
        'and a matching NAME alone proves nothing - lesson 40');
    ok(!$P->_vg_is_ours(undef), 'nothing at all is not ours either');
}

# The one that matters most, and the one the reported fork gets wrong.
#
# Its cleanup reads the group with `$vginfo->{volumes} // []`, so a
# volume_group_get that FAILS yields an empty list and the group is deleted as
# though it were empty. A briefly unreachable array then destroys a group that
# may carry somebody's protection policy. "Could not ask" is not "there is
# nothing there" (rule 21a).
{
    package Test::VgApi;
    sub new {
        my ($cls, %a) = @_;
        return bless { deleted => [], %a }, $cls;
    }
    sub volume_group_get {
        my ($self, $id) = @_;
        die "the array is not answering\n" if $self->{unreachable};
        return $self->{group};
    }
    sub volume_group_get_by_name { return $_[0]->{group} }
    sub volume_group_delete {
        my ($self, $id) = @_;
        push @{ $self->{deleted} }, $id;
        return 1;
    }
    sub volume_group_create { return $_[0]->{created_id} }
    sub volume_group_add_members { return 1 }
    sub volume_group_remove_members { return 1 }
}

my $OURS = { id => 'vg-1', name => 'pve-ps1-104-vg',
             description => $P->_vg_description('ps1', 104) };

{
    no warnings 'redefine', 'once';

    # 1. The array cannot be asked. The group must survive.
    my $api = Test::VgApi->new(unreachable => 1, group => { %$OURS, volumes => [] });
    local *PVE::Storage::Custom::DellPowerStorePlugin::_api = sub { $api };
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    $P->_vg_reap_if_empty({}, 'ps1', 'vg-1');
    is_deeply($api->{deleted}, [],
        'an unreachable array does NOT get its volume group deleted')
        or diag('this is the defect in the reported fork');
    ok(scalar(grep { /could not be read/ } @warnings),
        '... and it says why the group was left in place');
}

{
    no warnings 'redefine', 'once';

    # 2. Empty, ours, unprotected: the only case that may be deleted.
    my $api = Test::VgApi->new(group => { %$OURS, volumes => [] });
    local *PVE::Storage::Custom::DellPowerStorePlugin::_api = sub { $api };
    $P->_vg_reap_if_empty({}, 'ps1', 'vg-1');
    is_deeply($api->{deleted}, ['vg-1'], 'an empty group of ours is removed');
}

{
    no warnings 'redefine', 'once';

    # 3. Empty, but an operator applied a protection policy to it. Turning
    #    per-VM grouping on is not permission to delete their policy.
    my $api = Test::VgApi->new(group => {
        %$OURS, volumes => [], protection_policy_id => 'pp-7' });
    local *PVE::Storage::Custom::DellPowerStorePlugin::_api = sub { $api };
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    $P->_vg_reap_if_empty({}, 'ps1', 'vg-1');
    is_deeply($api->{deleted}, [],
        'an empty group carrying a protection policy is left alone');
    ok(scalar(grep { /protection policy/ } @warnings), '... and says so');
}

{
    no warnings 'redefine', 'once';

    # 4. Not ours. Never touched, however empty and however well the name
    #    matches.
    my $api = Test::VgApi->new(group => {
        id => 'vg-9', name => 'pve-ps1-104-vg',
        description => 'Finance VMs', volumes => [] });
    local *PVE::Storage::Custom::DellPowerStorePlugin::_api = sub { $api };
    $P->_vg_reap_if_empty({}, 'ps1', 'vg-9');
    is_deeply($api->{deleted}, [],
        'a group this plugin did not create is never deleted');
}

{
    no warnings 'redefine', 'once';

    # 5. Still holding a disk. Not empty, whatever else is true.
    my $api = Test::VgApi->new(group => {
        %$OURS, volumes => [{ id => 'v-1', type => 'Primary' }] });
    local *PVE::Storage::Custom::DellPowerStorePlugin::_api = sub { $api };
    $P->_vg_reap_if_empty({}, 'ps1', 'vg-1');
    is_deeply($api->{deleted}, [], 'a group with a disk in it is kept');
}

{
    no warnings 'redefine', 'once';

    # 6. The array answered, but with no member list at all. That is not
    #    "empty" either.
    my $api = Test::VgApi->new(group => { %$OURS });
    local *PVE::Storage::Custom::DellPowerStorePlugin::_api = sub { $api };
    $P->_vg_reap_if_empty({}, 'ps1', 'vg-1');
    is_deeply($api->{deleted}, [],
        'a group whose membership the array did not report is kept');
}

# Two options claiming one slot. A volume belongs to at most one volume group,
# so this has to be refused while the configuration can still be changed
# rather than discovered later by whichever of the two lost (lesson 41).
{
    my $conflict = {
        'pstore-volume-group'        => 'finance-vg',
        'pstore-volume-group-per-vm' => 1,
    };
    ok(!eval { $P->_check_volume_group_options('ps1', $conflict); 1 },
        'setting both volume group options is refused');
    like($@, qr/at most one volume group/,
        '... and the message says why, not just that');

    ok(eval { $P->_check_volume_group_options('ps1',
            { 'pstore-volume-group-per-vm' => 1 }); 1 },
        'per-VM grouping on its own is fine');
    ok(eval { $P->_check_volume_group_options('ps1',
            { 'pstore-volume-group' => 'finance-vg' }); 1 },
        'a named group on its own is fine');
    ok(eval { $P->_check_volume_group_options('ps1', {}); 1 },
        'and neither is the default');
}

# Resolving the group: the two ways it must not go wrong.
#
# PVE allocates disks in parallel, so a second disk of the same VM and a second
# node race for this exact group. And a lookup that FAILED must never be read
# as "there is no such group", because the answer to that is to create one.
{
    package Test::VgRace;
    sub new { my ($c,%a)=@_; bless { gets => 0, creates => 0, %a }, $c }
    sub volume_group_get_by_name {
        my ($self) = @_;
        $self->{gets}++;
        die "the array is not answering\n" if $self->{unreachable};
        # A racing worker created it between our lookup and our create.
        return $self->{appears_on} && $self->{gets} >= $self->{appears_on}
            ? $self->{group} : undef;
    }
    sub volume_group_create {
        my ($self) = @_;
        $self->{creates}++;
        die "a volume group with that name already exists\n"
            if $self->{create_conflicts};
        return 'vg-new';
    }
}

{
    no warnings 'redefine', 'once';
    my $api = Test::VgRace->new;
    local *PVE::Storage::Custom::DellPowerStorePlugin::_api = sub { $api };

    is($P->_vg_resolve_id({}, 'ps1', 'pve-ps1-104-disk0'), 'vg-new',
        'a group is created for a VM that has none');
}

{
    no warnings 'redefine', 'once';
    # Two workers, one group: ours loses the create and finds the winner's.
    my $api = Test::VgRace->new(
        create_conflicts => 1, appears_on => 2,
        group => { %$OURS },
    );
    local *PVE::Storage::Custom::DellPowerStorePlugin::_api = sub { $api };

    is($P->_vg_resolve_id({}, 'ps1', 'pve-ps1-104-disk0'), 'vg-1',
        "losing the race to create the group finds the winner's, because"
      . ' the lookup and the create are both inside the retry (rule 22)');
}

{
    no warnings 'redefine', 'once';
    my $api = Test::VgRace->new(unreachable => 1);
    local *PVE::Storage::Custom::DellPowerStorePlugin::_api = sub { $api };
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    my $id = $P->_vg_resolve_id({}, 'ps1', 'pve-ps1-104-disk0');

    is($id, undef, 'an unreachable array yields no group');
    is($api->{creates}, 0,
        '... and NO group is created off the back of a failed lookup, which'
      . ' is how a duplicate appears');
    ok(scalar(grep { /without a group/ } @warnings),
        '... and the warning says the disk is being created anyway');
}

{
    no warnings 'redefine', 'once';
    # An auxiliary object never resolves a group at all, so it never creates
    # one either.
    my $api = Test::VgRace->new;
    local *PVE::Storage::Custom::DellPowerStorePlugin::_api = sub { $api };

    is($P->_vg_resolve_id({}, 'ps1', 'pve-ps1-104-vmconf-snap1'), undef,
        'the config backup volume resolves no group');
    is($api->{creates}, 0, '... and creates none');
    is($api->{gets}, 0, '... and does not even ask');
}

# ---------------------------------------------------------------------------
# Leaving a group: the volume is going away vs the volume is moving
#
# The reporter confirmed on his array that PowerStore refuses to delete a
# volume that is still a member of a volume group (issue #3). That turns
# removal from tidiness into a required step, and it changes what to do about
# a group this plugin did not create:
#
#   deleting  the volume is about to stop existing, so taking it out of
#             somebody's group is not damage. Refusing would leave a disk PVE
#             has asked to delete undeletable forever.
#   renaming  the volume survives. An operator put it there deliberately and a
#             reassignment is not a reason to overrule them.
# ---------------------------------------------------------------------------

{
    package Test::VgMembership;
    sub new { my ($c,%a)=@_; bless { removed => [], %a }, $c }
    sub volume_groups_of { return $_[0]->{groups} // [] }
    sub volume_group_get {
        my ($self, $id) = @_;
        return $self->{details}{$id};
    }
    sub volume_group_remove_members {
        my ($self, $id, $ids) = @_;
        push @{ $self->{removed} }, $id;
        return 1;
    }
}

my $FOREIGN = { id => 'vg-theirs', name => 'finance-vg',
                description => 'Finance VMs, do not touch' };
my $MINE    = { id => 'vg-mine',  name => 'pve-ps1-104-vg',
                description => $P->_vg_description('ps1', 104) };

{
    no warnings 'redefine', 'once';
    my $api = Test::VgMembership->new(
        groups  => [ { id => 'vg-theirs', name => 'finance-vg' } ],
        details => { 'vg-theirs' => $FOREIGN },
    );
    local *PVE::Storage::Custom::DellPowerStorePlugin::_api = sub { $api };

    my $touched = $P->_vg_release({}, 'ps1', 'pve-ps1-104-disk0', 'v-1',
        leaving => 1);

    is_deeply($api->{removed}, ['vg-theirs'],
        'deleting a volume removes it even from a group this plugin did not'
      . ' create, because the array refuses to delete a member')
        or diag('without this the volume can never be deleted at all');
    is_deeply($touched, ['vg-theirs'], '... and reports what it left');
}

{
    no warnings 'redefine', 'once';
    my $api = Test::VgMembership->new(
        groups  => [ { id => 'vg-theirs', name => 'finance-vg' } ],
        details => { 'vg-theirs' => $FOREIGN },
    );
    local *PVE::Storage::Custom::DellPowerStorePlugin::_api = sub { $api };

    my $touched = $P->_vg_release({}, 'ps1', 'pve-ps1-104-disk0', 'v-1');

    is_deeply($api->{removed}, [],
        "moving a volume between VMs leaves an operator's own group alone");
    is_deeply($touched, [], '... and reports nothing to reap');
}

{
    no warnings 'redefine', 'once';
    my $api = Test::VgMembership->new(
        groups  => [ { id => 'vg-mine', name => 'pve-ps1-104-vg' } ],
        details => { 'vg-mine' => $MINE },
    );
    local *PVE::Storage::Custom::DellPowerStorePlugin::_api = sub { $api };

    $P->_vg_release({}, 'ps1', 'pve-ps1-104-disk0', 'v-1');
    is_deeply($api->{removed}, ['vg-mine'],
        'a group this plugin created is left on a rename, as the VMID must'
      . ' keep matching the one Proxmox shows');
}

{
    no warnings 'redefine', 'once';
    # The membership cannot be read. Removing nothing is right: the delete
    # below will be refused by the array and say so, which is better than
    # guessing which groups to strip.
    package Test::VgUnreadable;
    sub new { bless { removed => [] }, shift }
    sub volume_groups_of { die "the array is not answering\n" }
    sub volume_group_remove_members { push @{ $_[0]{removed} }, $_[1]; 1 }
}

{
    no warnings 'redefine', 'once';
    my $api = Test::VgUnreadable->new;
    local *PVE::Storage::Custom::DellPowerStorePlugin::_api = sub { $api };
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    my $touched = $P->_vg_release({}, 'ps1', 'pve-ps1-104-disk0', 'v-1',
        leaving => 1);

    is_deeply($touched, [], 'an unreadable membership removes nothing');
    is_deeply($api->{removed}, [], '... and strips no group on a guess');
    ok(scalar(grep { /membership/ } @warnings), '... and says so');
}

# ---------------------------------------------------------------------------
# Host groups (issue #5)
#
# A host belongs to AT MOST ONE host group - the host object carries
# 'host_group_id', singular, where a volume carries 'volume_groups', a list -
# and a host in a group is mapped THROUGH that group. So moving a host between
# groups takes away every volume the old group was mapping to it, and the move
# is not even atomic. Everything below is that rule.
# ---------------------------------------------------------------------------

{
    package Test::HgApi;
    sub new { my ($c,%a)=@_; bless { added => [], created => [], removed => [], %a }, $c }
    sub host_get_by_name { return $_[0]->{host} }
    sub host_group_get {
        my ($self, $id) = @_;
        die "the array is not answering\n" if $self->{unreachable};
        return $self->{groups}{$id};
    }
    sub host_group_get_by_name {
        my ($self, $name) = @_;
        die "the array is not answering\n" if $self->{unreachable};
        return $self->{by_name}{$name};
    }
    sub host_group_create {
        my ($self, $name, $ids, %o) = @_;
        push @{ $self->{created} }, { name => $name, hosts => $ids, %o };
        return 'hg-new';
    }
    sub host_group_add_hosts {
        my ($self, $id, $ids) = @_;
        push @{ $self->{added} }, { group => $id, hosts => $ids };
        return 1;
    }
    sub host_group_remove_hosts {
        my ($self, $id, $ids) = @_;
        push @{ $self->{removed} }, { group => $id, hosts => $ids };
        return 1;
    }
}

my $HG_SCFG = { 'dell-cluster-name' => 'c1', 'dell-host-mode' => 'host-group' };

# 1. In no group: ours to create and join.
{
    no warnings 'redefine', 'once';
    my $api = Test::HgApi->new(host => { id => 'h-1', name => 'pve-c1-n1' });
    local *PVE::Storage::Custom::DellPowerStorePlugin::_api = sub { $api };

    my $id = $P->_hg_ensure_member($HG_SCFG, 'ps1', 'pve-c1-n1');

    is($id, 'hg-new', 'a host in no group gets our group');
    is(scalar @{ $api->{created} }, 1, 'the group is created once');
    is($api->{created}[0]{name}, 'pve-c1-cluster',
        'named after the cluster, not the storage: a node is in one cluster');
    like($api->{created}[0]{description}, qr/\Q[pve-dellemc-cluster]\E/,
        'and carries the ownership marker this plugin wrote');
    is_deeply($api->{removed}, [],
        'nothing is removed from anything');
}

# 2. THE ONE THAT MATTERS. Already in somebody else's group: never moved.
{
    no warnings 'redefine', 'once';
    my $api = Test::HgApi->new(
        host   => { id => 'h-1', name => 'pve-c1-n1' },
        groups => { 'hg-theirs' => { id => 'hg-theirs', name => 'vmware-cluster',
                                     description => 'ESXi hosts' } },
    );
    local *PVE::Storage::Custom::DellPowerStorePlugin::_api = sub { $api };
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    # The host reports the foreign group.
    local *PVE::Storage::Custom::DellPowerStorePlugin::_host_identity =
        sub { return ('h-1', 'hg-theirs') };

    my $id = $P->_hg_ensure_member($HG_SCFG, 'ps1', 'pve-c1-n1');

    is($id, 'hg-theirs', 'the foreign group is reported back, and used');
    is_deeply($api->{removed}, [],
        'the host is NEVER removed from a group this plugin did not create')
        or diag('removing it takes away every volume that group maps to the'
              . " node, which may be somebody else's production storage");
    is_deeply($api->{created}, [], '... and no group of ours is created for it');
    is_deeply($api->{added}, [], '... and it is not added anywhere');
    ok(scalar(grep { /left there|at most one/ } @warnings),
        '... and the operator is told why, once');
}

# 3. Already in ours: nothing happens at all.
{
    no warnings 'redefine', 'once';
    my $api = Test::HgApi->new(
        host   => { id => 'h-1', name => 'pve-c1-n1' },
        groups => { 'hg-ours' => { id => 'hg-ours', name => 'pve-c1-cluster',
            description => 'Proxmox VE cluster c1 [pve-dellemc-cluster]' } },
    );
    local *PVE::Storage::Custom::DellPowerStorePlugin::_api = sub { $api };
    local *PVE::Storage::Custom::DellPowerStorePlugin::_host_identity =
        sub { return ('h-1', 'hg-ours') };

    my $id = $P->_hg_ensure_member($HG_SCFG, 'ps1', 'pve-c1-n1');
    is($id, 'hg-ours', 'a host already in our group stays put');
    is_deeply($api->{created}, [], 'nothing is created');
    is_deeply($api->{added}, [], 'nothing is added');
}

# 4. The array cannot be asked which group the host is in. Doing nothing is
#    right: the alternative is deciding it is not ours and adding the host
#    somewhere, which is the move this design exists to avoid.
{
    no warnings 'redefine', 'once';
    my $api = Test::HgApi->new(host => { id => 'h-1' }, unreachable => 1);
    local *PVE::Storage::Custom::DellPowerStorePlugin::_api = sub { $api };
    local *PVE::Storage::Custom::DellPowerStorePlugin::_host_identity =
        sub { return ('h-1', 'hg-unknown') };

    my $id = $P->_hg_ensure_member($HG_SCFG, 'ps1', 'pve-c1-n1');

    is($id, undef, 'an unreadable group yields no answer');
    is_deeply($api->{removed}, [], '... and nothing is moved on a guess');
    is_deeply($api->{created}, [], '... and nothing is created');
}

# 5. A second node racing for the same group finds the winner's.
{
    no warnings 'redefine', 'once';
    my $api = Test::HgApi->new(
        host    => { id => 'h-2', name => 'pve-c1-n2' },
        by_name => { 'pve-c1-cluster' => { id => 'hg-ours', name => 'pve-c1-cluster' } },
    );
    local *PVE::Storage::Custom::DellPowerStorePlugin::_api = sub { $api };
    local *PVE::Storage::Custom::DellPowerStorePlugin::_host_identity =
        sub { return ('h-2', undef) };

    my $id = $P->_hg_ensure_member($HG_SCFG, 'ps1', 'pve-c1-n2');
    is($id, 'hg-ours', 'the second node joins the existing group');
    is_deeply($api->{created}, [], '... without creating a second one');
    is($api->{added}[0]{group}, 'hg-ours', '... by being added to it');
}

# The mode is refused on families that do not implement it. dell-host-mode is
# declared once for every type, because SectionConfig dies on a duplicate
# property name, so the enum lists every mode any family supports (lesson 41).
{
    ok(!eval { PVE::Storage::Custom::DellPowerVaultPlugin->_check_host_mode(
            'me5', { 'dell-host-mode' => 'host-group' }); 1 },
        'host-group is refused on PowerVault, which does not implement it');
    like($@, qr/not implemented for this family/, '... saying so plainly');

    ok(eval { $P->_check_host_mode('ps1', { 'dell-host-mode' => 'host-group' }); 1 },
        'and accepted on PowerStore, which does');
    ok(eval { $P->_check_host_mode('ps1', { 'dell-host-mode' => 'per-node' }); 1 },
        'per-node stays valid everywhere');
}

# ---------------------------------------------------------------------------
# A group-level mapping has no host_id (issue #11)
#
# A host_volume_mapping row for a mapping made to a host group carries
# host_group_id and NO host_id. Reading only host_id therefore calls the volume
# unmapped, the caller unmaps nothing, and the array refuses to delete it
# because it is still attached.
#
# This project already had the fact written down, for LUN allocation, where a
# group mapping occupies its id on every member. It was never applied to the
# unmap path.
# ---------------------------------------------------------------------------

{
    package Test::MapApi;
    sub new { my ($c,%a)=@_; bless {%a}, $c }
    sub mapping_list { return $_[0]->{mappings} }
    sub host_list    { return $_[0]->{hosts} }
}

{
    no warnings 'redefine', 'once';
    my $api = Test::MapApi->new(
        mappings => [ { volume_id => 'v-1', host_group_id => 'hg-1' } ],
        hosts    => [ { id => 'h-1', name => 'pve-c1-n1', host_group_id => 'hg-1' },
                      { id => 'h-2', name => 'pve-c1-n2', host_group_id => 'hg-1' } ],
    );
    local *PVE::Storage::Custom::DellPowerStorePlugin::_api = sub { $api };
    local *PVE::Storage::Custom::DellPowerStorePlugin::_volume_id = sub { 'v-1' };

    my $hosts = $P->_array_mapped_hosts({}, 'pve-ps1-100-disk0');

    is(scalar @$hosts, 1,
        'a group-level mapping is reported, so the caller can unmap it')
        or diag('reporting none is why the array refused the delete: the'
              . ' volume was still attached to the group');
    like($hosts->[0], qr/^pve-c1-n/,
        '... as a member host name, which is what the unmap path takes');
}

{
    no warnings 'redefine', 'once';
    # Both kinds at once, and the same host reached twice, must not duplicate.
    my $api = Test::MapApi->new(
        mappings => [ { volume_id => 'v-1', host_id => 'h-3' },
                      { volume_id => 'v-1', host_group_id => 'hg-1' } ],
        hosts    => [ { id => 'h-1', name => 'pve-c1-n1', host_group_id => 'hg-1' },
                      { id => 'h-3', name => 'pve-c1-n3' } ],
    );
    local *PVE::Storage::Custom::DellPowerStorePlugin::_api = sub { $api };
    local *PVE::Storage::Custom::DellPowerStorePlugin::_volume_id = sub { 'v-1' };

    my $hosts = $P->_array_mapped_hosts({}, 'pve-ps1-100-disk0');
    is_deeply([sort @$hosts], ['pve-c1-n1', 'pve-c1-n3'],
        'a host mapping and a group mapping are both reported');
}

{
    no warnings 'redefine', 'once';
    # A group whose members this storage cannot name. Reporting nothing would
    # repeat the defect silently, so it warns and the delete then fails with
    # the array's own reason rather than with silence.
    my $api = Test::MapApi->new(
        mappings => [ { volume_id => 'v-1', host_group_id => 'hg-unknown' } ],
        hosts    => [ { id => 'h-1', name => 'pve-c1-n1' } ],
    );
    local *PVE::Storage::Custom::DellPowerStorePlugin::_api = sub { $api };
    local *PVE::Storage::Custom::DellPowerStorePlugin::_volume_id = sub { 'v-1' };
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    my $hosts = $P->_array_mapped_hosts({}, 'pve-ps1-100-disk0');
    is_deeply($hosts, [], 'an unnameable group yields no host to unmap by');
    ok(scalar(grep { /host group/ } @warnings),
        '... but says so, rather than reporting "not mapped"');
}

done_testing();

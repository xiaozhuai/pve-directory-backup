package PVE::Storage::Custom::BackupProviderDirPlugin;

use strict;
use warnings;

use Encode qw(decode encode);
use Errno qw(ENOENT);
use Fcntl qw(S_ISREG);
use File::Path qw(remove_tree);
use Time::Local qw(timelocal_modern);

use PVE::BackupProvider::Plugin::Directory;
use PVE::Tools;

use base qw(PVE::Storage::Plugin);

# Helpers

sub get_vm_backup_mechanism {
    my ($class, $scfg) = @_;

    return $scfg->{'vm-backup-mechanism'} // properties()->{'vm-backup-mechanism'}->{'default'};
}

sub get_lxc_backup_mode {
    my ($class, $scfg) = @_;

    return $scfg->{'lxc-backup-mode'} // properties()->{'lxc-backup-mode'}->{'default'};
}

# Directory names below the configured root are never followed through symlinks.
my sub directory_entries {
    my ($path) = @_;

    die "refusing symbolic link directory '$path'\n" if -l $path;
    opendir(my $dh, $path) or die "unable to open directory '$path' - $!\n";
    my @entries = sort grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir($dh) or die "unable to close directory '$path' - $!\n";
    return @entries;
}

my sub parse_backup_volume {
    my ($volname, $noerr) = @_;

    my $date = qr/[0-9]{4}_[0-9]{2}_[0-9]{2}-[0-9]{2}_[0-9]{2}_[0-9]{2}/;
    if ($volname =~ m!\Abackup/(([0-9]+)-(qemu|lxc)-($date|[0-9]+))\z!) {
        my ($archive, $vmid, $type, $timestamp) = ($1, $2, $3, $4);
        my $ctime = $timestamp;
        if ($timestamp =~ /_/) {
            my ($year, $month, $day, $hour, $minute, $second) = split(/[_-]/, $timestamp);
            local $@;
            $ctime = eval { timelocal_modern($second, $minute, $hour, $day, $month - 1, $year) };
        }
        return ($archive, $vmid, $type, $ctime) if defined($ctime);
    }

    die "unable to parse volume name '$volname'\n" if !$noerr;
    return;
}

my sub backup_directory {
    my ($class, $scfg, $volname) = @_;

    my ($relative, undef, undef, $ctime) = parse_backup_volume($volname);
    for my $path ($scfg->{path}, "$scfg->{path}/$relative") {
        die "refusing symbolic link directory '$path'\n" if -l $path;
        die "backup directory '$path' does not exist\n" if !-d $path;
    }
    my $path = "$scfg->{path}/$relative";
    die "backup '$volname' is incomplete\n" if -l "$path/.complete" || !-f "$path/.complete";
    return wantarray ? ($path, $ctime) : $path;
}

# Keep one lock per VMID in the storage root. Deletion and metadata updates
# share the lock, and removing an archive leaves its lock inode in place.
my sub with_backup_lock {
    my ($class, $scfg, $volname, $code) = @_;

    backup_directory($class, $scfg, $volname);
    my (undef, undef, $vmid) = $class->parse_volname($volname);
    my $lock_path = "$scfg->{path}/.$vmid.lock";
    die "refusing symbolic link lock '$lock_path'\n" if -l $lock_path;
    die "lock '$lock_path' is not a regular file\n" if -e $lock_path && !-f $lock_path;

    my $result = PVE::Tools::lock_file($lock_path, 30, $code);
    die $@ if $@;
    return $result;
}

my sub backup_files {
    my ($path) = @_;

    return map { "$path/$_" } grep { !-l "$path/$_" && -f "$path/$_" }
        directory_entries($path);
}

my sub allocated_file_size {
    my ($file) = @_;

    my @stat = lstat($file);
    die "unable to stat backup file '$file' - $!\n" if !@stat;
    die "backup file '$file' is not a regular file\n" if !S_ISREG($stat[2]);
    die "unable to determine allocated size of '$file'\n" if !defined($stat[12]);
    # st_blocks counts 512-byte units, independently of the filesystem block size.
    return $stat[12] * 512;
}

my sub backup_size {
    my ($path) = @_;

    my $size = 0;
    $size += allocated_file_size($_) for backup_files($path);
    # stat values are tainted under vzdump/pvesm. pvesm uses the size's length
    # to construct a printf format, so validate before returning the number.
    my ($bytes) = $size =~ m/\A(\d+)\z/;
    die "invalid backup size for '$path'\n" if !defined($bytes);
    return 0 + $bytes;
}

# Configuration

sub api {
    return 16;
}

sub type {
    return 'backup-provider-dir';
}

sub plugindata {
    return {
	content => [ { backup => 1, none => 1 }, { backup => 1 } ],
	features => { 'backup-provider' => 1 },
	'sensitive-properties' => {},
    };
}

sub properties {
    return {
	'lxc-backup-mode' => {
	    description => "How to create LXC backups. tar - create a tar archive.",
	    type => 'string',
	    enum => [qw(tar)],
	    default => 'tar',
	},
	'vm-backup-mechanism' => {
	    description => "Which mechanism to use for creating complete sparse raw VM backups. "
		."nbd - copy the NBD export directly. file-handle - copy data via a file handle.",
	    type => 'string',
	    enum => [qw(nbd file-handle)],
	    default => 'nbd',
	},
    };
}

sub options {
    return {
	path => { fixed => 1 },
	'lxc-backup-mode' => { optional => 1 },
	'vm-backup-mechanism' => { optional => 1 },
	disable => { optional => 1 },
	nodes => { optional => 1 },
	'prune-backups' => { optional => 1 },
	'max-protected-backups' => { optional => 1 },
    };
}

# Storage implementation

sub prune_backups {
    my ($class, $scfg, $storeid, $keep, $vmid, $type, $dryrun, $logfunc) = @_;

    $logfunc //= sub { print "$_[1]\n" };
    my $groups = {};
    my $prune_list = [];
    for my $backup ($class->list_volumes($storeid, $scfg, $vmid, ['backup'])->@*) {
        next if defined($type) && $type ne $backup->{subtype};
        my $entry = {
            volid => $backup->{volid},
            vmid => $backup->{vmid},
            type => $backup->{subtype},
            ctime => $backup->{ctime},
        };
        $entry->{mark} = 'protected' if $backup->{protected};
        push $groups->{"$entry->{type}/$entry->{vmid}"}->@*, $entry;
        push $prune_list->@*, $entry;
    }
    PVE::Storage::prune_mark_backup_group($_, $keep) for values $groups->%*;

    my $failed;
    if (!$dryrun) {
        for my $entry ($prune_list->@*) {
            next if $entry->{mark} ne 'remove';
            my $volid = $entry->{volid};
            $logfunc->('info', "removing backup '$volid'");
            eval {
                my (undef, $volname) = split(/:/, $volid, 2);
                $class->free_image($storeid, $scfg, $volname, 0);
            };
            if (my $err = $@) {
                $logfunc->('err', "error when removing backup '$volid' - $err");
                $failed = 1;
            }
        }
    }
    die "error pruning backups - check log\n" if $failed;
    return $prune_list;
}

sub parse_volname {
    my ($class, $volname) = @_;

    my ($filename, $vmid) = parse_backup_volume($volname);
    return ('backup', $filename, $vmid);
}

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    die "volume snapshot is not possible on backup-provider-dir volume" if $snapname;

    my ($type, $filename, $vmid) = $class->parse_volname($volname);

    my $path = "$scfg->{path}/${filename}";
    return wantarray ? ($path, $vmid, $type) : $path;
}

sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;

    die "cannot create base image in backup-provider-dir storage\n";
}

sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snap) = @_;

    die "can't clone images in backup-provider-dir storage\n";
}

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    die "can't allocate space in backup-provider-dir storage\n";
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;

    return with_backup_lock($class, $scfg, $volname, sub {
        my $path = backup_directory($class, $scfg, $volname);
        die "cannot remove protected backup '$storeid:$volname'\n"
            if $class->get_volume_attribute($scfg, $storeid, $volname, 'protected');

        my $errors;
        remove_tree($path, { safe => 1, error => \$errors });
        if ($errors->@*) {
            my @messages;
            for my $error ($errors->@*) {
                push @messages, map { "$_: $error->{$_}" } keys $error->%*;
            }
            die "unable to remove backup '$storeid:$volname' - " . join('; ', @messages) . "\n";
        }
        die "unable to remove backup directory '$path'\n" if -e $path || -l $path;
        return;
    });
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    my $res = [];

    return $res;
}

sub list_volumes {
    my ($class, $storeid, $scfg, $vmid, $content_types) = @_;

    return [] if !grep { $_ eq 'backup' } $content_types->@*;

    my $path = $scfg->{path};
    my $res = [];
    for my $entry (directory_entries($path)) {
        my ($archive, $backup_vmid, $subtype, $ctime) = parse_backup_volume("backup/$entry", 1);
        next if !defined($archive);
        next if defined($vmid) && $backup_vmid != $vmid;
        my $backup_dir = "$path/$archive";
        next if -l $backup_dir || !-d $backup_dir;
        next if -l "$backup_dir/.complete" || !-f "$backup_dir/.complete";
        my $volname = "backup/$archive";
        push $res->@*, {
            volid => "$storeid:$volname",
            vmid => $backup_vmid,
            format => 'directory',
            ctime => $ctime,
            size => backup_size($backup_dir),
            subtype => $subtype,
            content => 'backup',
            protected => $class->get_volume_attribute($scfg, $storeid, $volname, 'protected'),
            notes => $class->get_volume_attribute($scfg, $storeid, $volname, 'notes'),
        };
    }
    return $res;
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $path = $scfg->{path};

    my $timeout = 2;
    if (!PVE::Tools::run_fork_with_timeout($timeout, sub {!-l $path && -d $path})) {
	die "unable to activate storage '$storeid' - directory '$path' does not exist or is"
	    ." unreachable\n";
    }

    return 1;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    return 1;
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    die "volume snapshot is not possible on backup-provider-dir volume" if $snapname;

    backup_directory($class, $scfg, $volname);

    return 1;
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    die "volume snapshot is not possible on backup-provider-dir volume" if $snapname;

    return 1;
}

sub get_volume_attribute {
    my ($class, $scfg, $storeid, $volname, $attribute) = @_;

    my $path = backup_directory($class, $scfg, $volname);
    if ($attribute eq 'protected') {
        # Any marker, including a dangling symlink, must fail closed for deletion.
        return -e "$path/backup.protected" || -l "$path/backup.protected" ? 1 : 0;
    } elsif ($attribute eq 'notes') {
        my $notes_path = "$path/backup.notes";
        die "refusing symbolic link notes '$notes_path'\n" if -l $notes_path;
        return '' if !-e $notes_path;
        die "notes '$notes_path' is not a regular file\n" if !-f $notes_path;
        my $data = PVE::Tools::file_get_contents($notes_path);
        return eval { decode('UTF-8', $data, 1) } // $data;
    }
    return;
}

sub update_volume_attribute {
    my ($class, $scfg, $storeid, $volname, $attribute, $value) = @_;

    die "attribute '$attribute' is not supported on backup-provider-dir volume\n"
        if $attribute ne 'notes' && $attribute ne 'protected';

    return with_backup_lock($class, $scfg, $volname, sub {
        my $path = backup_directory($class, $scfg, $volname);
        my $attribute_path = "$path/backup.$attribute";
        die "refusing symbolic link attribute '$attribute_path'\n" if -l $attribute_path;
        die "attribute '$attribute_path' is not a regular file\n"
            if -e $attribute_path && !-f $attribute_path;
        my $data = $attribute eq 'notes' ? encode('UTF-8', $value // '') : ($value ? "1\n" : '');
        if ($data ne '') {
            PVE::Tools::file_set_contents($attribute_path, $data);
        } else {
            unlink($attribute_path) or $! == ENOENT
                or die "unable to remove attribute '$attribute_path' - $!\n";
        }
        return;
    });
}

sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;

    my ($backup_dir, $ctime) = backup_directory($class, $scfg, $volname);
    my $size = 0;
    my $used = 0;
    for my $backup_file (backup_files($backup_dir)) {
        if ($backup_file =~ m!\.raw\z!) {
            my ($virtual_size, undef, $disk_size) =
                PVE::Storage::Plugin::file_size_info($backup_file, $timeout, 'raw', 1);
            die "unable to determine size of '$backup_file'\n" if !defined($virtual_size);
            $size += $virtual_size;
            $used += $disk_size // allocated_file_size($backup_file);
        } elsif ($backup_file =~ m!\.qcow2\z!) {
            die "legacy qcow2 backup images are not supported: '$backup_file'\n";
        } else {
            $size += -s $backup_file;
            $used += allocated_file_size($backup_file);
        }
    }
    ($size) = $size =~ m/\A(\d+)\z/;
    ($used) = $used =~ m/\A(\d+)\z/;
    die "invalid backup size for '$backup_dir'\n" if !defined($size) || !defined($used);
    return wantarray ? (0 + $size, 'directory', 0 + $used, undef, $ctime) : 0 + $size;
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;

    die "volume resize is not possible on backup-provider-dir volume";
}

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    die "volume snapshot is not possible on backup-provider-dir volume";
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    die "volume snapshot rollback is not possible on backup-provider-dir volume";
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    die "volume snapshot delete is not possible on backup-provider-dir volume";
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running) = @_;

    return 0;
}

sub new_backup_provider {
    my ($class, $scfg, $storeid, $log_function) = @_;

    return PVE::BackupProvider::Plugin::Directory->new(
	$class, $scfg, $storeid, $log_function);
}

1;

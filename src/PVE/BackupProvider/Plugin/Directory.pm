package PVE::BackupProvider::Plugin::Directory;

use strict;
use warnings;

use Errno qw(EINTR);
use Fcntl qw(SEEK_SET O_RDWR O_CREAT O_EXCL);
use File::Path qw(make_path remove_tree);
use File::Temp qw(tempdir);
use IO::File;
use POSIX qw(strftime);
use Time::HiRes qw(time sleep);

use PVE::Storage::Common;
use PVE::Storage::Plugin;
use PVE::Tools qw(file_get_contents file_set_contents run_command);

use base qw(PVE::BackupProvider::Plugin::Base);

# Private helpers

my sub log_info {
    my ($self, $message) = @_;

    $self->{'log-function'}->('info', $message);
}

my sub log_warning {
    my ($self, $message) = @_;

    $self->{'log-function'}->('warn', $message);
}

my sub check_sparse_support {
    my ($directory) = @_;

    my $probe = File::Temp->new(
        TEMPLATE => '.sparse-check-XXXXXXXX', DIR => $directory, UNLINK => 1);
    my $size = 16 * 1024 * 1024;
    eval {
        truncate($probe, $size) or die "unable to size sparse-file probe - $!\n";
        sysseek($probe, $size - 1, SEEK_SET) // die "unable to seek sparse-file probe - $!\n";
        my $written;
        do {
            $written = syswrite($probe, 'x', 1);
        } while (!defined($written) && $! == EINTR);
        die "unable to write sparse-file probe - $!\n" if !defined($written);
        die "short write to sparse-file probe\n" if $written != 1;

        # Force delayed allocation before measuring Linux st_blocks (512-byte units).
        $probe->sync() or die "unable to synchronize sparse-file probe - $!\n";
        my @stat = stat($probe);
        die "unable to stat sparse-file probe - $!\n" if !@stat;
        die "unable to verify sparse-file allocation in '$directory'\n"
            if $stat[7] != $size || !defined($stat[12]) || $stat[12] <= 0;
        my $allocated = $stat[12] * 512;
        die "backup target '$directory' does not preserve sparse files"
            . " (probe allocated $allocated of $size bytes)\n"
            if $allocated >= $size / 2;
    };
    my $error = $@;

    if (unlink($probe->filename)) {
        $probe->unlink_on_destroy(0);
    } else {
        $error .= "unable to remove sparse-file probe - $!\n";
    }
    $probe->close() or $error .= "unable to close sparse-file probe - $!\n";
    die $error if $error;

    return;
}

# Backup Provider API

sub new {
    my ($class, $storage_plugin, $scfg, $storeid, $log_function) = @_;

    my $self = bless {
	scfg => $scfg,
	storeid => $storeid,
	'storage-plugin' => $storage_plugin,
	'log-function' => $log_function,
    }, $class;

    return $self;
}

sub provider_name {
    my ($self) = @_;

    return 'directory backup provider';
}

# Hooks

sub job_init {
    my ($self, $start_time) = @_;

    log_info($self, "backup provider initialized successfully for new job $start_time");

    return;
}

sub job_cleanup {
    my ($self) = @_;

    log_info($self, "job cleanup called");

    return;
}

sub backup_init {
    my ($self, $vmid, $vmtype, $backup_time) = @_;

    die "invalid guest ID\n" if $vmid !~ m/\A[0-9]+\z/;
    die "unsupported guest type '$vmtype'\n" if $vmtype !~ m/\A(?:qemu|lxc)\z/;
    die "invalid backup timestamp\n" if $backup_time !~ m/\A[0-9]+\z/;
    my $timestamp = strftime('%Y_%m_%d-%H_%M_%S', localtime($backup_time));
    my $archive = "$vmid-$vmtype-$timestamp";

    log_info($self, "backup start hook called");

    my $root = $self->{scfg}->{path};
    die "backup storage '$root' is not a directory\n" if -l $root || !-d $root;
    my $final_dir = "$root/$archive";
    die "backup '$archive' already exists\n" if -e $final_dir || -l $final_dir;
    my $backup_dir = $final_dir;
    mkdir($backup_dir, 0750) or die "unable to create directory '$backup_dir' - $!\n";

    $self->{$vmid} = {
        'backup-dir' => $backup_dir,
        'final-dir' => $final_dir,
        archive => $archive,
    };
    check_sparse_support($backup_dir) if $vmtype eq 'qemu';

    return { 'archive-name' => $archive };
}

my sub publish_backup {
    my ($self, $vmid) = @_;

    # The container writer may run as a mapped UID without permission to rename
    # entries in the guest's parent directory. Publish from inside its own dir.
    file_set_contents("$self->{$vmid}->{'backup-dir'}/.complete", "1\n");
    return;
}

sub backup_cleanup {
    my ($self, $vmid, $vmtype, $success, $info) = @_;

    if ($success) {
	log_info($self, "backup cleanup called - success");
	my $size = 0;
	my $backup_dir = $self->{$vmid}->{'final-dir'};
        die "backup has not completed\n" if !defined($backup_dir) || !-f "$backup_dir/.complete";
        opendir(my $dh, $backup_dir) or die "unable to open '$backup_dir' - $!\n";
        for my $name (readdir($dh)) {
            my $file = "$backup_dir/$name";
            if (!-l $file && -f $file) {
                my @stat = stat($file);
                die "unable to stat '$file' - $!\n" if !@stat;
                $size += $stat[12] * 512;
            }
        }
        closedir($dh) or die "unable to close '$backup_dir' - $!\n";
	my $stats = { 'archive-size' => $size };
	return { 'stats' => $stats };
    } else {
	log_info($self, "backup cleanup called - failure");

	$self->{$vmid}->{failed} = 1;

        if (my $dir = $self->{$vmid}->{'backup-dir'}) {
            if (!-f "$dir/.complete") {
                my $errors;
                remove_tree($dir, { safe => 1, error => \$errors });
                for my $error ($errors->@*) {
                    log_warning($self, "unable to clean up $_ - $error->{$_}") for keys $error->%*;
                }
            }
        }
    }
}

sub backup_container_prepare {
    my ($self, $vmid, $info) = @_;

    my $dir = $self->{$vmid}->{'backup-dir'};
    chown($info->{'backup-user-id'}, -1, $dir) or die "unable to change owner for $dir\n";

    return;
}

sub backup_vm_query_incremental {
    my ($self, $vmid, $volumes) = @_;

    # Required API hook: undef requests the complete contents of every volume.
    return;
}

sub backup_get_mechanism {
    my ($self, $vmid, $vmtype) = @_;

    return 'directory' if $vmtype eq 'lxc';
    return $self->{'storage-plugin'}->get_vm_backup_mechanism($self->{scfg}) if $vmtype eq 'qemu';

    die "unsupported guest type '$vmtype'\n";
}

sub backup_handle_log_file {
    my ($self, $vmid, $filename) = @_;

    my $log_dir = $self->{$vmid}->{'final-dir'};
    return if !defined($log_dir); # initialization may have failed before creating an archive
    if ($self->{$vmid}->{failed}) {
	$log_dir .= ".failed";
    }
    make_path($log_dir);
    die "unable to create directory $log_dir\n" if !-d $log_dir;

    my $data = file_get_contents($filename);
    my $target = "${log_dir}/backup.log";
    file_set_contents($target, $data);
}

# Copy a complete raw image, handling short I/O without skipping any bytes.
# The destination must be a new regular file; zero blocks can remain sparse.
sub _copy_full_image {
    my ($self, $in_fh, $out_fh, $size, $bandwidth_limit, $progress) = @_;

    sysseek($in_fh, 0, SEEK_SET) // die "unable to seek backup source - $!\n";
    sysseek($out_fh, 0, SEEK_SET) // die "unable to seek backup target - $!\n";
    my $started = time();
    my $offset = 0;
    my $skip_discard;
    my $buffer;
    while ($offset < $size) {
        my $length = $size - $offset;
        $length = 4 * 1024 * 1024 if $length > 4 * 1024 * 1024;
        my $read = sysread($in_fh, $buffer, $length);
        next if !defined($read) && $! == EINTR;
        die "failed to read from backup source - $!\n" if !defined($read);
        die "premature EOF while reading backup source\n" if !$read;

        if ($buffer eq "\0" x $read) {
            sysseek($out_fh, $offset + $read, SEEK_SET)
                // die "unable to seek backup target - $!\n";
        } else {
            my $written = 0;
            while ($written < $read) {
                my $res = syswrite($out_fh, $buffer, $read - $written, $written);
                next if !defined($res) && $! == EINTR;
                die "failed to write to backup target - $!\n" if !defined($res);
                die "unable to progress writing to backup target\n" if !$res;
                $written += $res;
            }
        }

        if (!$skip_discard) {
            eval { PVE::Storage::Common::deallocate($in_fh, $offset, $read); };
            if (my $err = $@) {
                log_warning($self, "discard source failed (skipping further discards) - $err");
                $skip_discard = 1;
            }
        }
        $offset += $read;
        if ($bandwidth_limit) {
            my $delay = $offset / $bandwidth_limit - (time() - $started);
            sleep($delay) if $delay > 0;
        }
        $progress->(100 * $offset / $size) if $progress;
    }
    truncate($out_fh, $size) or die "unable to set backup target size - $!\n";
    $out_fh->sync() or die "unable to synchronize backup target - $!\n";
    return;
}

my sub backup_progress {
    my ($self, $device_name) = @_;

    my $started = time();
    my $last_time = $started;
    my $last_percent = -1;
    return sub {
        my ($percent, $complete) = @_;

        # qemu-img can report 100% before the final write/flush or exit status.
        return if !$complete && $percent >= 100;
        $percent = int($percent);
        return if $percent <= $last_percent;
        my $now = time();
        return if $last_percent >= 0 && !$complete && $now - $last_time < 3;

        log_info($self, sprintf('%s: backup progress %d%% (%ds)',
            $device_name, $percent, int($now - $started)));
        $last_time = $now;
        $last_percent = $percent;
    };
}

my sub backup_file {
    my ($self, $vmid, $device_name, $size, $in_fh, $bandwidth_limit, $progress) = @_;

    my $target = "$self->{$vmid}->{'backup-dir'}/${device_name}.raw";
    my $out_fh = IO::File->new($target, O_RDWR | O_CREAT | O_EXCL, 0600)
        or die "unable to create backup target '$target' - $!\n";
    eval {
        $self->_copy_full_image($in_fh, $out_fh, $size, $bandwidth_limit, $progress);
        $out_fh->close() or die "unable to close backup target '$target' - $!\n";
    };
    my $err = $@;
    $out_fh->close() if defined(fileno($out_fh));
    die $err if $err;
}

my sub backup_nbd {
    my ($self, $vmid, $device_name, $size, $nbd_path, $bandwidth_limit, $progress) = @_;

    my $source = "nbd:unix:${nbd_path}:exportname=${device_name}";
    my $target = "$self->{$vmid}->{'backup-dir'}/${device_name}.raw";
    # Copy the raw export while retaining holes; no image-format conversion.
    my $cmd = ['qemu-img', 'convert', '-p', '-f', 'raw', '-O', 'raw', '-S', '4k'];
    push $cmd->@*, '-r', $bandwidth_limit if $bandwidth_limit;
    push $cmd->@*, $source, $target;
    run_command($cmd, outfunc => sub {
        my ($line) = @_;
        if ($line =~ m/^\s*\((\d+(?:\.\d+)?)\/100%\)\s*$/) {
            $progress->($1);
        } elsif ($line =~ m/\S/) {
            log_info($self, "$device_name: $line");
        }
    });
    my $actual_size = PVE::Storage::Plugin::file_size_info($target, undef, 'raw', 1);
    die "backup image size does not match source size\n"
        if !defined($actual_size) || $actual_size != $size;
}

my sub backup_vm_volume {
    my ($self, $vmid, $device_name, $info, $bandwidth_limit) = @_;

    die "invalid backup device name '$device_name'\n"
        if $device_name !~ m/\A[a-zA-Z0-9_-]+\z/;
    die "invalid backup volume size\n" if !defined($info->{size}) || $info->{size} !~ m/\A\d+\z/;
    die "only full volume backups are supported\n"
        if defined($info->{'bitmap-mode'}) && $info->{'bitmap-mode'} ne 'none';

    my $mechanism = $self->{'storage-plugin'}->get_vm_backup_mechanism($self->{scfg});
    my $progress = backup_progress($self, $device_name);
    $progress->(0);
    if ($mechanism eq 'nbd') {
        backup_nbd($self, $vmid, $device_name, $info->{size}, $info->{'nbd-path'}, $bandwidth_limit,
            $progress);
    } elsif ($mechanism eq 'file-handle') {
        backup_file($self, $vmid, $device_name, $info->{size}, $info->{'file-handle'}, $bandwidth_limit,
            $progress);
    } else {
        die "unknown VM backup mechanism '$mechanism'\n";
    }
    $progress->(100, 1);
}

sub backup_vm {
    my ($self, $vmid, $guest_config, $volumes, $info) = @_;

    my $target = "$self->{$vmid}->{'backup-dir'}/guest.conf";
    file_set_contents($target, $guest_config);

    if (my $firewall_config = $info->{'firewall-config'}) {
	$target = "$self->{$vmid}->{'backup-dir'}/firewall.conf";
	file_set_contents($target, $firewall_config);
    }

    for my $device_name (sort keys $volumes->%*) {
	backup_vm_volume(
	    $self, $vmid, $device_name, $volumes->{$device_name}, $info->{'bandwidth-limit'});
    }
    publish_backup($self, $vmid);
}

my sub backup_directory_tar {
    my ($self, $vmid, $directory, $exclude_patterns, $sources, $bandwidth_limit) = @_;

    # essentially copied from PVE/VZDump/LXC.pm' archive()

    # copied from PVE::Storage::Plugin::COMMON_TAR_FLAGS
    my @tar_flags = qw(
	--one-file-system
	-p --sparse --numeric-owner --acls
	--xattrs --xattrs-include=user.* --xattrs-include=security.capability
	--warning=no-file-ignored --warning=no-xattr-write
    );

    my $tar = ['tar', 'cpf', '-', '--totals', @tar_flags];

    push @$tar, "--directory=$directory";

    my @exclude_no_anchored = ();
    my @exclude_anchored = ();
    for my $pattern ($exclude_patterns->@*) {
	if ($pattern !~ m|^/|) {
	    push @exclude_no_anchored, $pattern;
	} else {
	    push @exclude_anchored, $pattern;
	}
    }

    push @$tar, '--no-anchored';
    push @$tar, '--exclude=lost+found';
    push @$tar, map { "--exclude=$_" } @exclude_no_anchored;

    push @$tar, '--anchored';
    push @$tar, map { "--exclude=.$_" } @exclude_anchored;

    push @$tar, $sources->@*;

    my $cmd = [ $tar ];

    push @$cmd, [ 'cstream', '-t', $bandwidth_limit ] if $bandwidth_limit;

    my $target = "$self->{$vmid}->{'backup-dir'}/archive.tar";
    push @{$cmd->[-1]}, \(">" . PVE::Tools::shellquote($target));

    my $logfunc = sub {
	my $line = shift;
	log_info($self, "tar: $line");
    };

    PVE::Tools::run_command($cmd, logfunc => $logfunc);

    return;
};

sub backup_container {
    my ($self, $vmid, $guest_config, $exclude_patterns, $info) = @_;

    my $target = "$self->{$vmid}->{'backup-dir'}/guest.conf";
    file_set_contents($target, $guest_config);

    if (my $firewall_config = $info->{'firewall-config'}) {
	$target = "$self->{$vmid}->{'backup-dir'}/firewall.conf";
	file_set_contents($target, $firewall_config);
    }

    my $backup_mode = $self->{'storage-plugin'}->get_lxc_backup_mode($self->{scfg});
    if ($backup_mode eq 'tar') {
	backup_directory_tar(
	    $self,
	    $vmid,
	    $info->{directory},
	    $exclude_patterns,
	    $info->{sources},
	    $info->{'bandwidth-limit'},
	);
    } else {
	die "got unexpected backup mode '$backup_mode' from storage plugin\n";
    }
    publish_backup($self, $vmid);
}

# Restore API

my sub archive_directory {
    my ($self, $volname) = @_;

    my (undef, $relative) = $self->{'storage-plugin'}->parse_volname($volname);
    for my $dir ($self->{scfg}->{path}, "$self->{scfg}->{path}/$relative") {
        die "invalid backup directory '$dir'\n" if -l $dir || !-d $dir;
    }
    my $marker = "$self->{scfg}->{path}/$relative/.complete";
    die "backup '$volname' has not completed\n" if -l $marker || !-f $marker;
    return "$self->{scfg}->{path}/$relative";
}

my sub archive_file {
    my ($self, $volname, $name) = @_;

    my $file = archive_directory($self, $volname) . "/$name";
    die "refusing symbolic link archive file '$file'\n" if -l $file;
    return $file;
}

sub restore_get_mechanism {
    my ($self, $volname) = @_;

    my (undef, $relative_backup_dir) = $self->{'storage-plugin'}->parse_volname($volname);
    my ($vmtype) = $relative_backup_dir =~ m/\A[0-9]+-(qemu|lxc)-/;

    return ('qemu-img', $vmtype) if $vmtype eq 'qemu';

    if ($vmtype eq 'lxc') {
	if (-f archive_file($self, $volname, 'archive.tar')) {
	    $self->{'restore-mechanisms'}->{$volname} = 'tar';
	    return ('tar', $vmtype);
	}

	if (-f archive_file($self, $volname, 'archive.sqfs')) {
	    $self->{'restore-mechanisms'}->{$volname} = 'directory';
	    return ('directory', $vmtype)
	}

	die "unable to find archive '$volname'\n";
    }

    die "cannot restore unexpected guest type '$vmtype'\n";
}

sub archive_get_guest_config {
    my ($self, $volname) = @_;

    my $filename = archive_file($self, $volname, 'guest.conf');

    return file_get_contents($filename);
}

sub archive_get_firewall_config {
    my ($self, $volname) = @_;

    my $filename = archive_file($self, $volname, 'firewall.conf');

    return if !-e $filename;

    return file_get_contents($filename);
}

sub restore_vm_init {
    my ($self, $volname) = @_;

    my $res = {};

    my $backup_dir = archive_directory($self, $volname);
    opendir(my $dh, $backup_dir) or die "unable to open '$backup_dir' - $!\n";
    for my $name (sort readdir($dh)) {
        die "unsupported backup image format '$name' - only raw images are supported\n"
            if $name =~ m/\.qcow2\z/;
        next if $name !~ m/\A([a-zA-Z0-9_-]+)\.raw\z/;
        my $device = $1;
        my $file = archive_file($self, $volname, "$device.raw");
        die "backup image '$file' is not a regular file\n" if !-f $file;
        $res->{$device}->{size} = PVE::Storage::Plugin::file_size_info($file, undef, 'raw', 1);
    }
    closedir($dh) or die "unable to close '$backup_dir' - $!\n";

    return $res;
}

sub restore_vm_cleanup {
    my ($self, $volname) = @_;

    return; # restore reads the completed archive directly
}

sub restore_vm_volume_init {
    my ($self, $volname, $device_name, $info) = @_;

    die "invalid backup device name '$device_name'\n" if $device_name !~ m/\A[a-zA-Z0-9_-]+\z/;
    my $legacy = archive_directory($self, $volname) . "/$device_name.qcow2";
    die "unsupported backup image format - only raw images are supported\n" if -e $legacy || -l $legacy;
    my $image = archive_file($self, $volname, "$device_name.raw");
    die "backup image '$image' is not a regular file\n" if !-f $image;
    PVE::Storage::Plugin::file_size_info($image, undef, 'raw', 1);
    return { 'qemu-img-path' => $image };
}

sub restore_vm_volume_cleanup {
    my ($self, $volname, $device_name, $info) = @_;

    return; # the source is the backup itself and must never be removed
}

my sub restore_tar_init {
    my ($self, $volname) = @_;

    return { 'tar-path' => archive_file($self, $volname, 'archive.tar') };
}

my sub restore_directory_init {
    my ($self, $volname) = @_;

    my $archive = archive_file($self, $volname, 'archive.sqfs');
    my $mount_root = '/run/backup-provider-dir';
    make_path($mount_root, { mode => 0700 });
    my $mount_point = tempdir('restore-XXXXXXXX', DIR => $mount_root);
    eval { run_command(['mount', '-t', 'squashfs', '-o', 'ro,nodev,nosuid,noexec', $archive, $mount_point]); };
    if (my $err = $@) {
        rmdir($mount_point);
        die $err;
    }
    $self->{'restore-mounts'}->{$volname} = $mount_point;

    return { 'archive-directory' => $mount_point };
}

my sub restore_directory_cleanup {
    my ($self, $volname) = @_;

    my $mount_point = $self->{'restore-mounts'}->{$volname} or return;
    run_command(['umount', $mount_point]);
    rmdir($mount_point) or die "unable to remove mount point '$mount_point' - $!\n";
    delete $self->{'restore-mounts'}->{$volname};

    return;
}

sub restore_container_init {
    my ($self, $volname, $info) = @_;

    if ($self->{'restore-mechanisms'}->{$volname} eq 'tar') {
	return restore_tar_init($self, $volname);
    } elsif ($self->{'restore-mechanisms'}->{$volname} eq 'directory') {
	return restore_directory_init($self, $volname);
    } else {
	die "no restore mechanism set for '$volname'\n";
    }
}

sub restore_container_cleanup {
    my ($self, $volname, $info) = @_;

    if ($self->{'restore-mechanisms'}->{$volname} eq 'tar') {
	return; # nothing to do
    } elsif ($self->{'restore-mechanisms'}->{$volname} eq 'directory') {
	return restore_directory_cleanup($self, $volname);
    } else {
	die "no restore mechanism set for '$volname'\n";
    }
}

1;

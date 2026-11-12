# PVE Directory Backup

[English](README.md) | [简体中文](README_CN.md)

Create full backups of PVE virtual machines and containers in a directory: sparse raw images for VMs and tar archives for LXC.

Backups are stored directly under the storage path as `VMID-qemu-YYYY_MM_DD-HH_MM_SS` or `VMID-lxc-YYYY_MM_DD-HH_MM_SS`, using the node's local time.

## Installation and Reload

Run these commands as root from the project directory on your PVE node. Ensure no backup or restore tasks are running during installation and reload. In a cluster, install the plugin on every node that uses this storage.

If `make` is not installed, run `apt install make` first.

```sh
make check-pve
make install
systemctl reload pvedaemon pveproxy pvestatd pvescheduler
```

This installs the plugin and reloads the management services. No VM or host restart is required.

## Configuration

Create an empty directory on a filesystem that supports sparse files. The path must not be a symbolic link. VM backups check sparse-file support before writing disk data and stop if the check fails. Adjust the path below for your environment:

```sh
mkdir -p /mnt/directory-backups
```

Append the following to `/etc/pve/storage.cfg`:

```text
backup-provider-dir: directory-backups
    path /mnt/directory-backups
    vm-backup-mechanism nbd
    lxc-backup-mode tar
```

VM backups require fleecing. Add or update the following in `/etc/vzdump.conf`:

```text
fleecing: enabled=1,storage=local
```

`local` stores temporary disks. Choose storage that supports VM disks and has enough free space. This sets the node's backup default, which individual jobs can override. To enable Fleecing only for a specific job, configure it in that job's **Advanced** tab instead.

## Usage

Check the storage and run a backup, using VM 20021 as an example:

```sh
pvesm status --storage directory-backups
vzdump 20021 --storage directory-backups --mode stop \
    --fleecing enabled=1,storage=local
pvesm list directory-backups
```

For scheduled backup jobs, select `directory-backups` and ensure fleecing is enabled. No changes to VM configuration or loading of the kernel `nbd` module are required.

## Performance Comparison

Tested on PVE 9.2.26 / QEMU 11.1.3 using the same stopped VM: a 512 GiB logical disk with 5.70 GiB allocated. Source disks, backups, and restore targets shared one ext4 filesystem. Both formats used fleecing, no compression, and no bandwidth limit.

| Backup format | Full backup | Restore | Allocated backup size |
|---|---:|---:|---:|
| This plugin | 24.2 s | 5.2 s | 5.70 GiB |
| Native vzdump (VMA) | 461.9 s | 17.5 s | 5.77 GiB |

Each format was tested once for backup and restore. Times cover complete commands; separate `qemu-img compare` checks confirmed that the source disk and both restored disks matched the raw reference. Caches were not cleared; these results are specific to this machine and dataset.

Adapted from the [Proxmox Backup Provider patch](https://lore.proxmox.com/all/20250404133204.239783-9-f.ebner@proxmox.com/raw).

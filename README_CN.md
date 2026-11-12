# PVE Directory Backup

[English](README.md) | [简体中文](README_CN.md)

将 PVE 虚拟机和容器完整备份到目录：VM 使用稀疏 raw，LXC 使用 tar。

备份直接存放在存储根目录，命名为 `VMID-qemu-YYYY_MM_DD-HH_MM_SS` 或 `VMID-lxc-YYYY_MM_DD-HH_MM_SS`，时间使用节点的本地时区。

## 安装与重载

在 PVE 节点上，以 root 身份进入项目目录执行。安装和重载时应没有正在运行的备份、恢复任务；集群中每个使用该存储的节点都需安装。

未安装 `make` 时，先执行 `apt install make`。

```sh
make check-pve
make install
systemctl reload pvedaemon pveproxy pvestatd pvescheduler
```

这会安装插件并让管理服务重新加载，无需重启虚拟机或主机。

## 配置

创建一个支持稀疏文件的空目录，路径不能是符号链接。插件会在写入 VM 磁盘数据前检测稀疏文件支持，检测不通过则终止备份。以下路径按实际环境替换：

```sh
mkdir -p /mnt/directory-backups
```

在 `/etc/pve/storage.cfg` 中追加：

```text
backup-provider-dir: directory-backups
    path /mnt/directory-backups
    vm-backup-mechanism nbd
    lxc-backup-mode tar
```

VM 备份需要启用 fleecing。在 `/etc/vzdump.conf` 中增加或修改：

```text
fleecing: enabled=1,storage=local
```

`local` 用于存放临时磁盘，应选择支持虚拟机磁盘且空间充足的存储。此配置是节点的备份默认值，任务设置可以覆盖它；若只对指定任务启用，可改在该任务的“高级”选项中配置 Fleecing。

## 使用

检查存储，并以 VM 20021 为例执行备份：

```sh
pvesm status --storage directory-backups
vzdump 20021 --storage directory-backups --mode stop \
    --fleecing enabled=1,storage=local
pvesm list directory-backups
```

定时备份任务选择 `directory-backups`，并确保 fleecing 已开启。无需修改 VM 配置或加载内核 `nbd` 模块。

## 性能对比

PVE 9.2.26 / QEMU 11.1.3，同一台停止状态的 VM，磁盘逻辑容量 512 GiB、实际占用 5.70 GiB。源磁盘、备份和恢复目标位于同一 ext4 文件系统；均启用 Fleecing、不压缩、不限速。

| 备份方式 | 全量备份 | 恢复 | 备份实际占用 |
|---|---:|---:|---:|
| 本插件 | 24.2 秒 | 5.2 秒 | 5.70 GiB |
| 原生 vzdump（VMA，无压缩） | 461.9 秒 | 17.5 秒 | 5.77 GiB |

每种方式各测一次，计时包含完整命令，磁盘校验另计；备份与原始磁盘及两种恢复结果的内容比对均通过。未清空系统缓存，结果仅代表本机及此稀疏磁盘，实际速度取决于存储、数据分布和缓存。

基于 [Proxmox Backup Provider 补丁](https://lore.proxmox.com/all/20250404133204.239783-9-f.ebner@proxmox.com/raw) 改造。

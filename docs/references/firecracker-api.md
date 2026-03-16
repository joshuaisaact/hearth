# Reference: Firecracker API

**Source**: https://github.com/firecracker-microvm/firecracker

## Overview

Firecracker exposes a REST API over a Unix socket for VM configuration and lifecycle management. The API must be called in a specific order before the VM can start.

## Key Endpoints

### Machine Config
```
PUT /machine-config
{
  "vcpu_count": 2,
  "mem_size_mib": 256,
  "smt": false
}
```

### Boot Source
```
PUT /boot-source
{
  "kernel_image_path": "/path/to/vmlinux",
  "boot_args": "console=ttyS0 reboot=k panic=1 pci=off"
}
```

### Block Devices (rootfs)
```
PUT /drives/rootfs
{
  "drive_id": "rootfs",
  "path_on_host": "/path/to/rootfs.ext4",
  "is_root_device": true,
  "is_read_only": false
}
```

### Network
```
PUT /network-interfaces/eth0
{
  "iface_id": "eth0",
  "guest_mac": "AA:FC:00:00:00:01",
  "host_dev_name": "tap0"
}
```

### vsock
```
PUT /vsock
{
  "guest_cid": 3,
  "uds_path": "/path/to/vsock.sock"
}
```

### Start
```
PUT /actions
{ "action_type": "InstanceStart" }
```

### Snapshot Create
```
PUT /snapshot/create
{
  "snapshot_type": "Full",
  "snapshot_path": "/path/to/vmstate.snap",
  "mem_file_path": "/path/to/memory.snap"
}
```

### Snapshot Restore (on boot)
```
firecracker --restore-from-snapshot /path/to/vmstate.snap \
            --mem-file-path /path/to/memory.snap
```

## Configuration Order

1. Machine config
2. Boot source
3. Drives
4. Network interfaces
5. vsock
6. InstanceStart

All config must be set before InstanceStart. After start, only a limited set of endpoints accept updates.

## Jailer

The jailer wraps the Firecracker process with:
- chroot into a dedicated directory
- seccomp-bpf filter (whitelist of allowed syscalls)
- cgroup placement (CPU, memory limits)
- UID/GID mapping

```
jailer --id vm-001 \
       --exec-file /usr/bin/firecracker \
       --uid 1000 --gid 1000 \
       --chroot-base-dir /srv/jailer
```

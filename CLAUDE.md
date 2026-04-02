# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repo contains bash scripts and Ansible for setting up Raspberry Pi netboot infrastructure. The flow is:

1. `extract-img` — downloads an Ubuntu ARM64 preinstalled image (`.img.xz`), extracts it, mounts it via `kpartx`, and rsyncs the root/boot partitions to `/exports/netboot/<name>/`
2. `customize-img` — calls `extract-img`, then modifies the extracted filesystem for NFS netboot: sets `cmdline.txt` to boot via NFS, updates `/etc/fstab`, disables growroot, installs the `hooks/overlayroot-nfs` initramfs hook, and rebuilds the initramfs via `systemd-nspawn`

## Repository layout

```
customize-img          # entry point: build a netboot image
extract-img            # helper: download + extract Ubuntu ARM64 image
hooks/
  overlayroot-nfs      # initramfs hook — sets up overlayfs on boot
  overlayroot-nfs-sync # systemd shutdown service — syncs tmpfs upper to NFS state store
serve-cloud-init/
  main.go              # HTTP server for per-node cloud-init seed data
  cloud-init/          # per-node seed files (meta-data + user-data), keyed by serial
ansible/               # kickstart host provisioning (packages, NFS, TFTP, cloud-init service)
  group_vars/all.yml   # shared vars (subnet = 10.0.60.0/24)
  host_vars/           # per-node config (node_serial, nfs_fsid)
  inventory.ini        # production inventory
  inventory-vm.ini     # VM test environment inventory
setup/
  kickstart/           # cloud-init seed files for flashing kickstart SD card
vms/                   # Lima VM test environment (kickstart + node) — TEST ONLY
tmp/                   # gitignored local runtime artifacts (cache, exports)
```

## Running the scripts

All scripts require `sudo` / root. They must be run on the Linux server acting as the netboot host (not macOS).

The Lima VM environment (`vms/`) is a **test environment only**. Production image builds and serving run on `kickstart.tynet.us` (aarch64 Raspberry Pi).

```bash
# Extract and customize an image for netboot
sudo ./customize-img [kickstart_ip] [serial] [hostname]

# Or via Makefile targets (run on kickstart host):
make pi2
make pi3
```

## Network

- **Kickstart host**: `kickstart.tynet.us`, DHCP reservation `10.0.60.100`
- **Pi nodes**: pi1–pi3, DHCP reservations `10.0.60.201`–`10.0.60.203` (managed in Unifi)
- **Subnet**: `10.0.60.0/24`, gateway `10.0.60.1`
- Node IPs are NOT hardcoded in cloud-init — managed as Unifi DHCP reservations

## Dependencies

- `kpartx`, `wget`, `unxz`, `rsync` — for image extraction
- `systemd-container` — for initramfs rebuild via `systemd-nspawn`
- `nfs-server`, `rpcbind`, `tftpd-hpa` — for serving (managed by Ansible)
- Ubuntu ARM64 preinstalled server images from `cdimage.ubuntu.com`

## Key design details

- Scripts write human-readable output to **stderr** and machine-readable output (paths) to **stdout**.
- The default image is Ubuntu 22.04 snapshot (arm64). The destination defaults to `/exports/netboot/<image-basename>`.
- `extract-img` caches the downloaded `.img` in `/var/cache/img/` and skips re-download if already present. rsync exit code 23 (partial transfer due to special files) is treated as success.
- `customize-img` validates that `root_dir` points to a real OS tree (`usr/` present) before modifying anything — prevents host corruption if `extract-img` fails.
- The boot partition is served via TFTP; the root partition is served via NFSv3.
- Server-side configuration (NFS exports, TFTP dirs, overlay dirs, cloud-init service) is handled entirely by Ansible — the shell scripts only build the image.
- The NFS root `cmdline.txt` uses `ds=nocloud;s=http://<kickstart_ip>:8000/<serial>/` for cloud-init.
- NFS exports use `10.0.60.0/24` subnet restriction (not per-node IPs) — set in `ansible/group_vars/all.yml`.

## Overlay filesystem design

Each node runs overlayfs with:
- **lower**: read-only NFS root (`/exports/netboot/ubuntu-22.04`)
- **upper**: tmpfs (RAM-backed) — required because Linux 6.x needs `RENAME_WHITEOUT` on upper, which NFS doesn't support
- **state store**: per-node NFS share (`/exports/overlay/<hostname>/`) — upper layer is synced here on shutdown and restored on boot

### overlayroot-nfs (initramfs hook)

Runs as `init-bottom` — after NFS root is mounted, before `pivot_root`. Steps:
1. Reads `overlay_host=` and kickstart IP from `nfsroot=` in kernel cmdline
2. Mounts `<kickstart>:/exports/overlay/<hostname>` (NFSv3, rw) as the NFS state store
3. Creates tmpfs with `upper/` and `work/` subdirs
4. Copies saved state from NFS state store into tmpfs upper (state restore)
5. Bind-mounts NFS root as read-only lower layer
6. Mounts overlayfs at `rootmnt`
7. Moves all sub-mounts into the new root before `pivot_root`
8. Falls back to plain NFS root if any step fails

### overlayroot-nfs-sync (shutdown service)

Systemd service that runs before halt/reboot/shutdown. Rsyncs the live tmpfs upper layer back to `/exports/overlay/<hostname>/upper/` on the kickstart host, persisting writes across reboots.

### systemd-nspawn for initramfs rebuild

`customize-img` rebuilds the initramfs inside the extracted image using `systemd-nspawn` (not bare `chroot`) because:
- nspawn auto-mounts `/proc`, `/sys`, and `/dev` — required by `update-initramfs`
- nspawn requires `/dev` to be a pre-mounted filesystem; `customize-img` mounts a tmpfs on `<root>/dev` before spawning
- The tmpfs on `/dev` is cleaned up via a `trap` on function return (nspawn unmounts it on exit, so the trap uses `|| true`)

## Node inventory

| Hostname          | Serial   | MAC               | IP (DHCP reservation) |
|-------------------|----------|-------------------|----------------------|
| kickstart.tynet.us | —       | dc:a6:32:80:79:52 | 10.0.60.100          |
| pi1.tynet.us      | ad36c642 | —                 | 10.0.60.201          |
| pi2.tynet.us      | 244634d3 | dc:a6:32:8d:f3:ca | 10.0.60.202          |
| pi3.tynet.us      | a43386be | dc:a6:32:80:2a:cc | 10.0.60.203          |

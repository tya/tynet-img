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
vms/                   # Lima VM test environment (kickstart + node)
tmp/                   # gitignored local runtime artifacts (cache, exports)
```

## Running the scripts

All scripts require `sudo` / root. They must be run on the Linux server acting as the netboot host (not macOS).

```bash
# Extract and customize an image for netboot
sudo ./customize-img [kickstart_ip] [serial] [hostname]

# Just extract an image (outputs the root dir path to stdout)
sudo ./extract-img [url] [destination_dir]
```

## Dependencies

- `kpartx`, `wget`, `unxz`, `rsync` — for image extraction
- `systemd-container`, `qemu-user-static` — for cross-arch initramfs rebuild via `systemd-nspawn`
- `nfs-server`, `rpcbind`, `tftpd-hpa` — for serving (managed by Ansible)
- Ubuntu ARM64 preinstalled server images from `cdimage.ubuntu.com`

## Key design details

- Scripts write human-readable output to **stderr** and machine-readable output (paths) to **stdout**.
- The default image is Ubuntu 26.04 snapshot (arm64). The destination defaults to `/exports/netboot/<image-basename>`.
- `extract-img` caches the downloaded `.img` in `/var/cache/img/` and skips re-download if already present. rsync exit code 23 (partial transfer due to special files) is treated as success.
- `customize-img` validates that `root_dir` points to a real OS tree (`usr/` present) before modifying anything — prevents host corruption if `extract-img` fails.
- `systemd-nspawn` is used (not bare `chroot`) to rebuild the initramfs inside the ARM64 image. It mounts a fresh tmpfs on `/dev` before spawning to satisfy nspawn's requirement that `/dev` be a pre-mounted filesystem.
- The boot partition is served via TFTP using a bind-mount (managed by Ansible); the root partition is served via NFSv3.
- Server-side configuration (NFS exports, TFTP bind-mounts, overlay dirs, cloud-init service) is handled entirely by Ansible — the shell scripts only build the image.
- The NFS root `cmdline.txt` uses `ds=nocloud;s=http://<kickstart_ip>:8000/<serial>/` for cloud-init.

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repo contains bash scripts for setting up Raspberry Pi netboot infrastructure. The flow is:

1. `extract-img` — downloads an Ubuntu ARM64 preinstalled image (`.img.xz`), extracts it, mounts it via `kpartx`, and rsyncs the root/boot partitions to `/exports/netboot/<name>/`
2. `customize-img` — calls `extract-img`, then modifies the extracted filesystem for NFS netboot: sets `cmdline.txt` to boot via NFS, updates `/etc/fstab`, disables growroot, and refreshes RPi firmware files from GitHub
3. `serve-img` — calls `customize-img`, then configures NFS exports (`/etc/exports`) and bind-mounts the boot dir into tftpd's serving directory (`/srv/tftpboot/<serial>`), then restarts `rpcbind`, `nfs-server`, and `tftpd-hpa`
4. `configure-tftp` — one-time setup to install and configure `tftpd-hpa`

`.bak` is an older monolithic script (using env vars like `PI_SERIAL`, `PI_MAC`, etc.) that predates the current modular scripts — kept for reference.

## Running the scripts

All scripts require `sudo` / root. They must be run on the Linux server acting as the netboot host (not macOS).

```bash
# One-shot: extract, customize, and serve a new image
sudo ./serve-img [tftp_dir] [node_ip_cidr]

# Just extract an image (outputs the root dir path to stdout)
sudo ./extract-img [url] [destination_dir]

# Customize an already-extracted image
sudo ./customize-img [kickstart_ip]
```

## Dependencies

- `kpartx`, `wget`, `unxz`, `rsync` — for image extraction
- `nfs-server`, `rpcbind`, `tftpd-hpa` — for serving
- Ubuntu ARM64 preinstalled server images from `cdimage.ubuntu.com`

## Key design details

- Scripts write human-readable output to **stderr** and machine-readable output (paths) to **stdout**, enabling chaining via shell `read`.
- The default image is Ubuntu 26.04 snapshot (arm64). The destination defaults to `/exports/netboot/<image-basename>`.
- `extract-img` caches the downloaded `.img` in `/var/cache/img/` and skips re-download if already present.
- `customize-img` fetches fresh `start4.elf` and `fixup4.dat` from the `raspberrypi/rpi-firmware` GitHub repo at customize time.
- The boot partition is served via TFTP using a bind-mount (entry added to `/etc/fstab`); the root partition is served via NFSv3.
- The NFS root `cmdline.txt` uses `ds=nocloud;s=http://10.0.10.13:8000/` for cloud-init.

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repo contains bash scripts for building Raspberry Pi netboot images and provisioning nodes. It is bash-only — no Ansible. Kickstart host provisioning (packages, services, NFS config) lives in `../tynet-infra`.

The flow is:

1. `extract-img <nfs_release>` — downloads an Ubuntu ARM64 preinstalled image, extracts it to `/exports/netboot/<nfs_release>/`
2. `customize-img <nfs_release>` — calls `extract-img`, then modifies the shared base image for NFS netboot: fstab, netplan, cloud-init network config, overlayroot-nfs initramfs hook, initramfs rebuild. **Node-agnostic** — no per-node params.
3. `build-node <hostname>` — provisions a single node's TFTP directory: syncs boot files from the base image, writes `cmdline.txt`, creates overlay dirs. Reads config from `tynet.env`.

## Repository layout

```
customize-img          # customize shared base image for NFS netboot (node-agnostic)
extract-img            # download + extract Ubuntu ARM64 image
build-node             # provision per-node TFTP dir + overlay dirs
tynet.env             # node inventory (MACs, serials, IPs, releases) — bash-sourceable
hooks/
  overlayroot-nfs      # initramfs hook — sets up overlayfs on boot
  overlayroot-nfs-sync # systemd shutdown service — syncs tmpfs upper to NFS state store
serve-cloud-init/
  main.go              # HTTP server for per-node cloud-init seed data
  cloud-init/          # per-node seed files (meta-data + user-data), keyed by serial
vms/                   # Lima VM test environment (kickstart + node) — TEST ONLY
tmp/                   # gitignored local runtime artifacts (cache, exports)
```

Kickstart host provisioning (packages, tftpd, NFS, cloud-init service) lives in `../tynet-infra` — run `make kickstart` from there.

## Running the scripts

All scripts require `sudo` / root. They must be run on the kickstart host (`kickstart.tynet.us`, Linux aarch64).

The Lima VM environment (`vms/`) is a **test environment only**.

```bash
# Build the shared base image (once per release):
sudo ./customize-img ubuntu-22.04
sudo ./customize-img ubuntu-26.04

# Provision a node's TFTP dir (after customize-img):
sudo ./build-node pi2.tynet.us
sudo ./build-node pi3.tynet.us

# Or via Makefile:
make ubuntu-22.04     # build base image
make pi2              # provision pi2 TFTP dir
make pi               # provision all nodes
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

- Scripts write human-readable output to **stderr** only. `customize-img` and `build-node` do not write to stdout.
- `extract-img` takes a release name (`ubuntu-22.04`, `ubuntu-26.04`); the URL map is inside the script. Add new releases there.
- `extract-img` caches the downloaded `.img` in `/var/cache/img/` and skips re-download if already present. rsync exit code 23 (partial transfer due to special files) is treated as success.
- `customize-img` validates that `root_dir` (`/exports/netboot/<release>/`) contains `usr/` before modifying — prevents host corruption if extraction fails.
- `customize-img` is **node-agnostic**: it customizes the shared base image only. No `serial`, `hostname`, or `overlay_dev` params.
- `build-node` reads all per-node config from `tynet.env` (sourced as bash). To add a node: add a `NODE_<SHORTNAME>_*` block to `tynet.env` and re-run `make kickstart` in tynet-infra to update `/etc/exports`.
- TFTP dirs are keyed by MAC address (`/srv/tftpboot/<mac>/`) matching Pi EEPROM `TFTP_PREFIX=2` behaviour.
- `cmdline.txt` uses `ds=nocloud;s=http://<kickstart_ip>:8000/<serial>/` for cloud-init.
- NFS exports use `10.0.60.0/24` subnet restriction — managed by Ansible kickstart role in tynet-infra (`group_vars/all.yml`).

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

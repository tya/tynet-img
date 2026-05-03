# tynet-img

Scripts for building Raspberry Pi netboot images and provisioning nodes. Bash-only — kickstart host provisioning (packages, services, NFS config) lives in `../tynet-infra`.

## How it works

A Pi boots over the network by fetching its kernel and boot files via TFTP, then mounting its root filesystem over NFS. Each node gets a persistent writable overlay over the shared read-only base image. cloud-init runs on first boot.

```
Pi (power on)
  └── DHCP  → gets TFTP server IP from UniFi (option 66)
  └── TFTP  → /srv/tftpboot/<mac>/            (boot files + cmdline.txt)
  └── NFS   → /exports/netboot/<release>/     (shared read-only root)
  └── NFS   → /exports/overlay/<hostname>/   (per-node state store)
  └── HTTP  → :8000/<serial>/                 (cloud-init user-data + meta-data)
```

## Infrastructure

- **Kickstart host**: `kickstart.tynet.us` — Raspberry Pi aarch64, `10.0.60.100`
- **Pi VLAN**: `10.0.60.0/24`, gateway `10.0.60.1`
- **Pi nodes**: pi2–pi3, DHCP reservations `10.0.60.202`–`10.0.60.203` (managed in Unifi)
- **UniFi Network Boot**: DHCP option 66 = `10.0.60.100` on VLAN 60

## Scripts

### `extract-img [nfs_release]`

Downloads and extracts an Ubuntu ARM64 preinstalled image to `/exports/netboot/<nfs_release>/`.

- Release name maps to URL via `IMAGE_URLS` table inside the script — add new releases there
- Caches the downloaded `.img` in `/var/cache/img/` — re-runs after a failed build are fast
- Skips extract if destination is already populated

```bash
sudo ./extract-img ubuntu-22.04
sudo ./extract-img ubuntu-26.04
```

### `customize-img [nfs_release]`

Modifies the shared base image at `/exports/netboot/<nfs_release>/` for NFS netboot. **Node-agnostic** — run once per release, not per node.

- Calls `extract-img` to ensure the base image exists
- Empties `/etc/fstab` — prevents systemd from remounting the NFS root over the overlay
- Disables growroot
- Writes netplan config for eth0 DHCP with `critical: true`
- Disables cloud-init network management (handled by netplan)
- Flattens `os_prefix=current/` boot layout for TFTP compatibility
- Downloads Pi 4 firmware (`start4.elf`, `fixup4.dat`) into the boot dir
- Installs `overlayroot-nfs` initramfs hook (dracut or initramfs-tools, auto-detected)
- Installs `overlayroot-nfs-sync` shutdown service
- Rebuilds initramfs via `systemd-nspawn`
- Validates the hook is present in the rebuilt initramfs

```bash
sudo ./customize-img ubuntu-22.04
sudo ./customize-img ubuntu-26.04

# Or via Makefile:
make ubuntu-22.04
make ubuntu-26.04
```

### `build-node <hostname>`

Provisions a single node's TFTP directory and overlay dirs. Reads all config from `tynet.env`.

- Syncs boot files from `/exports/netboot/<release>/boot/` → `/srv/tftpboot/<mac>/`
- Writes per-node `/srv/tftpboot/<mac>/cmdline.txt` (NFS root, overlay_host, overlay_dev, netconsole, cloud-init URL)
- Creates `/exports/overlay/<hostname>/upper` and `/exports/overlay/<hostname>/work`

```bash
sudo ./build-node pi2.tynet.us
sudo ./build-node pi3.tynet.us

# Or via Makefile:
make pi2
make pi3
make pi   # all nodes
```

### `tynet.env` (generated)

Bash-sourceable node inventory. Used by `build-node`, `check-status`,
`check-boot-config`, and `verify-boot`.

**Source of truth lives in `../tynet-infra`.** The real `tynet.env` is
rendered onto the kickstart host by the kickstart Ansible role from
`tynet-infra/inventory/group_vars/all.yml` and
`tynet-infra/inventory/host_vars/<host>.yml`. To change a node's config,
edit those files and re-run `make kickstart` in tynet-infra. The file is
gitignored in this repo; `tynet.env.example` documents the format for
reference.

```bash
KICKSTART_IP=10.0.60.100
KICKSTART_MAC=dca632807952

NODES=(pi2 pi3)

NODE_PI2_SERIAL=244634d3
NODE_PI2_MAC=dc-a6-32-8d-f3-ca
NODE_PI2_IP=10.0.60.202
NODE_PI2_RELEASE=ubuntu-22.04

NODE_PI3_SERIAL=a43386be
NODE_PI3_MAC=dc-a6-32-80-2a-cc
NODE_PI3_IP=10.0.60.203
NODE_PI3_RELEASE=ubuntu-26.04
NODE_PI3_OVERLAY_DEV=/dev/sda1   # optional: SSD upper layer
```

### `serve-cloud-init`

Go program serving per-node cloud-init seed data over HTTP on port 8000.
Managed as a systemd service by the kickstart Ansible role in tynet-infra.

```bash
./serve-cloud-init -dir ~/src/tynet-img/serve-cloud-init/cloud-init
```

Seed files (`meta-data`, `user-data`, `network-config`, `vendor-data`) live in
`serve-cloud-init/cloud-init/<serial>/` — **rendered by tynet-infra Ansible**
from inventory plus `keys/*.pub`. The directory is gitignored; canonical
fixtures used by `go test` are in `serve-cloud-init/testdata/cloud-init/`.

## Overlay filesystem

Each Pi runs overlayfs for a writable root without modifying the shared base:

```
overlayfs (visible root)
  ├── upper  →  tmpfs or SSD  (writable layer)
  └── lower  →  NFS           (shared read-only base image)
```

The upper layer is tmpfs by default (Linux 6.x requires `RENAME_WHITEOUT` support on upper, which NFS lacks). If `overlay_dev=/dev/sda1` is set in `tynet.env`, the `overlayroot-nfs` hook mounts the SSD as upper instead.

### State persistence (tmpfs mode)

`overlayroot-nfs-sync` runs at shutdown and rsyncs the tmpfs upper to `/exports/overlay/<hostname>/upper/` on kickstart. On next boot the initramfs hook restores it into a fresh tmpfs before mounting the overlay.

### initramfs hook

`overlayroot-nfs` (or the dracut equivalent) runs as `init-bottom` — after NFS root is mounted, before `pivot_root`. It sets up the overlay stack and falls back to plain NFS root on any failure.

`customize-img` rebuilds the initramfs with `systemd-nspawn` (not bare chroot) because nspawn auto-mounts `/proc`, `/sys`, `/dev` that `update-initramfs` requires.

## Kickstart host provisioning

Kickstart host setup (packages, tftpd, NFS exports, cloud-init service) is managed by Ansible in `../tynet-infra`:

```bash
cd ../tynet-infra
make kickstart       # provision kickstart host
make nodes           # deploy SSH host keys to Pi nodes (from 1Password)
make reboot-nodes    # graceful drain + reboot all nodes
```

NFS exports are auto-generated from `/exports/netboot/` release dirs. Re-run `make kickstart` after adding a new release.

## Makefile reference

Run on kickstart host:

```bash
make ubuntu-22.04        # build base image for ubuntu-22.04
make ubuntu-26.04        # build base image for ubuntu-26.04
make pi2                 # provision pi2.tynet.us TFTP dir
make pi3                 # provision pi3.tynet.us TFTP dir
make pi                  # provision all nodes

make update-base                      # apply security patches (default: ubuntu-22.04)
make update-base RELEASE=ubuntu-26.04

make wipe-overlay-pi2    # wipe pi2's overlay (node must be offline)
make wipe-all-overlays CONFIRM=yes

make status              # show per-node status (release, overlay mode, SSH key)
make console             # listen for netconsole boot messages
make logs                # show recent customize-img run history

make cycle-pi2           # power-cycle pi2 via Unifi PoE
make cycle-pi3           # power-cycle pi3 via Unifi PoE
```

## Provisioning a new node

```bash
# 1. Add node to tynet-infra inventory:
#    - tynet-infra/inventory/production.ini  (add to [nodes])
#    - tynet-infra/inventory/host_vars/<host>.yml  (serial, MAC, IP, release, fsid)

# 2. Add DHCP reservation in Unifi (MAC → IP)

# 3. Re-run kickstart Ansible — renders tynet.env + per-node cloud-init seed files,
#    updates NFS exports:
cd ../tynet-infra && make kickstart

# 4. Build base image if not already done:
make ubuntu-22.04    # or ubuntu-26.04

# 5. Provision the node's TFTP dir:
make pi2   # or whichever node

# 6. Deploy SSH host key:
cd ../tynet-infra && make nodes LIMIT=pi2.tynet.us

# 7. Power on — node netboots and runs cloud-init
```

## Logging

`customize-img` and `build-node` write timestamped logs to `/var/log/tynet-img/` on kickstart.

```bash
tail -f /var/log/tynet-img/latest.log   # follow live build
make logs                                # recent run history
```

## Node inventory

| Hostname           | Serial   | MAC               | IP            |
|--------------------|----------|-------------------|---------------|
| kickstart.tynet.us | —        | dc:a6:32:80:79:52 | 10.0.60.100   |
| pi2.tynet.us       | 244634d3 | dc:a6:32:8d:f3:ca | 10.0.60.202   |
| pi3.tynet.us       | a43386be | dc:a6:32:80:2a:cc | 10.0.60.203   |

## VM test environment

Lima-based two-VM stack for testing on Apple Silicon. **Test only** — production runs on kickstart.tynet.us.

```bash
cd vms
make start      # start kickstart + node VMs
make provision  # provision kickstart VM
make kickstart  # shell into kickstart VM
make node       # shell into node VM
make stop
```

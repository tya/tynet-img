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
  └── HTTP  → :8000/<mac>/                    (cloud-init user-data + meta-data)
```

## Infrastructure

- **Kickstart host**: `kickstart.tynet.us` — Raspberry Pi aarch64, `10.0.60.100`
- **Pi VLAN**: `10.0.60.0/24`, gateway `10.0.60.1`
- **Pi nodes**: pi2–pi3, DHCP reservations `10.0.60.202`–`10.0.60.203` (managed in Unifi)
- **UniFi Network Boot**: DHCP option 66 = `10.0.60.100` on VLAN 60

## Installation

`tynet-img` ships as a Debian `.deb` published to the [tynet-apt repository](https://tya.github.io/tynet-apt/) and installed on the kickstart host via Ansible in `../tynet-infra`. The package depends on `kpartx`, `wget`, `xz-utils`, `rsync`, `systemd-container`, `e2fsprogs`, `nfs-kernel-server`, `tftpd-hpa`, `rpcbind`, `openssh-client`, `curl`, and `iputils-ping`; apt pulls those in automatically.

```bash
# Bootstrap the tynet apt source (one-time, handled by tynet-infra Ansible):
curl -fsSL https://tya.github.io/tynet-apt/tynet-apt.gpg \
  | sudo tee /etc/apt/trusted.gpg.d/tynet.gpg >/dev/null
echo "deb [signed-by=/etc/apt/trusted.gpg.d/tynet.gpg] https://tya.github.io/tynet-apt stable main" \
  | sudo tee /etc/apt/sources.list.d/tynet.list

sudo apt-get update
sudo apt-get install tynet-img
```

In production this entire dance is done by `make kickstart` in `../tynet-infra`.

### What the package installs

| Path | Type | Notes |
|------|------|-------|
| `/usr/sbin/extract-img` | exec | Download + extract Ubuntu ARM64 image to `/exports/netboot/<release>/` |
| `/usr/sbin/customize-img` | exec | Customize a base image for NFS netboot (initramfs hook, netplan, fstab, …) |
| `/usr/sbin/build-node` | exec | Provision a single node's TFTP dir + overlay dirs |
| `/usr/bin/check-status` | exec | Per-node status table (release, overlay, SSH key, last sync) |
| `/usr/bin/check-boot-config` | exec | Validate TFTP + NFS config before rebooting |
| `/usr/bin/verify-boot` | exec | Power-cycle + verify full netboot chain |
| `/usr/bin/check-netboot` | exec | Show recent TFTP/NFS activity from journal |
| `/usr/share/tynet-img/hooks/` | data | initramfs hooks (`overlayroot-nfs`, `overlayroot-nfs-sync`, dracut variants) injected into Pi images by `customize-img` |
| `/lib/systemd/system/update-base.service` | unit | Apply security patches to every release in `/exports/netboot/` via `systemd-nspawn` |
| `/lib/systemd/system/update-base.timer` | unit | Daily at 03:00 (randomized ±30min), enabled by postinst |
| `/etc/default/tftpd-hpa` | conffile | `TFTP_DIRECTORY=/srv/tftpboot`, `--secure` |
| `/etc/logrotate.d/tynet-img` | conffile | Rotate `/var/log/tynet-img/*.log` daily, keep 30 days |
| `/etc/tynet-img/` | dir | Holds `tynet.env`; Ansible renders the file at `0600 root:root` |
| `/usr/share/doc/tynet-img/` | docs | `README.md`, `copyright`, `changelog.gz`, `tynet.env.example`, `Makefile.reference` |
| `/usr/share/lintian/overrides/tynet-img` | data | Suppresses expected lintian warnings |

### Runtime directories (created by postinst)

| Path | Purpose |
|------|---------|
| `/srv/tftpboot/` | TFTP root (each node gets `/srv/tftpboot/<mac>/`) |
| `/exports/netboot/` | NFS root for shared read-only base images (per-release subdir) |
| `/exports/overlay/` | NFS state store for per-node overlay upper layers (tmpfs mode) |
| `/var/log/tynet-img/` | Logs from `customize-img` and `build-node` |
| `/var/cache/img/` | Cached `.img.xz` downloads — survives runs |

### Services enabled by postinst

- `rpcbind.service`, `nfs-server.service`, `tftpd-hpa.service` (the netboot path)
- `update-base.timer` (daily patch loop)

The `prerm` script stops `update-base.timer` on removal but leaves NFS/TFTP/rpcbind running — they're shared infrastructure that other tools on the host depend on.

### Release pipeline

Tags on `tya/tynet-img` matching `v*` trigger `.github/workflows/release.yml`: `nfpm` builds the `.deb`, `gh release create` attaches it, and a `repository_dispatch` event notifies `tya/tynet-apt` which signs and indexes the package on `gh-pages`. The `APT_DISPATCH_TOKEN` secret must be set on the repo for the dispatch step to work; if not, fire it manually:

```bash
gh api -X POST /repos/tya/tynet-apt/dispatches \
  -f event_type=new-release \
  -F 'client_payload[repo]=tya/tynet-img' \
  -F 'client_payload[tag]=vX.Y.Z' \
  -F 'client_payload[package]=tynet-img' \
  -F 'client_payload[asset_url]=https://github.com/tya/tynet-img/releases/download/vX.Y.Z/tynet-img_X.Y.Z_arm64.deb'
```

## Scripts

After install, all commands are on `$PATH`. From a git checkout, prefix with `./` or `PATH=.:$PATH` for dev.

### `extract-img [nfs_release]`

Downloads and extracts an Ubuntu ARM64 preinstalled image to `/exports/netboot/<nfs_release>/`.

- Release name maps to URL via `IMAGE_URLS` table inside the script — add new releases there
- Caches the downloaded `.img` in `/var/cache/img/` — re-runs after a failed build are fast
- Skips extract if destination is already populated

```bash
sudo extract-img ubuntu-22.04
sudo extract-img ubuntu-26.04
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
- Installs `overlayroot-nfs` initramfs hook (dracut or initramfs-tools, auto-detected) from `/usr/share/tynet-img/hooks/`
- Installs `overlayroot-nfs-sync` shutdown service
- Rebuilds initramfs via `systemd-nspawn`
- Validates the hook is present in the rebuilt initramfs

Hook source dir is resolved from the script's own location: a sibling `./hooks/` if running from a checkout, otherwise `/usr/share/tynet-img/hooks/`.

```bash
sudo customize-img ubuntu-22.04
sudo customize-img ubuntu-26.04

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
sudo build-node pi2.tynet.us
sudo build-node pi3.tynet.us

# Or via Makefile:
make pi2
make pi3
make pi   # all nodes
```

### `tynet.env` (generated)

Bash-sourceable node inventory at `/etc/tynet-img/tynet.env` (mode `0600 root:root`). Used by `build-node`, `check-status`, `check-boot-config`, and `verify-boot`. Each script lets you override the path with `TYNET_ENV=<path>`.

**Source of truth lives in `../tynet-infra`.** The real `tynet.env` is rendered onto the kickstart host by the kickstart Ansible role from `tynet-infra/inventory/group_vars/all.yml` and `tynet-infra/inventory/host_vars/<host>.yml`. To change a node's config, edit those files and re-run `make kickstart` in tynet-infra. The file is gitignored in this repo; `tynet.env.example` (shipped to `/usr/share/doc/tynet-img/`) documents the format for reference.

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

Kickstart host setup (the tynet-apt source, `tynet-img` and `tynet-cloud-init` package installs, NFS exports template, cloud-init seed files, SSH keys) is managed by Ansible in `../tynet-infra`:

```bash
cd ../tynet-infra
make kickstart       # apt-installs tynet-img + tynet-cloud-init, renders /etc/tynet-img/tynet.env, /etc/exports, cloud-init seeds
make nodes           # deploy SSH host keys to Pi nodes (from 1Password)
make reboot-nodes    # graceful drain + reboot all nodes
```

NFS exports are auto-generated from `/exports/netboot/` release dirs. Re-run `make kickstart` after adding a new release.

## Makefile reference

Run on kickstart host (or from a checkout for dev — see [Development](#development)):

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

make deb                 # build the .deb locally (requires nfpm)
make clean-deb           # remove dist/
```

Power-cycling and k8s-aware reboots live in `../tynet-infra` (`make cycle-pi2`, `make cycle-pi3`, `make reboot-nodes`).

## Provisioning a new node

```bash
# 1. Add node to tynet-infra inventory:
#    - tynet-infra/inventory/production.ini  (add to [nodes])
#    - tynet-infra/inventory/host_vars/<host>.yml  (serial, MAC, IP, release, fsid)

# 2. Add DHCP reservation in Unifi (MAC → IP)

# 3. Re-run kickstart Ansible — renders /etc/tynet-img/tynet.env + per-node cloud-init seed files,
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

## Development

Dev-from-checkout still works without installing the deb — scripts find their hooks via a sibling `./hooks/` directory and the env file via the `TYNET_ENV` environment variable. The Makefile assumes installed binaries on `$PATH`; either install the deb on the dev host, prefix with `./` manually, or run with `PATH=.:$PATH make pi2`.

```bash
# Build the deb locally to verify packaging:
make deb
dpkg-deb -c dist/tynet-img_*.deb         # inspect contents
dpkg-deb -I dist/tynet-img_*.deb         # inspect control metadata

# Test customize-img with a checkout-local hooks dir:
sudo PATH=.:$PATH TYNET_ENV=./tynet.env make ubuntu-22.04
```

A release fires when you push a `v*` tag:

```bash
git tag v0.2.0
git push origin v0.2.0
```

GitHub Actions handles the rest (build, release, dispatch to tynet-apt).

## Logging

`customize-img` and `build-node` write timestamped logs to `/var/log/tynet-img/` on kickstart, rotated daily by the logrotate config the deb installs.

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

VMs render `tynet.env` to a virtiofs path on the Mac (`vmnet/vm.env`) rather than `/etc/tynet-img/tynet.env`. When invoking the scripts inside a VM, set `TYNET_ENV=/Users/<you>/src/tynet-infra/vmnet/vm.env`.

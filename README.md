# tynet-img

Scripts for provisioning Raspberry Pi nodes via network boot (NFS root + TFTP boot + cloud-init).

## How it works

A Pi boots over the network by fetching its kernel and boot files via TFTP, then mounting its root filesystem over NFS. Each node gets a persistent writable overlay over the shared read-only base image. cloud-init runs on first boot and fetches its configuration from an HTTP server on the kickstart host, keyed by the Pi's serial number.

```
Pi (power on)
  └── DHCP  → gets TFTP server IP from UniFi (option 66)
  └── TFTP  → /srv/tftpboot/<serial>/         (boot files + cmdline.txt)
  └── NFS   → /exports/netboot/ubuntu-26.04/  (shared read-only root)
  └── NFS   → /exports/overlay/<hostname>/    (per-node NFS state store)
  └── HTTP  → :8000/<serial>/                 (cloud-init user-data + meta-data)
```

All services are hosted on the kickstart host (`kickstart.tynet.us`, `10.0.60.100`).

## Infrastructure

- **Kickstart host**: `kickstart.tynet.us` — Raspberry Pi aarch64, DHCP reservation `10.0.60.100`
- **Pi VLAN**: `10.0.60.0/24`, gateway `10.0.60.1`
- **Pi nodes**: pi1–pi4, DHCP reservations `10.0.60.201`–`10.0.60.204` (managed in Unifi)
- **UniFi Network Boot**: set to `10.0.60.100` on VLAN 60 (DHCP option 66)

## Overlay filesystem

Each Pi runs an overlayfs stack to get a writable root without modifying the shared base:

```
overlayfs (visible root)
  ├── upper  →  tmpfs  (RAM-backed writes during runtime)
  └── lower  →  NFS    (shared read-only base image)
```

### Why tmpfs for the upper layer

Linux 6.x requires `RENAME_WHITEOUT` support on the overlayfs upper layer. NFS does not provide this syscall, so the upper layer must be tmpfs (RAM-backed). This means all writes during runtime live in RAM and are lost on power loss unless explicitly synced.

### State persistence across reboots

To survive reboots, the `overlayroot-nfs-sync` systemd shutdown service runs before the machine halts or reboots. It rsyncs the tmpfs upper layer to a per-node NFS state store at `/exports/overlay/<hostname>/upper/` on the kickstart host. On the next boot, the `overlayroot-nfs` initramfs hook copies the saved state from NFS back into a fresh tmpfs before mounting the overlay, restoring the node to where it left off.

### Boot sequence (initramfs detail)

The `overlayroot-nfs` hook runs as an `init-bottom` initramfs script — after the NFS root is mounted but before `pivot_root` hands control to the OS. It:

1. Reads `overlay_host=<hostname>` from the kernel cmdline
2. Derives the kickstart IP from `nfsroot=<ip>:...` in the kernel cmdline
3. Mounts `<kickstart>:/exports/overlay/<hostname>` as the NFS state store (read-write, NFSv3)
4. Creates a tmpfs at `/run/overlayroot-upper` with `upper/` and `work/` subdirs
5. Copies any saved state from the NFS state store into the tmpfs upper layer (state restore)
6. Bind-mounts the NFS root (`rootmnt`) as a read-only lower layer
7. Mounts overlayfs: `lower=NFS root, upper=tmpfs/upper, workdir=tmpfs/work`
8. Moves all sub-mounts into the new root so they remain accessible after `pivot_root`

If any step fails, the hook falls back to booting plain NFS root (no overlay) so the node still comes up.

### initramfs rebuild with systemd-nspawn

After installing the `overlayroot-nfs` hook into the image, `customize-img` must rebuild the initramfs so the hook is included. This is done by running `update-initramfs -u -k all` inside the extracted image using `systemd-nspawn`:

```
systemd-nspawn -D /exports/netboot/ubuntu-26.04 update-initramfs -u -k all
```

`systemd-nspawn` is used instead of a bare `chroot` because:

- It automatically bind-mounts `/proc`, `/sys`, and a fresh `/dev` inside the container, which `update-initramfs` needs
- It handles the `/dev` requirement cleanly — `customize-img` pre-mounts a tmpfs on `<root>/dev` before spawning, because nspawn requires `/dev` to be a pre-mounted filesystem rather than a populated directory
- It properly isolates the container from the host, preventing accidental host modifications

The pre-mounted tmpfs on `/dev` is cleaned up via a `trap` on function return.

## Scripts

### `extract-img [URL] [DST]`
Downloads an Ubuntu ARM64 preinstalled image, extracts it, and rsyncs the root and boot partitions to a local directory.

- Caches the downloaded `.img` in `/var/cache/img/` — re-runs are fast
- Defaults to the Ubuntu 26.04 snapshot arm64 image
- Defaults destination to `/exports/netboot/<image-name>/`
- Writes the destination path to stdout

```bash
sudo ./extract-img
sudo ./extract-img https://cdimage.ubuntu.com/.../ubuntu-26.04-...img.xz /exports/netboot/ubuntu-26.04
```

### `customize-img [KICKSTART_IP] [SERIAL] [HOSTNAME]`
Calls `extract-img`, then modifies the extracted filesystem for netboot:

- Writes `cmdline.txt` with NFS root (read-only), `overlay_host=<hostname>`, and cloud-init URL
- Sets `/etc/fstab` to mount root over NFS (read-only)
- Disables growroot
- Installs the `overlayroot-nfs` initramfs hook
- Installs the `overlayroot-nfs-sync` shutdown service for overlay state persistence
- Rebuilds the initramfs via `systemd-nspawn` so the hook is included
- Writes the root directory path to stdout

```bash
sudo ./customize-img 10.0.60.100 244634d3 pi2   # kickstart_ip serial hostname
```

Or via Makefile targets (run on kickstart host):
```bash
make pi2
make pi3
```

### `serve-cloud-init [-dir DIR] [-addr ADDR]`
Go program that serves per-node cloud-init seed data over HTTP on port 8000. Managed as a systemd service by Ansible; can also be run manually.

```bash
./serve-cloud-init -dir ~/src/tynet-img/serve-cloud-init/cloud-init
./serve-cloud-init -dir ~/src/tynet-img/serve-cloud-init/cloud-init -addr :9000
```

## Per-node cloud-init data

Seed files live in `serve-cloud-init/cloud-init/<serial>/` and are served to each node on first boot.

```
serve-cloud-init/cloud-init/
  ad36c642/        # pi1.tynet.us
  244634d3/        # pi2.tynet.us
  a43386be/        # pi3.tynet.us
  testnode/        # VM test node
```

Each directory contains `meta-data` (instance ID + hostname) and `user-data` (standard `#cloud-config`).

Node IPs are managed as DHCP reservations in Unifi — not hardcoded in cloud-init.

## Building serve-cloud-init

Requires Go 1.22+.

```bash
make        # build for local machine
make test   # run Go unit tests
make clean  # remove binary
```

Source lives in `serve-cloud-init/`. The binary is written to `./serve-cloud-init`.

## Provisioning the kickstart host

The kickstart host is configured with Ansible from your Mac. This installs all required packages (kpartx, nfs-kernel-server, tftpd-hpa, golang-go, systemd-container, qemu-user-static, etc.), configures services, deploys the serve-cloud-init systemd service, sets up NFS exports and per-node overlay/TFTP directories, and installs a daily timer to apply security updates to the base image.

**Mac prerequisites:**
```bash
brew install ansible
```

**Provision production (`kickstart.tynet.us`):**
```bash
make provision-kickstart
```

**Provision the local VM kickstart (test env only):**
```bash
cd vms && make provision
```

Both use the same Ansible playbook (`ansible/playbooks/kickstart.yml`) with different inventories:

```
ansible/
  inventory.ini        # production: kickstart.tynet.us + pi1-pi4
  inventory-vm.ini     # VM test environment: lima-kickstart + testnode
  group_vars/all.yml   # shared vars (subnet)
  host_vars/           # per-node config (node_serial, nfs_fsid)
  playbooks/
    kickstart.yml      # configure kickstart host
  roles/
    kickstart/         # packages, TFTP, NFS, cloud-init service,
                       #   overlay dirs, NFS exports, update-base timer
```

**What stays in shell scripts vs Ansible:**

| Shell scripts | Ansible |
|---|---|
| `extract-img` — download + extract base image | Kickstart host packages and services |
| `customize-img` — overlayfs hooks, cmdline.txt, initramfs rebuild | Per-node NFS exports and TFTP dirs |

## Maintenance

Run these on the kickstart host:

```bash
# Apply security updates to the shared base image
make update-base

# Wipe a single node's overlay (node must be offline first)
make wipe-overlay-pi2

# Wipe all nodes' overlays (use after update-base before rebooting)
make wipe-all-overlays CONFIRM=yes

# Reboot all nodes via Ansible
make reboot-nodes
```

**Typical base image update flow:**
```bash
make update-base                        # patch the shared NFS root
make wipe-all-overlays CONFIRM=yes      # clear per-node upper layers
make reboot-nodes                       # restart nodes against updated base
```

The kickstart host also runs an `update-base.timer` systemd unit that applies updates daily at 03:00 (with a random 30-minute delay). After an automated update you should wipe overlays and reboot nodes manually.

## Provisioning a new node (end-to-end)

```bash
# 1. Add host_vars entry: ansible/host_vars/<hostname>.yml
#    Fields: node_serial, nfs_fsid

# 2. Add cloud-init seed data: serve-cloud-init/cloud-init/<serial>/
#    Files: meta-data, user-data

# 3. Add DHCP reservation in Unifi for the node's MAC → desired IP

# 4. Provision the kickstart host (creates NFS exports + TFTP dirs)
make provision-kickstart

# 5. On the kickstart host: build the netboot image
make pi2   # or pi3, etc.

# 6. Power on the Pi — it will netboot and run cloud-init on first boot
```

## Setting up a new kickstart host (SD card)

Cloud-init seed files for the kickstart host live in `setup/kickstart/`:

```
setup/kickstart/
  user-data       # cloud-config: hostname, user, timezone, packages
  meta-data       # instance-id + local-hostname
  network-config  # DHCP on eth0
```

Flash Ubuntu to an SD card with Raspberry Pi Imager, then copy these files to the boot partition (`/boot/firmware/`) before first boot. After boot, run `make provision-kickstart`.

## Local VM test environment

A Lima-based two-VM environment for testing the full netboot stack on Apple Silicon without real hardware. **Test environment only** — production runs on `kickstart.tynet.us`.

**Mac prerequisites:**
```bash
brew install lima ansible
brew install socket_vmnet   # for VM-to-VM networking
```

```bash
cd vms
make start      # start both VMs (kickstart + node)
make provision  # run Ansible against kickstart VM
make test       # run integration tests from the node VM
make kickstart  # shell into kickstart VM
make node       # shell into node VM
make stop       # stop both VMs
make clean      # delete both VMs
```

The kickstart VM is fixed at `192.168.105.10`. After `make provision`, build the base image from inside the kickstart VM:

```bash
cd /Users/ty/src/tynet-img
sudo ./customize-img 192.168.105.10 testnode testnode
```

Then run the integration tests:

```bash
cd vms && make test
```

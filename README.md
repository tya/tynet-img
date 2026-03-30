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

All services are hosted on the kickstart host (`vpn.tynet.us`, `10.0.60.10`).

### Overlay filesystem

Each Pi runs an overlayfs stack to get a writable root without modifying the shared base:

```
overlayfs (visible root)
  ├── upper  →  tmpfs  (RAM-backed writes during runtime)
  └── lower  →  NFS    (shared read-only base image)
```

The upper layer is tmpfs (RAM-backed) because Linux 6.x requires `RENAME_WHITEOUT` support on the upper layer, which NFS does not provide. To persist writes across reboots, the `overlayroot-nfs-sync` shutdown service syncs the tmpfs upper layer back to the per-node NFS state store (`/exports/overlay/<hostname>/`) before the machine powers off. On the next boot, `overlayroot-nfs` (an initramfs hook) restores that saved state into a fresh tmpfs before mounting the overlay.

## Infrastructure

- **Kickstart host**: `vpn.tynet.us` — Raspberry Pi, on VLAN 60 (`10.0.60.10`)
- **Pi VLAN**: `10.0.60.0/24`
- **UniFi Network Boot**: set to `10.0.60.10` on the VLAN 60 network (sets DHCP option 66)

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

- Writes `cmdline.txt` with NFS root (read-only), overlay hostname, and cloud-init URL
- Sets `/etc/fstab` to mount root over NFS
- Disables growroot
- Installs the `overlayroot-nfs` initramfs hook and rebuilds the initramfs
- Installs the `overlayroot-nfs-sync` shutdown service for overlay state persistence
- Writes the root directory path to stdout

```bash
sudo ./customize-img 10.0.60.10 244634d3 pi2   # kickstart_ip serial hostname
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
  244634d3/        # pi2.tynet.us
    meta-data
    user-data
  a43386be/        # pi3.tynet.us
    meta-data
    user-data
  testnode/        # VM test node
    meta-data
    user-data
```

`meta-data` sets the instance ID and hostname. `user-data` is a standard `#cloud-config` document.

## Building serve-cloud-init

Requires Go 1.22+.

```bash
make        # build for local machine
make test   # run Go unit tests
make clean  # remove binary
```

Source lives in `serve-cloud-init/`. The binary is written to `./serve-cloud-init`.

## Provisioning the kickstart host

The kickstart host is configured with Ansible from your Mac. This installs all required packages (kpartx, nfs-kernel-server, tftpd-hpa, golang-go, etc.), configures services, deploys the serve-cloud-init systemd service, sets up NFS exports and TFTP bind-mounts for each node, and installs a daily timer to apply security updates to the base image.

**Mac prerequisites:**
```bash
brew install ansible
```

**Provision production (`vpn.tynet.us`):**
```bash
make provision-kickstart
```

**Provision the local VM kickstart (see VM test environment below):**
```bash
cd vms && make provision
```

Both use the same Ansible playbook (`ansible/playbooks/kickstart.yml`) with different inventories:

```
ansible/
  inventory.ini      # production: vpn.tynet.us + pi1-pi4
  inventory-vm.ini   # VM test environment: lima-kickstart + testnode
  host_vars/         # per-node config (serial, node_ip, nfs_fsid)
  playbooks/
    kickstart.yml    # configure kickstart host (packages, TFTP, NFS, cloud-init service,
                     #   per-node overlay dirs, NFS exports, TFTP bind-mounts, update-base timer)
    upgrade.yml      # apt upgrade all nodes
    microk8s.yml     # microk8s status and addon management
  roles/
    kickstart/       # kickstart host setup
    nodes/           # common node config (hostname, SSH keys)
```

**What stays in shell scripts vs Ansible:**

| Shell scripts | Ansible |
|---|---|
| `extract-img` — download + extract base image | Kickstart host packages and services |
| `customize-img` — overlayfs hooks, cmdline.txt, overlay sync service | Per-node NFS exports and TFTP bind-mounts |
| | OS upgrades, SSH key rotation, reboot management |

## Maintenance

Run these on the kickstart host after Ansible provisioning:

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
make update-base        # patch the shared NFS root
make wipe-all-overlays CONFIRM=yes  # clear per-node upper layers so no stale files shadow updates
make reboot-nodes       # restart nodes against the updated base
```

The kickstart host also runs an `update-base.timer` systemd unit that runs `make update-base` daily at 03:00 (with a random 30-minute delay to avoid thundering herd).

## Provisioning a new node (end-to-end)

```bash
# 1. Add host_vars entry for the node
#    Create ansible/host_vars/<hostname>.yml with serial, node_ip, nfs_fsid

# 2. Add cloud-init seed data
#    Create serve-cloud-init/cloud-init/<serial>/meta-data and user-data

# 3. Provision the kickstart host (creates NFS exports + TFTP dirs for the new node)
make provision-kickstart

# 4. On the kickstart host: build the base image
sudo ./customize-img 10.0.60.10 <serial> <hostname>

# 5. In UniFi: set Network Boot to 10.0.60.10 on the VLAN 60 network

# 6. Power on the Pi — it will netboot and run cloud-init
```

## Local VM test environment

A Lima-based two-VM environment for testing the full netboot stack on Apple Silicon without real hardware. Uses the same Ansible playbook as production.

**Mac prerequisites:**
```bash
brew install lima ansible
brew install socket_vmnet   # for VM-to-VM networking
```

```bash
cd vms
make start      # start both VMs (kickstart + node)
make provision  # run Ansible against kickstart VM (same playbook as production)
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

Then run the integration tests from your Mac:

```bash
cd vms && make test
```

The tests cover TFTP file fetch, NFS base mount (read-only), NFS overlay mount (writable), overlayfs stacking (NFS lower + tmpfs upper), and cloud-init HTTP endpoints.

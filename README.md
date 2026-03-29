# tynet-img

Scripts for provisioning Raspberry Pi nodes via network boot (NFS root + TFTP boot + cloud-init).

## How it works

A Pi boots over the network by fetching its kernel and boot files via TFTP, then mounting its root filesystem over NFS. cloud-init runs on first boot and fetches its configuration from an HTTP server on the kickstart host, keyed by the Pi's serial number.

```
Pi (power on)
  └── DHCP  → gets TFTP server IP from UniFi (option 66)
  └── TFTP  → /srv/tftpboot/<serial>/        (boot files + cmdline.txt)
  └── NFS   → /exports/netboot/ubuntu-26.04/ (root filesystem)
  └── HTTP  → :8000/<serial>/                (cloud-init user-data + meta-data)
```

All three are served from the kickstart host (`vpn.tynet.us`, `10.0.60.10`).

## Infrastructure

- **Kickstart host**: `vpn.tynet.us` — Ubuntu 22.10, Raspberry Pi, on VLAN 60 (`10.0.60.10`)
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

### `customize-img [KICKSTART_IP] [SERIAL]`
Calls `extract-img`, then modifies the extracted filesystem for netboot:

- Writes `cmdline.txt` with NFS root + `ds=nocloud;s=http://<kickstart>:8000/<serial>/` for cloud-init
- Sets `/etc/fstab` to mount root over NFS
- Disables growroot
- Writes the root directory path to stdout

```bash
sudo ./customize-img 10.0.60.10 244634d3
```

### `serve-img [TFTP_DIR] [NODE_CIDR] [KICKSTART_IP]`
Calls `customize-img`, then configures the kickstart host to serve the node:

- Adds an NFS export for the node subnet in `/etc/exports`
- Bind-mounts the boot directory into the TFTP directory and adds it to `/etc/fstab`
- Restarts `rpcbind`, `nfs-server`, and `tftpd-hpa`
- The Pi serial is derived from the basename of `TFTP_DIR`

```bash
sudo ./serve-img /srv/tftpboot/244634d3 10.0.60.0/24 10.0.60.10 pi2   # pi2
sudo ./serve-img /srv/tftpboot/a43386be 10.0.60.0/24 10.0.60.10 pi3   # pi3
```

### `configure-tftp`
One-time setup to install and configure `tftpd-hpa` on the kickstart host.

```bash
sudo ./configure-tftp
```

### `serve-cloud-init [-dir DIR] [-addr ADDR]`
Go program that serves per-node cloud-init seed data over HTTP on port 8000. Defaults to the `cloud-init/` directory adjacent to the binary.

```bash
./serve-cloud-init -dir ~/src/tynet-img/cloud-init
./serve-cloud-init -dir ~/src/tynet-img/cloud-init -addr :9000
```

## Per-node cloud-init data

Seed files live in `cloud-init/<serial>/` and are served to each node on first boot.

```
cloud-init/
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
make test   # run tests
make clean  # remove binary
```

The binary is written to `./serve-cloud-init`.

## Dependencies

The kickstart host requires: `kpartx`, `wget`, `nfs-kernel-server`, `rpcbind`, `tftpd-hpa`, `make`, `golang-go`

## Provisioning a new node (end-to-end)

```bash
# 1. On kickstart host: one-time TFTP setup
sudo ./configure-tftp

# 2. Add cloud-init seed data for the node
#    Create cloud-init/<serial>/meta-data and user-data

# 3. Serve NFS + TFTP boot files for each node (hostname used for overlay layer)
sudo ./serve-img /srv/tftpboot/<serial> 10.0.60.0/24 10.0.60.10 <hostname>

# 4. Start the cloud-init HTTP server
./serve-cloud-init -dir ~/src/tynet-img/cloud-init &

# 5. In UniFi: set Network Boot to 10.0.60.10 on the VLAN 60 network

# 6. Power on the Pi — it will netboot and run cloud-init
```

## Day-2 management with Ansible

After nodes are netbooting, use Ansible for ongoing management from your Mac.

```
ansible/
  inventory.ini             # kickstart + pi1-pi4
  playbooks/
    kickstart.yml           # configure vpn.tynet.us (TFTP, NFS, cloud-init service)
    upgrade.yml             # apt upgrade all nodes
    microk8s.yml            # microk8s status and addon management
  roles/
    kickstart/              # replaces configure-tftp shell script
    nodes/                  # common node config (hostname, SSH keys)
```

```bash
# Set up kickstart host (first time or after changes)
ansible-playbook ansible/playbooks/kickstart.yml

# Upgrade all nodes
ansible-playbook ansible/playbooks/upgrade.yml

# Upgrade a single node
ansible-playbook ansible/playbooks/upgrade.yml --limit pi2

# Check microk8s cluster status
ansible-playbook ansible/playbooks/microk8s.yml --tags status
```

**What stays in shell scripts vs Ansible:**

| Shell scripts | Ansible |
|---|---|
| `extract-img` — download + extract image | Kickstart service config (TFTP, NFS) |
| `customize-img` — inject overlayfs hook, write cmdline.txt | OS upgrades across nodes |
| `serve-img` — provision a new node (per-serial) | MicroK8s cluster management |
| | SSH key rotation |
| | Reboot management |

## Local VM test environment

A Lima-based two-VM environment for testing the full netboot stack on Apple Silicon without real hardware. See `vms/`.

```bash
cd vms
make start      # start both VMs
make kickstart  # shell into kickstart VM
make node       # shell into node VM
make stop       # stop both VMs
make clean      # delete both VMs
```

The kickstart VM is fixed at `192.168.105.10`. Inside the kickstart VM:

```bash
cd /Users/ty/src/tynet-img
sudo ./configure-tftp
sudo ./serve-img /srv/tftpboot/testnode 192.168.105.0/24 192.168.105.10
./serve-cloud-init -dir /Users/ty/src/tynet-img/cloud-init &
```

From the node VM, verify each service:

```bash
tftp 192.168.105.10 -c get testnode/vmlinuz        # TFTP
sudo mount -t nfs 192.168.105.10:/exports/netboot/ubuntu-26.04 /mnt  # NFS
curl http://192.168.105.10:8000/testnode/meta-data  # cloud-init HTTP
```

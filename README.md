# tynet-img

Scripts for provisioning Raspberry Pi nodes via network boot (NFS root + TFTP boot + cloud-init).

## How it works

A Pi boots over the network by fetching its kernel and boot files via TFTP, then mounting its root filesystem over NFS. cloud-init runs on first boot and fetches its configuration from an HTTP server on the kickstart host, keyed by the Pi's serial number.

```
Pi (power on)
  └── TFTP → /srv/tftpboot/<serial>/     (boot files + cmdline.txt)
  └── NFS  → /exports/netboot/ubuntu-26.04/  (root filesystem)
  └── HTTP → :8000/<serial>/             (cloud-init user-data + meta-data)
```

All three are served from the kickstart host (`10.0.10.13`).

## Scripts

### `extract-img [URL] [DST]`
Downloads an Ubuntu ARM64 preinstalled image, extracts it, and rsyncs the root and boot partitions to a local directory.

- Caches the downloaded `.img` in `/var/cache/img/` — re-runs are fast
- Defaults to the Ubuntu 26.04 snapshot arm64 image
- Defaults destination to `/exports/netboot/<image-name>/`
- Writes the destination path to stdout

```bash
sudo ./extract-img
sudo ./extract-img https://cdimage.ubuntu.com/.../ubuntu-26.04-...img.xz /exports/netboot/ubuntu-26
```

### `customize-img [KICKSTART_IP] [SERIAL]`
Calls `extract-img`, then modifies the extracted filesystem for netboot:

- Writes `cmdline.txt` with NFS root + `ds=nocloud;s=http://<kickstart>:8000/<serial>/` for cloud-init
- Sets `/etc/fstab` to mount root over NFS
- Disables growroot
- Refreshes RPi firmware (`start4.elf`, `fixup4.dat`) from the rpi-firmware GitHub repo
- Writes the root directory path to stdout

```bash
sudo ./customize-img 10.0.10.13 244634d3
```

### `serve-img [TFTP_DIR] [NODE_IP]`
Calls `customize-img`, then configures the kickstart host to serve the node:

- Adds an NFS export for the node's IP in `/etc/exports`
- Bind-mounts the boot directory into the TFTP directory and adds it to `/etc/fstab`
- Restarts `rpcbind`, `nfs-server`, and `tftpd-hpa`
- The Pi serial is derived from the basename of `TFTP_DIR`

```bash
sudo ./serve-img /srv/tftpboot/244634d3 10.0.10.12/32   # pi2
sudo ./serve-img /srv/tftpboot/a43386be 10.0.10.13/32   # pi3
```

### `configure-tftp`
One-time setup to install and configure `tftpd-hpa` on the kickstart host.

```bash
sudo ./configure-tftp
```

### `serve-cloud-init [-dir DIR] [-addr ADDR]`
Go program that serves per-node cloud-init seed data over HTTP on port 8000. Defaults to the `cloud-init/` directory adjacent to the binary.

```bash
./serve-cloud-init
./serve-cloud-init -dir /srv/cloud-init -addr :9000
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
```

`meta-data` sets the instance ID and hostname. `user-data` is a standard `#cloud-config` document — put your MicroK8s snap install, users, SSH keys, and join tokens here.

## Building serve-cloud-init

Requires Go 1.22+.

```bash
# build for the local machine (development/testing)
make build

# build for the kickstart host (linux/amd64)
make build-linux

# run tests
make test
```

The binary is written to `./serve-cloud-init`. Copy it to the kickstart host alongside the `cloud-init/` directory.

## Dependencies

The kickstart host requires: `kpartx`, `wget`, `nfs-server`, `rpcbind`, `tftpd-hpa`

## Provisioning a new node (end-to-end)

```bash
# 1. On kickstart host: set up TFTP, serve NFS + boot files
sudo ./serve-img /srv/tftpboot/<serial> <node-ip>/32

# 2. Add cloud-init seed data for the node
#    Edit cloud-init/<serial>/user-data

# 3. On kickstart host: serve cloud-init data
./serve-cloud-init

# 4. Power on the Pi — it will netboot and run cloud-init
```

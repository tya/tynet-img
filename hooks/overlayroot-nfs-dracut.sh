#!/bin/sh
# dracut pre-pivot hook: per-node overlayfs with tmpfs upper layer.
# Dracut equivalent of hooks/overlayroot-nfs (initramfs-tools init-bottom).
#
# Linux kernel 6.x requires RENAME_WHITEOUT support on the overlayfs upper
# layer. NFS does not provide this, so tmpfs is used as the upper layer
# (RAM-backed). On boot, any previously saved state is copied from the
# per-node NFS overlay share into the tmpfs upper, restoring the last known
# state. Writes during runtime go to tmpfs and are synced back to NFS by the
# overlayroot-nfs-sync shutdown service.
#
# Reads overlay_host= from the kernel cmdline, then:
#   1. Mounts <kickstart>:/exports/overlay/<hostname> as the NFS state store
#   2. Creates a tmpfs upper layer
#   3. Copies saved state from NFS upper/ into tmpfs upper/ (state restore)
#   4. Mounts overlayfs: lower=NFS root ($NEWROOT), upper=tmpfs
#
# Installed by customize-img into:
#   /usr/lib/dracut/modules.d/50overlayroot-nfs/overlayroot-nfs.sh

command -v getarg > /dev/null || . /lib/dracut-lib.sh 2>/dev/null || . /usr/lib/dracut-lib.sh

# Write to kernel ring buffer so messages appear over netconsole and in dmesg.
kmsg() { echo "<6>overlayroot-nfs: $*" > /dev/kmsg 2>/dev/null || true; }

OVERLAY_HOST=$(getarg overlay_host=) || true
[ -z "${OVERLAY_HOST}" ] && exit 0

KICKSTART_IP=$(getarg nfsroot= | cut -d: -f1) || true
if [ -z "${KICKSTART_IP}" ]; then
    warn "overlayroot-nfs: cannot determine kickstart IP from nfsroot="
    kmsg "FAILED: cannot determine kickstart IP from nfsroot="
    exit 0
fi

info "overlayroot-nfs: setting up overlay for ${OVERLAY_HOST}"
kmsg "start: overlay for ${OVERLAY_HOST} kickstart=${KICKSTART_IP}"

# Mount per-node NFS state store (read the saved upper layer from here)
NFS_STATE="/run/overlayroot-nfs"
mkdir -p "${NFS_STATE}"
if ! mount -t nfs -o rw,nolock,vers=3 \
        "${KICKSTART_IP}:/exports/overlay/${OVERLAY_HOST}" "${NFS_STATE}"; then
    warn "overlayroot-nfs: failed to mount NFS state store"
    kmsg "FAILED: could not mount NFS state store ${KICKSTART_IP}:/exports/overlay/${OVERLAY_HOST}"
    exit 0
fi
kmsg "mounted NFS state store"

# Create tmpfs upper layer (kernel 6.x requires RENAME_WHITEOUT on upper;
# NFS does not support it — tmpfs does)
TMPFS_UPPER="/run/overlayroot-upper"
mkdir -p "${TMPFS_UPPER}"
mount -t tmpfs tmpfs "${TMPFS_UPPER}"
mkdir -p "${TMPFS_UPPER}/upper" "${TMPFS_UPPER}/work"

# Restore saved state from NFS into the tmpfs upper layer
if [ -d "${NFS_STATE}/upper" ] && [ "$(ls -A "${NFS_STATE}/upper" 2>/dev/null)" ]; then
    cp -a "${NFS_STATE}/upper/." "${TMPFS_UPPER}/upper/"
    kmsg "restored saved state from NFS upper"
else
    kmsg "no saved state — starting fresh"
fi

# Bind-mount the current NFS root as the read-only lower layer
LOWER="/run/overlayroot-lower"
mkdir -p "${LOWER}"
# shellcheck disable=SC2154  # NEWROOT is set by the dracut framework
mount --bind "${NEWROOT}" "${LOWER}"
mount --bind -o remount,ro "${LOWER}"

# Mount overlayfs at NEWROOT
if ! mount -t overlay overlay \
        -o "lowerdir=${LOWER},upperdir=${TMPFS_UPPER}/upper,workdir=${TMPFS_UPPER}/work" \
        "${NEWROOT}"; then
    warn "overlayroot-nfs: overlay mount failed, falling back to plain NFS root"
    kmsg "FAILED: overlay mount failed — falling back to plain NFS root"
    umount "${TMPFS_UPPER}"
    umount "${LOWER}"
    umount "${NFS_STATE}"
    exit 0
fi
kmsg "overlay mounted successfully"

# Move all sub-mounts inside the new root so they remain accessible after switch_root.
# The sync service will write tmpfs upper back to NFS_STATE on shutdown.
mkdir -p "${NEWROOT}/run/overlayroot-lower"
mkdir -p "${NEWROOT}/run/overlayroot-upper"
mkdir -p "${NEWROOT}/run/overlayroot-nfs"
mount --move "${LOWER}"       "${NEWROOT}/run/overlayroot-lower"
mount --move "${TMPFS_UPPER}" "${NEWROOT}/run/overlayroot-upper"
mount --move "${NFS_STATE}"   "${NEWROOT}/run/overlayroot-nfs"

kmsg "done: switch_root handoff to ${OVERLAY_HOST}"

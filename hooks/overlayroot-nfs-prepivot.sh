#!/bin/sh
# dracut pre-pivot hook: runs AFTER nfsroot mounts /sysroot, BEFORE switch_root.
# SOURCED by dracut. Use "return", never "exit".
#
# Strategy: /sysroot is already NFS-mounted. Move it to /run/overlayroot-lower,
# set up tmpfs upper, mount overlay at /sysroot.

command -v getarg > /dev/null || . /lib/dracut-lib.sh 2>/dev/null || . /usr/lib/dracut-lib.sh

kmsg() { echo "<6>overlayroot-nfs-prepivot: $*" > /dev/kmsg 2>/dev/null || true; }

OVERLAY_HOST=$(getarg overlay_host=) || true
[ -z "${OVERLAY_HOST}" ] && return 0

# shellcheck disable=SC2154
grep -q " ${NEWROOT} overlay" /proc/mounts 2>/dev/null && return 0

# Parse NFS root params
_nfsroot=$(grep -o 'nfsroot=[^ ]*' /proc/cmdline 2>/dev/null)
_nfsroot=${_nfsroot#nfsroot=}
KICKSTART_IP=${_nfsroot%%:*}

# Mount state store (for tracing + saved-state restore)
NFS_STATE="/run/overlayroot-nfs"
mkdir -p "${NFS_STATE}"
if ! grep -q " ${NFS_STATE} nfs" /proc/mounts 2>/dev/null; then
    mount -t nfs -o rw,nolock,soft,timeo=50,retrans=2,vers=3 \
        "${KICKSTART_IP}:/exports/overlay/${OVERLAY_HOST}" "${NFS_STATE}" \
        > /dev/null 2>&1 || {
        kmsg "FAILED: state store mount"
        return 0
    }
fi

trace() {
    _up=$(awk '{print $1}' /proc/uptime 2>/dev/null)
    echo "[+${_up}s][prepivot] $*" >> "${NFS_STATE}/prepivot.txt" 2>/dev/null
    kmsg "$*"
}

trace "fired"
trace "mounts:"
sed 's/^/  /' /proc/mounts >> "${NFS_STATE}/prepivot.txt" 2>/dev/null

# Verify /sysroot is mounted as NFS
if ! grep -q " ${NEWROOT} nfs" /proc/mounts 2>/dev/null; then
    trace "FAILED: ${NEWROOT} is not NFS-mounted"
    return 0
fi

UPPER_DIR="/run/overlayroot-upper"
LOWER="/run/overlayroot-lower"
mkdir -p "${UPPER_DIR}" "${LOWER}"

# Move NFS mount from /sysroot to LOWER
if ! mount --move "${NEWROOT}" "${LOWER}" 2>>"${NFS_STATE}/prepivot.txt"; then
    trace "FAILED: mount --move ${NEWROOT} -> ${LOWER}"
    return 0
fi
trace "moved ${NEWROOT} -> ${LOWER}"

# Set up tmpfs upper
SSD_MOUNTED=0
SSD_DEV=$(getarg overlay_dev=) || true
if [ -n "${SSD_DEV}" ] && [ -b "${SSD_DEV}" ]; then
    if mount -t ext4 -o noatime "${SSD_DEV}" "${UPPER_DIR}" 2>/dev/null; then
        mkdir -p "${UPPER_DIR}/upper" "${UPPER_DIR}/work"
        SSD_MOUNTED=1
        trace "upper on SSD ${SSD_DEV}"
    fi
fi

if [ "${SSD_MOUNTED}" -eq 0 ]; then
    mount -t tmpfs tmpfs "${UPPER_DIR}" || {
        trace "FAILED: tmpfs upper, restoring NFS mount"
        mount --move "${LOWER}" "${NEWROOT}"
        return 0
    }
    mkdir -p "${UPPER_DIR}/upper" "${UPPER_DIR}/work"
    trace "upper on tmpfs"

    if [ -d "${NFS_STATE}/upper" ] && [ "$(ls -A "${NFS_STATE}/upper" 2>/dev/null)" ]; then
        cp -a "${NFS_STATE}/upper/." "${UPPER_DIR}/upper/"
        trace "restored saved state"
    else
        trace "fresh start"
    fi
fi

# Mount overlay at NEWROOT
if ! mount -t overlay overlay \
        -o "lowerdir=${LOWER},upperdir=${UPPER_DIR}/upper,workdir=${UPPER_DIR}/work" \
        "${NEWROOT}" 2>>"${NFS_STATE}/prepivot.txt"; then
    trace "FAILED: overlay mount, restoring NFS mount"
    umount "${UPPER_DIR}" 2>/dev/null
    mount --move "${LOWER}" "${NEWROOT}"
    return 0
fi

trace "overlay mounted at ${NEWROOT}"

#!/bin/sh
# dracut initqueue hook: per-node overlayfs with persistent upper layer.
# SOURCED by dracut's initqueue loop. Use "return", never "exit".
#
# Strategy: mount NFS root ourselves at /run/overlayroot-lower (doesn't
# conflict with dracut's nfsroot handler since we use a different path),
# set up tmpfs upper, mount overlay at NEWROOT. Touch /dev/nfs so
# dracut's nfsroot finished gate passes immediately.

command -v getarg > /dev/null || . /lib/dracut-lib.sh 2>/dev/null || . /usr/lib/dracut-lib.sh

kmsg() { echo "<6>overlayroot-nfs: $*" > /dev/kmsg 2>/dev/null || true; }

# Already done — overlay is on NEWROOT
# shellcheck disable=SC2154
grep -q " ${NEWROOT} overlay" /proc/mounts 2>/dev/null && return 0

OVERLAY_HOST=$(getarg overlay_host=) || true
[ -z "${OVERLAY_HOST}" ] && return 0

# Parse NFS root params from cmdline
_nfsroot=$(grep -o 'nfsroot=[^ ]*' /proc/cmdline 2>/dev/null)
_nfsroot=${_nfsroot#nfsroot=}
KICKSTART_IP=${_nfsroot%%:*}
NFS_PATH=${_nfsroot#*:}
NFS_PATH=${NFS_PATH%%,*}
NFS_OPTS=${_nfsroot#*,}
[ "${NFS_OPTS}" = "${_nfsroot}" ] && NFS_OPTS="vers=3"

[ -z "${KICKSTART_IP}" ] && return 0
[ -z "${NFS_PATH}" ] && return 0

# Need network to be up — check for default route (no ping in initramfs)
grep -q '00000000' /proc/net/route 2>/dev/null || return 0

# Mount state store NFS share early so we can write trace files
NFS_STATE="/run/overlayroot-nfs"
mkdir -p "${NFS_STATE}"
if ! grep -q " ${NFS_STATE} nfs" /proc/mounts 2>/dev/null; then
    mount -t nfs -o rw,nolock,soft,timeo=50,retrans=2,vers=3 \
        "${KICKSTART_IP}:/exports/overlay/${OVERLAY_HOST}" "${NFS_STATE}" \
        > /dev/null 2>&1 || return 0
fi

trace() {
    _up=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)
    echo "[+${_up}s] $*" >> "${NFS_STATE}/debug.txt" 2>/dev/null
    kmsg "$*"
}

trace "hook fired (overlay_host=${OVERLAY_HOST})"

UPPER_DIR="/run/overlayroot-upper"
LOWER="/run/overlayroot-lower"
mkdir -p "${UPPER_DIR}" "${LOWER}"

# 1. Mount NFS root ourselves at LOWER (separate from dracut's NEWROOT mount)
if ! grep -q " ${LOWER} nfs" /proc/mounts 2>/dev/null; then
    _err=$(mount -t nfs -vvv -o "ro,nolock,soft,timeo=50,retrans=2,${NFS_OPTS}" \
            "${KICKSTART_IP}:${NFS_PATH}" "${LOWER}" 2>&1)
    _rc=$?
    if [ "${_rc}" -ne 0 ]; then
        trace "FAILED: NFS root mount (rc=${_rc}):"
        echo "${_err}" | sed 's/^/    /' >> "${NFS_STATE}/debug.txt" 2>/dev/null
        trace "kernel msgs (last 20):"
        dmesg | tail -20 | sed 's/^/    /' >> "${NFS_STATE}/debug.txt" 2>/dev/null
        return 0
    fi
    trace "NFS root mounted at ${LOWER}"
fi

# 2. Set up upper layer
SSD_MOUNTED=0
SSD_DEV=$(getarg overlay_dev=) || true
if [ -n "${SSD_DEV}" ]; then
    _tries=0
    while [ ! -b "${SSD_DEV}" ] && [ "${_tries}" -lt 10 ]; do sleep 1; _tries=$((_tries + 1)); done
    if [ -b "${SSD_DEV}" ] && mount -t ext4 -o noatime "${SSD_DEV}" "${UPPER_DIR}"; then
        mkdir -p "${UPPER_DIR}/upper" "${UPPER_DIR}/work"
        SSD_MOUNTED=1
        trace "upper on SSD ${SSD_DEV}"
    fi
fi

if [ "${SSD_MOUNTED}" -eq 0 ]; then
    if ! grep -q " ${UPPER_DIR} tmpfs" /proc/mounts 2>/dev/null; then
        mount -t tmpfs tmpfs "${UPPER_DIR}" || {
            trace "FAILED: tmpfs upper"
            return 0
        }
    fi
    mkdir -p "${UPPER_DIR}/upper" "${UPPER_DIR}/work"
    trace "upper on tmpfs"

    if [ -d "${NFS_STATE}/upper" ] && [ "$(ls -A "${NFS_STATE}/upper" 2>/dev/null)" ]; then
        cp -a "${NFS_STATE}/upper/." "${UPPER_DIR}/upper/"
        trace "restored saved state"
    else
        trace "fresh start"
    fi
fi

# 3. If dracut already mounted NFS at NEWROOT, unmount it (we'll replace with overlay)
if grep -q " ${NEWROOT} nfs" /proc/mounts 2>/dev/null; then
    umount "${NEWROOT}" 2>/dev/null || trace "warning: could not unmount existing NFS at ${NEWROOT}"
fi

# 4. Mount overlay at NEWROOT
if ! mount -t overlay overlay \
        -o "lowerdir=${LOWER},upperdir=${UPPER_DIR}/upper,workdir=${UPPER_DIR}/work" \
        "${NEWROOT}"; then
    trace "FAILED: overlay mount"
    return 0
fi

# 5. Create /dev/nfs and /dev/root so dracut's nfsroot finished gate passes
[ -e /dev/nfs ] || ln -s null /dev/nfs
[ -e /dev/root ] || ln -s null /dev/root

trace "overlay mounted at ${NEWROOT}"

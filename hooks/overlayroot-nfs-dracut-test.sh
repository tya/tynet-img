#!/bin/sh
# Minimal test hook: just try to mount the overlay NFS share.
# If this appears in kickstart's mountd logs, the hook is running.

command -v getarg > /dev/null || . /lib/dracut-lib.sh 2>/dev/null || . /usr/lib/dracut-lib.sh

kmsg() { echo "<6>overlayroot-nfs-TEST: $*" > /dev/kmsg 2>/dev/null || true; }

kmsg "TEST HOOK ENTERED"

OVERLAY_HOST=$(getarg overlay_host=) || true
kmsg "overlay_host=${OVERLAY_HOST}"

[ -z "${OVERLAY_HOST}" ] && return 0

# Hardcoded NFS mount attempt — will show in kickstart's mountd log
mkdir -p /run/overlayroot-test
kmsg "attempting NFS mount 10.0.60.100:/exports/overlay/${OVERLAY_HOST}"
mount -t nfs -o rw,nolock,soft,timeo=100,retrans=2,vers=3 \
    "10.0.60.100:/exports/overlay/${OVERLAY_HOST}" /run/overlayroot-test 2>/dev/null \
    && kmsg "NFS mount succeeded" \
    || kmsg "NFS mount failed"
umount /run/overlayroot-test 2>/dev/null || true

return 0

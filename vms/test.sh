#!/usr/bin/env bash
# Integration tests for the kickstart VM environment.
# Run this inside the node VM:
#   limactl shell node -- sudo bash /Users/ty/src/tynet-img/vms/test.sh
#
# Tests:
#   1. TFTP    — fetch a boot file for testnode
#   2. NFS base — mount the shared read-only root
#   3. NFS overlay — mount the per-node writable overlay share
#   4. Overlayfs   — stack them; verify writes land in upper, not lower
#   5. cloud-init HTTP — fetch meta-data and user-data for testnode

set -euo pipefail

KICKSTART=192.168.105.10
SERIAL=testnode
WORK=$(mktemp -d)
PASS=0
FAIL=0

# ── helpers ──────────────────────────────────────────────────────────────────

green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*"; }

pass() { green "$1"; PASS=$((PASS+1)); }
fail() { red   "$1"; FAIL=$((FAIL+1)); }

cleanup() { umount "$WORK/overlay" 2>/dev/null || true
            umount "$WORK/lower"   2>/dev/null || true
            umount "$WORK/upper"   2>/dev/null || true
            umount "$WORK/base"    2>/dev/null || true
            rm -rf "$WORK"; }
trap cleanup EXIT

# ── 1. TFTP ──────────────────────────────────────────────────────────────────

echo
echo "── 1. TFTP ──────────────────────────────────────────────────────"
if tftp "$KICKSTART" -c get "$SERIAL/vmlinuz" "$WORK/vmlinuz" 2>/dev/null \
   && [ -s "$WORK/vmlinuz" ]; then
    pass "fetched $SERIAL/vmlinuz via TFTP ($(du -h "$WORK/vmlinuz" | cut -f1))"
else
    fail "could not fetch $SERIAL/vmlinuz from $KICKSTART via TFTP"
fi

# ── 2. NFS base (read-only shared root) ──────────────────────────────────────

echo
echo "── 2. NFS base mount ────────────────────────────────────────────"
mkdir -p "$WORK/base"
if mount -t nfs -o ro,nolock,vers=3 \
        "$KICKSTART:/exports/netboot/ubuntu-26.04" "$WORK/base"; then
    if [ -d "$WORK/base/etc" ] && [ -d "$WORK/base/usr" ]; then
        pass "NFS base mounted and looks like a root filesystem"
    else
        fail "NFS base mounted but missing expected directories"
    fi
    # verify read-only
    if ! touch "$WORK/base/etc/ro-test" 2>/dev/null; then
        pass "NFS base is read-only as expected"
    else
        fail "NFS base accepted a write — should be read-only"
        rm -f "$WORK/base/etc/ro-test"
    fi
else
    fail "could not mount NFS base from $KICKSTART"
fi

# ── 3. NFS overlay (per-node writable upper layer) ───────────────────────────

echo
echo "── 3. NFS overlay mount ─────────────────────────────────────────"
mkdir -p "$WORK/upper"
if mount -t nfs -o rw,nolock,vers=3 \
        "$KICKSTART:/exports/overlay/$SERIAL" "$WORK/upper"; then
    if [ -d "$WORK/upper/upper" ] && [ -d "$WORK/upper/work" ]; then
        pass "NFS overlay mounted with upper/ and work/ dirs present"
    else
        fail "NFS overlay mounted but upper/ or work/ missing"
    fi
    if touch "$WORK/upper/upper/write-test" 2>/dev/null; then
        pass "NFS overlay is writable"
        rm -f "$WORK/upper/upper/write-test"
    else
        fail "NFS overlay is not writable"
    fi
else
    fail "could not mount NFS overlay from $KICKSTART"
fi

# ── 4. Overlayfs ─────────────────────────────────────────────────────────────

echo
echo "── 4. Overlayfs stacking ────────────────────────────────────────"
mkdir -p "$WORK/overlay" "$WORK/lower"
# bind lower as read-only
if mount --bind "$WORK/base" "$WORK/lower" \
   && mount --bind -o remount,ro "$WORK/lower"; then

    if mount -t overlay overlay \
            -o lowerdir="$WORK/lower",upperdir="$WORK/upper/upper",workdir="$WORK/upper/work" \
            "$WORK/overlay"; then
        pass "overlayfs mounted successfully"

        # write through the overlay — should land in upper, not lower
        TEST_FILE="$WORK/overlay/etc/overlay-write-test"
        echo "written-by-test" > "$TEST_FILE"
        UPPER_COPY="$WORK/upper/upper/etc/overlay-write-test"

        if [ -f "$UPPER_COPY" ] && grep -q "written-by-test" "$UPPER_COPY"; then
            pass "write through overlay landed in NFS upper layer"
        else
            fail "write through overlay did not appear in NFS upper layer"
        fi

        if ! [ -f "$WORK/lower/etc/overlay-write-test" ]; then
            pass "lower (shared base) was not modified by the write"
        else
            fail "lower (shared base) was unexpectedly modified"
        fi

        # cleanup test file from upper
        rm -f "$UPPER_COPY"
    else
        fail "overlayfs mount failed"
    fi
else
    fail "could not bind-mount base as lower layer"
fi

# ── 5. cloud-init HTTP ───────────────────────────────────────────────────────

echo
echo "── 5. cloud-init HTTP ───────────────────────────────────────────"
META=$(curl -sf "http://$KICKSTART:8000/$SERIAL/meta-data")
if echo "$META" | grep -q "instance-id"; then
    pass "meta-data reachable (instance-id: $(echo "$META" | grep instance-id | cut -d' ' -f2))"
else
    fail "meta-data missing or malformed"
fi

USER=$(curl -sf "http://$KICKSTART:8000/$SERIAL/user-data")
if echo "$USER" | grep -q "#cloud-config"; then
    pass "user-data reachable and starts with #cloud-config"
else
    fail "user-data missing or does not start with #cloud-config"
fi

# ── summary ──────────────────────────────────────────────────────────────────

echo
echo "────────────────────────────────────────────────────────────────"
printf "Results: %s passed, %s failed\n" "$PASS" "$FAIL"
echo "────────────────────────────────────────────────────────────────"
[ "$FAIL" -eq 0 ]

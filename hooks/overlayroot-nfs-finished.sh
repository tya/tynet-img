#!/bin/sh
# initqueue/finished gate for overlayroot-nfs.
# Check actual mount state instead of state files (which get cleared).

# No overlay_host → not needed
grep -q 'overlay_host=' /proc/cmdline 2>/dev/null || return 0

# Check if overlay is already mounted on sysroot
grep -q 'overlay /sysroot' /proc/mounts 2>/dev/null && return 0

# Also check the state file as fallback (set on failure paths)
[ -f /run/overlayroot-nfs.done ] && return 0

return 1

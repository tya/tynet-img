#!/bin/sh
set -e

# Leave tftpd-hpa, nfs-server, rpcbind running — they're shared infrastructure
# that other tools on the host depend on. Only stop the timer we own.
if [ -d /run/systemd/system ]; then
    systemctl disable --now update-base.timer || true
fi

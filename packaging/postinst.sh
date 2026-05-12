#!/bin/sh
set -e

install -d -m 0755 /var/log/tynet-img
install -d -m 0755 /var/cache/img
install -d -m 0755 /srv/tftpboot
install -d -m 0755 /exports/netboot
install -d -m 0755 /exports/overlay

if [ -d /run/systemd/system ]; then
    systemctl daemon-reload
    systemctl enable --now rpcbind.service     || true
    systemctl enable --now nfs-server.service  || true
    systemctl restart    tftpd-hpa.service     || true
    systemctl enable --now update-base.timer   || true
fi

#!/bin/bash
# dracut module-setup.sh for overlayroot-nfs
# Installs the pre-pivot hook that sets up per-node overlayfs.

depends() {
    echo overlayfs
}

install() {
    inst_hook pre-pivot 15 "$moddir/overlayroot-nfs.sh"
}

#!/bin/bash
# dracut module-setup.sh for overlayroot-nfs

depends() {
    echo nfs overlayfs
}

install() {
    inst_hook pre-pivot 15 "$moddir/overlayroot-nfs-prepivot.sh"
}

SUMMARY = "Basic init for initramfs to mount and pivot root"
LICENSE = "CLOSED"

SRC_URI += "file://init"

do_install() {
    install -m 0755 "${WORKDIR}/init" "${D}/init"

    install -d "${D}/dev"
    mknod -m 0600 "${D}/dev/console" c 5 1
}

FILES:${PN} = "\
    /init \
    /dev \
"

RDEPENDS:${PN} += "\
    busybox \
    util-linux-mount \
"

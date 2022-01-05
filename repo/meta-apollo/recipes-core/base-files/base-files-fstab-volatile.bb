DESCRIPTION = "Base files volatile logdir"
AUTHOR = "Avast"

LICENSE = "CLOSED"
PACKAGE_ARCH = "${MACHINE_ARCH}"

DEPENDS = ""

do_fetch[deltask] = "1"
do_unpack[deltask] = "1"
do_compile[deltask] = "1"

PACKAGES = "${PN}"

SRC_URI = "file://fstab-logs"

do_install() {
    install -D -m 0644 ${WORKDIR}/fstab-logs ${D}/${sysconfdir}/fstab
}

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://inputrc"

do_install:append() {
	install -D -m 0644 ${WORKDIR}/inputrc ${D}${sysconfdir}/inputrc
}

CONFFILES:${PN} += "${sysconfdir}/inputrc"

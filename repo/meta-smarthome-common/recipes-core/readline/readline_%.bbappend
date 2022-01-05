FILESEXTRAPATHS_prepend := "${THISDIR}/files:"

SRC_URI += "file://inputrc"

do_install_append() {
	install -D -m 0644 ${WORKDIR}/inputrc ${D}${sysconfdir}/inputrc
}

CONFFILES_${PN} += "${sysconfdir}/inputrc"

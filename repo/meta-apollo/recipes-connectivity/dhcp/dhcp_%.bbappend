FILESEXTRAPATHS_prepend := "${THISDIR}/dhcp:"

SRC_URI += "file://dhcp-server"

PR = "2"

do_install_append() {
    install -m 0644 -D ${WORKDIR}/dhcp-server ${D}${sysconfdir}/default/dhcp-server
}

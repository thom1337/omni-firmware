FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

LICENSE = "CLOSED"

S = "${WORKDIR}"

SRC_URI = "file://system.conf"

do_fetch[deltask] = "1"
do_unpack[deltask] = "1"
do_compile[deltask] = "1"

PACKAGES = "${PN}"

do_install() {
    install -D -m 0644 ${WORKDIR}/system.conf ${D}${sysconfdir}/systemd/system.conf
}

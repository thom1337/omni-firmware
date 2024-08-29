FILESEXTRAPATHS:prepend := "${THISDIR}/systemd-serialgetty:"

SERIAL_CONSOLES = "115200;ttyAML0"

SRC_URI += "file://access.conf"

PR = "1"

do_install:append() {
    sed -i -e 's/\(sbin\/agetty\)/\1 \$ACCESS /' ${D}${systemd_unitdir}/system/serial-getty@.service
    install -D -m 0644 ${WORKDIR}/access.conf ${D}${systemd_unitdir}/system/serial-getty@.service.d/local.conf
}

PACKAGES += "${PN}-autologin"
RDEPENDS:${PN}-autologin = "${PN}"
FILES:${PN}-autologin = "${systemd_unitdir}/system/serial-getty@.service.d/local.conf"

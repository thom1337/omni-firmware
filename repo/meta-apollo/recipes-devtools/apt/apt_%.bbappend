FILESEXTRAPATHS:prepend := "${THISDIR}/apt:"
RDEPENDS:${PN}:remove = "bash"
RDEPENDS:${PN} += "gnupg"

SRC_URI += "file://logrotate.conf"

PR = "3"

do_install:append() {
    install -D -m 0644 ${WORKDIR}/logrotate.conf ${D}/${sysconfdir}/logrotate.d/apt.conf

    sed "s|#!/bin/bash|#!/bin/sh|g" -i ${D}${libdir}/dpkg/methods/apt/update
    sed "s|#!/bin/bash|#!/bin/sh|g" -i ${D}${libdir}/dpkg/methods/apt/install
}

SYSTEMD_SERVICE:${PN} = ""

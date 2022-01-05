FILESEXTRAPATHS_prepend := "${THISDIR}/apt:"
RDEPENDS_${PN}_remove = "bash"
RDEPENDS_${PN} += "gnupg"

SRC_URI += "file://logrotate.conf"

PR = "3"

do_install_append() {
    install -D -m 0644 ${WORKDIR}/logrotate.conf ${D}/${sysconfdir}/logrotate.d/apt.conf

    # remove unwanted timer and service
    rm ${D}/${systemd_system_unitdir}/apt-daily.timer
    rm ${D}/${systemd_system_unitdir}/apt-daily.service

    sed "s|#!/bin/bash|#!/bin/sh|g" -i ${D}/usr/lib/dpkg/methods/apt/update
    sed "s|#!/bin/bash|#!/bin/sh|g" -i ${D}/usr/lib/dpkg/methods/apt/install
}

SYSTEMD_SERVICE_${PN} = ""

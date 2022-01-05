APOLLO_RELEASE ??= "UNKNOWN"

FILESEXTRAPATHS_prepend := "${THISDIR}/files:"

hostname="avast-omni"

PR = "1"

SRC_URI += "file://motd.in"
SRC_URI += "file://fstab-logs"

do_install_append() {
    echo "${APOLLO_RELEASE}" > ${D}/${sysconfdir}/release
    sed -e 's|@MACHINE@|${MACHINE}|g' \
        -e 's|@VERSION@|${APOLLO_RELEASE}|g' \
        -e 's|@DISTRO@|${DISTRO}|g' \
        -e 's|@YVERSION@|${DISTRO_CODENAME}|g' \
        -e 's|@IMAGE_FEATURES@|${IMAGE_FEATURES}|g' \
        -e 's|@ENV@|${APOLLO_ENVIRONMENT}|g' \
        -e 's|@DATE@|${DATE}|g' ${WORKDIR}/motd.in > ${WORKDIR}/motd
    install -D -m 0644 ${WORKDIR}/motd ${D}/${sysconfdir}/motd

    rm -f ${D}/${sysconfdir}/issue
    ln -sf motd ${D}/${sysconfdir}/issue

    rm -f  "${D}${sysconfdir}/fstab"
}

FILES_${PN} += "${sysconfdir}/motd"
FILES_${PN}_remove = "${sysconfdir}/fstab"

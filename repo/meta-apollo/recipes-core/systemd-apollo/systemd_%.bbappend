FILESEXTRAPATHS_prepend := "${THISDIR}/files:"

PACKAGECONFIG_append = " coredump"

SERIAL_CONSOLES = "115200;ttyAML0"

SRC_URI += "file://resolved.conf"
SRC_URI += "file://systemd-tmpfiles-clean.timer"
SRC_URI += "file://resolv.conf"
SRC_URI += "file://10-data-mount.conf"
SRC_URI += "file://systemd-timesyncd.service"
SRC_URI += "file://data.mount"
SRC_URI += "file://eth.network"
SRC_URI += "file://networkd.conf"
SRC_URI += "file://10-enable_rps.conf"
SRC_URI += "file://journald.conf"

PACKAGECONFIG_remove = "hibernate"
PACKAGECONFIG_remove = "vconsole"

PR = "r3"

RDEPENDS_libsystemd += "${PN} (= ${EXTENDPKGV})"
DEPENDS += " coreutils-native"

do_install_append() {
    # mask systemd-journald-audit
    ln -sf /dev/null ${D}/etc/systemd/system/systemd-journald-audit.socket

    ln -sf /data/etc/systemd/network/00-eth0.network ${D}${sysconfdir}/systemd/network/00-eth0.network
    install -m 0644 ${WORKDIR}/resolved.conf ${D}${sysconfdir}/systemd/resolved.conf

    install -m 0644 ${WORKDIR}/systemd-tmpfiles-clean.timer ${D}/lib/systemd/system/systemd-tmpfiles-clean.timer
    install -m 0644 ${WORKDIR}/systemd-timesyncd.service ${D}/lib/systemd/system/systemd-timesyncd.service

    sed -i -e "/^L! \/etc\/resolv.conf.*$/d" ${D}${exec_prefix}/lib/tmpfiles.d/etc.conf
    install -m 0644 ${WORKDIR}/resolv.conf ${D}${sysconfdir}/resolv.conf
    rm -f ${D}${sysconfdir}/resolv-conf.systemd
    ln -sf ../run/systemd/resolve/stub-resolv.conf ${D}${sysconfdir}/resolv-conf.systemd

    mkdir -p ${D}/etc/systemd/system/systemd-networkd.service.d/
    install -m 0644 ${WORKDIR}/10-data-mount.conf ${D}/etc/systemd/system/systemd-networkd.service.d/

    install -D -m 0644 ${WORKDIR}/10-enable_rps.conf ${D}${sysconfdir}/tmpfiles.d/
    install -D -m 0644 ${WORKDIR}/eth.network ${D}/${sysconfdir}/systemd/network/eth.network
    install -D -m 0644 ${WORKDIR}/data.mount ${D}/lib/systemd/system/data.mount
    install -m 0644 ${WORKDIR}/networkd.conf ${D}${sysconfdir}/systemd/
    install -m 0644 ${WORKDIR}/journald.conf ${D}${sysconfdir}/systemd/
    mkdir -p ${D}/${sysconfdir}/systemd/system/multi-user.target.wants/
    ln -s /lib/systemd/system/data.mount ${D}/${sysconfdir}/systemd/system/multi-user.target.wants/data.mount

    # Remove unused configuration file
    rm -f ${D}${systemd_unitdir}/network/80-wired.network
    rm ${D}/lib/systemd/network/80-container-host0.network
    rm ${D}/lib/systemd/network/80-container-ve.network
    rm ${D}/lib/systemd/network/80-container-vz.network

    # Remove configuration file installed systemd-config*.bb
    rm -f ${D}/etc/systemd/system.conf
}

pkg_postinst_${PN} () {
    sed -e '/^hosts:/s/\s*\<myhostname\>//' \
        -e 's/\(^hosts:.*\)/\1 myhostname/' \
        -i $D${sysconfdir}/nsswitch.conf
}

CONFFILES_${PN} = "${sysconfdir}/resolv.conf"
FILES_${PN} += "${sysconfdir}/resolv.conf"
ALTERNATIVE_LINK_NAME[resolv-conf] = ""
ALTERNATIVE_TARGET[resolv-conf] = "${sysconfdir}/resolv.conf"

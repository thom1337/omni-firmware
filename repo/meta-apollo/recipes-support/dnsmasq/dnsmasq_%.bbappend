FILESEXTRAPATHS_prepend := "${THISDIR}/dnsmasq:"

PR = "2"

SRC_URI += "file://dnsmasq.conf"

SYSTEMD_AUTO_ENABLE_${PN} = "disable"

do_install_append() {
    mkdir -p ${D}/${sysconfdir}/
    install -D -m 0644 ${WORKDIR}/dnsmasq.conf ${D}/${sysconfdir}/dnsmasq.conf

    # Don't disable binding to loopback interface for systemd-resolved:
    sed -i '/^DNSStubListener=no/s!^!# !' ${D}${sysconfdir}/systemd/resolved.conf.d/dnsmasq-resolved.conf
}

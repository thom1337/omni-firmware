FILESEXTRAPATHS_prepend := "${THISDIR}/procps:"

SRC_URI += "file://decrease_tcp_conntrack_timeout.conf"
SRC_URI += "file://disable_ipv4_redirection.conf"
SRC_URI += "file://enable_forwarding.conf"
SRC_URI += "file://local_port_range.conf"

PR = "2"

do_install_append() {
    install -D -m 0644 ${WORKDIR}/decrease_tcp_conntrack_timeout.conf ${D}/${sysconfdir}/sysctl.d/
    install -D -m 0644 ${WORKDIR}/disable_ipv4_redirection.conf ${D}/${sysconfdir}/sysctl.d/
    install -D -m 0644 ${WORKDIR}/enable_forwarding.conf ${D}/${sysconfdir}/sysctl.d/
    install -D -m 0644 ${WORKDIR}/local_port_range.conf ${D}/${sysconfdir}/sysctl.d/
}

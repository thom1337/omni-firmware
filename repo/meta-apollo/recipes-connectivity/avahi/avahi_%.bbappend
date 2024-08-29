FILESEXTRAPATHS:prepend := "${THISDIR}/avahi:"

PR = "r4"

SRC_URI += "file://avahi-daemon.conf \
            file://avast-omni.service \
            file://0002-Resolve-conflicts-with-itself.patch \
            "

do_install:append() {
    mkdir -p ${D}/${sysconfdir}/avahi/services/
    install -D -m 0644 ${WORKDIR}/avahi-daemon.conf ${D}/${sysconfdir}/avahi/
    install -D -m 0644 ${WORKDIR}/avast-omni.service ${D}/${sysconfdir}/avahi/services

    rm -f ${D}/${sysconfdir}/avahi/services/sftp-ssh.service
    rm -f ${D}/${sysconfdir}/avahi/services/ssh.service
}

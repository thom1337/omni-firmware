FILESEXTRAPATHS_prepend := "${THISDIR}/files:"

PR = "1"

SRC_URI += " \
	file://syslog-ng.conf.systemd \
	file://syslog-ng.logrotate \
	file://syslog-ng.service \
"

do_install_append() {
	install -D -m 0644 ${WORKDIR}/syslog-ng.logrotate ${D}${sysconfdir}/logrotate.d/syslog-ng.conf

	# remove original instance-based service file
	rm -f ${D}${systemd_unitdir}/system/${BPN}@.service
	rm -f ${D}${systemd_unitdir}/system/multi-user.target.wants/${BPN}@default.service

	# put in new service file as the syslog socket doesn't support instance-based handling
	# and thus only one instance can be created at a time and also specific format of the
	# service file is required when using the syslog facility of journald
	#
	# Written according to information in https://www.freedesktop.org/wiki/Software/systemd/syslog/
	install -D -m 0644 ${WORKDIR}/syslog-ng.service ${D}${systemd_unitdir}/system/${BPN}.service
	ln -sf ../${BPN}.service ${D}${systemd_unitdir}/system/multi-user.target.wants/${BPN}.service

	mv ${D}${sysconfdir}/default/${BPN}@default ${D}${sysconfdir}/default/${BPN}
}

SYSTEMD_SERVICE_${PN} = "${BPN}.service"

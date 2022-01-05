LOGROTATE_SYSTEMD_TIMER_BASIS = "*:0/1"
LOGROTATE_SYSTEMD_TIMER_ACCURACY = "30s"

do_install_append() {
	sed -i 's/^dateext/nodateext/' ${D}/etc/logrotate.conf
	rm ${D}/etc/logrotate.d/btmp
}

do_install:append() {
    rm -f ${D}/lib/systemd/network/80-wired.network
}

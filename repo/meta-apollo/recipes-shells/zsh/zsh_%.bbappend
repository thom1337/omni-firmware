FILESEXTRAPATHS:prepend := "${THISDIR}/zsh:"

SRC_URI += "file://zshenv"

do_install:append() {
    install -D -m0644 ${WORKDIR}/zshenv ${D}/etc/zshenv
}

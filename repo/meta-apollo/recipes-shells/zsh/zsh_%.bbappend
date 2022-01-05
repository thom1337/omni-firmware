FILESEXTRAPATHS_prepend := "${THISDIR}/zsh:"

SRC_URI += "file://zshenv"

do_install_append() {
    install -D -m0644 ${WORKDIR}/zshenv ${D}/etc/zshenv
}

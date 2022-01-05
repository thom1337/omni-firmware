FILESEXTRAPATHS_prepend := "${THISDIR}/files:"

SRC_URI += "file://mktemp"
SRC_URI += "file://timeout"

RDEPENDS_${PN} = "zsh"

do_install_append() {
	install -m 0755 ${WORKDIR}/mktemp ${D}${bindir}/mktemp
	install -m 0755 ${WORKDIR}/timeout ${D}${bindir}/timeout
}

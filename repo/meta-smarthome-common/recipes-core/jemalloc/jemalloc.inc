DESCRIPTION = "jemalloc is a general purpose malloc"

LICENSE = "BSD-2-Clause"
LIC_FILES_CHKSUM = "file://COPYING;md5=ea061f8731d5e6a5761dfad951ef5f5f"

SRC_URI[sha256sum] = "74be9f44a60d2a99398e706baa921e4efde82bf8fd16e5c0643c375c5851e3b4"

PV = "5.2.0"
PR = "r4"
SRC_URI = "https://github.com/jemalloc/jemalloc/releases/download/${PV}/jemalloc-${PV}.tar.bz2"

EXTRA_OECONF += "--disable-fill --disable-prof-gcc --disable-prof-libgcc --doc=no --docdir=$(datarootdir)/doc"
DISABLE_STATIC = ""

inherit autotools

S = "${WORKDIR}/jemalloc-${PV}"

do_configure() {
    oe_runconf
}

PACKAGES =+ "${PN}-bin"
FILES_${PN}-bin += "${bindir}/jeprof \
    ${bindir}/jemalloc.sh \
    ${bindir}/jemalloc-config \
"

DEBIAN_NOAUTONAME_${PN} = "1"
DEBIAN_NOAUTONAME_${PN}-bin = "1"
DEBIAN_NOAUTONAME_${PN}-dbg = "1"
DEBIAN_NOAUTONAME_${PN}-dev = "1"
DEBIAN_NOAUTONAME_${PN}-staticdev = "1"
DEBIAN_NOAUTONAME_${PN}-doc = "1"
DEBIAN_NOAUTONAME_${PN}-src = "1"

DEPENDS += "libxslt-native"

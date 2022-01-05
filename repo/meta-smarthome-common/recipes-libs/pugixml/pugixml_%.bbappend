FILESEXTRAPATHS_prepend := "${THISDIR}/${PN}:"
PR = "r3"

EXTRA_OECMAKE += "-DBUILD_SHARED_AND_STATIC_LIBS=ON"

SRC_URI += "file://0001-Keep-original-name-of-shared-library-when-both-share.patch"

FILESEXTRAPATHS_prepend := "${THISDIR}/boost:"

PR = "3"

SRC_URI += "file://0004-Fix_for_double_closed_FD.patch"
SRC_URI += "file://0001-Field-digest-is-endian-independent.patch"

LICENSE:${PN} = "GPL-2.0-only & GPL-2.0-or-later & LGPL-3.0-or-later & GPL-3.0-or-later"

FILES:${PN}-binutils = " \
    ${bindir}/eu-* \
"

FILES:${PN} = ""
ALLOW_EMPTY:${PN} = "1"

# Exclude unnecessary files and directories
do_install:append() {
    rm -rf ${D}/etc/profile.d/debuginfod.csh
    rm -rf ${D}/etc/profile.d/debuginfod.sh
    rm -rf ${D}/usr/bin/debuginfod-find
    rm -rf ${D}/usr/bin/debuginfod
    rm -rf ${D}/etc/profile.d
    rm -rf ${D}/etc/debuginfod
    rm -rf ${D}/etc
}

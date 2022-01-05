DISABLE_STATIC = ""
PR="r5"

do_install_append() {
    sed -i "s/Requires.private:/Requires:/g" ${D}/${libdir}/pkgconfig/libssh2.pc
}

EXTRA_OECONF += "\
    --enable-crypt-none \
    --enable-mac-none \
"

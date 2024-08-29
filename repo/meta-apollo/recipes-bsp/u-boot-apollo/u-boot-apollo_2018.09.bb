require u-boot-apollo-common.inc
require recipes-bsp/u-boot-apollo/u-boot.inc

DEPENDS += "bison-native bc-native dtc-native python3-native"

PROVIDES = "u-boot"

do_install:append() {
    # fw_env.config is installed by u-boot-fw-utils to all images
    rm -f ${D}${sysconfdir}/fw_env.config
}

addtask do_deploy after do_install
do_deploy[nostamp] = "1"

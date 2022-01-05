DESCRIPTION = "Skyline convert package group"

inherit packagegroup

PACKAGES = " \
    packagegroup-image-prod \
"

RDEPENDS_${PN}-prod = " \
    systemd-serialgetty-autologin \
    systemd-config \
"

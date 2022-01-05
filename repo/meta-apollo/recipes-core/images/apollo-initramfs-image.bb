LICENSE = "CLOSED"

PACKAGE_INSTALL = " \
    initrd-apollo \
    busybox \
    util-linux-mount \
    u-boot-fw-utils-apollo \
    kernel-modules \
    udev \
"

# Do not pollute the initrd image with rootfs features
IMAGE_FEATURES = ""

export IMAGE_BASENAME = "apollo-initramfs-image"
IMAGE_LINGUAS = ""

IMAGE_FSTYPES = "${INITRAMFS_FSTYPES}"

inherit core-image

IMAGE_ROOTFS_SIZE = "1024"
IMAGE_ROOTFS_EXTRA_SPACE = "0"

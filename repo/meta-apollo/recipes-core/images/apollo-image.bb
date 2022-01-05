DESCRIPTION = "Apollo project base image"

include apollo-image.inc

do_rootfs[depends] += "apollo-initramfs-image:do_image_complete"
do_image_wic[depends] += "apollo-image:do_image_ext4"

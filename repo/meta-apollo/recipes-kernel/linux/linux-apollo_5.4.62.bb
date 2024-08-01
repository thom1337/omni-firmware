LINUX_VERSION = "5.4.62"
PR = "r5"

DEPENDS += "rsync-native coreutils-native"

FILESEXTRAPATHS_prepend := "${THISDIR}/files:"

SRCREV = "933cf1c2c075f44c7b6837b6201e0db2d488835a"
SRC_URI = "git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git;protocol=git;branch=linux-5.4.y \
           file://0001-arm64-dts-meson-axg-add-apollo-evt0-board.patch \
           file://0002-arm64-dts-apollo-fix-emmc-maximum-rate.patch \
           file://0003-arm64-dts-meson-axg-s400-Enable-PHY-interrupt.patch \
           file://0004-arm64-dts-apollo-Drop-the-evt0-suffix.patch \
           file://0005-DOWNSTREAM-apollo-leds-Set-initial-brightness-level.patch \
           file://0006-arm64-dts-apollo-enable-dma-thresh-mode.patch \
           file://0007-defconfigs-is-added.patch \
           file://0008-arm64-update-Kconfig-to-better-handle-CMDLINE.patch \
           file://0009-apollo_defconfig-remove-additional-schedulers-for-tr.patch \
           file://0010-tcp_conntracks-accept-connections-for-uni-directiona.patch \
           file://0011-apollo_defconfig-enable-CONFIG_IPV6_MULTIPLE_TABLES.patch \
           file://0012-meson-axg-apollo-reserve-memory-for-pstore_ram.patch \
           file://0013-amlogic-remove-unused-target.patch \
           file://0014-meson-axg-apollo-disable-force_thresh_dma_mode.patch \
           file://defconfig \
           file://0016-perf-Make-perf-able-to-build-with-latest-libbfd.patch \
           file://0021-avastmark-extra-marks-for-packets-and-connections.patch \
"

# make perf compileable with gcc10
SRC_URI += " \
    file://0018-perf-tests-bp_account-Make-global-variable-static.patch \
    file://0019-perf-env-Do-not-return-pointers-to-local-variables.patch \
    file://0020-perf-bench-Share-some-global-variables-to-fix-build-.patch \
    file://0017-perf-share-some-global-variables-to-fix-build-with-g.patch \
"

# add kernel modules needed for NordVPN
SRC_URI += " \
    file://0022-nordvpn-kernel-modules.patch \
"

KERNEL_VERSION_SANITY_SKIP="1"

KERNEL_CLASSES = "kernel-uimage-meson"

require recipes-kernel/linux/linux-meson.inc

# Checksum changed on 4.17
LIC_FILES_CHKSUM = "file://COPYING;md5=bbea815ee2795b2f4230826c0c6b8814"

FILES_${KERNEL_PACKAGE_NAME}-base += "${nonarch_base_libdir}/modules/${KERNEL_VERSION}/modules.builtin.modinfo"

DESCRIPTION = "Apollo EVT0 u-boot"
SECTION = "bootloaders"

FILESEXTRAPATHS_prepend := "${THISDIR}/files:"

LICENSE = "GPLv2+"
LIC_FILES_CHKSUM = "file://Licenses/README;md5=30503fd321432fc713238f582193b78e"
PE = "1"

SRC_URI = "git://git.denx.de/u-boot.git \
           file://0001-net-designware-add-meson-meson-gxbb-comptatible.patch \
           file://0002-ARM-meson-clean-up-platform-selection.patch \
           file://0003-configs-meson-remove-unnecessary-MESON_FDTFILE_SETTI.patch \
           file://0004-board-amlogic-remove-p212-derivatives.patch \
           file://0005-board-amlogic-factorise-gxbb-boards.patch \
           file://0006-ARM-rework-amlogic-configuration.patch \
           file://0007-configs-meson-change-default-load-addresses.patch \
           file://0008-pinctrl-meson-rework-gx-pmx-function.patch \
           file://0009-pinctrl-meson-select-generic-pinctrl.patch \
           file://0010-pinctrl-meson-add-axg-support.patch \
           file://0011-clk-Add-clock-driver-for-AXG.patch \
           file://0012-clk-meson-silence-debug-print.patch \
           file://0013-mmc-meson-gx-Add-AXG-compatible.patch \
           file://0014-ARM-meson-rework-soc-arch-file-to-prepare-for-new-So.patch \
           file://0015-ARM-meson-Add-support-for-AXG-family.patch \
           file://0016-ARM-dts-Sync-Amlogic-Meson-AXG-DT-from-Linux.patch \
           file://0017-arm64-meson-axg-fixups-for-U-Boot.patch \
           file://0018-ARM-dts-meson-axg-s400-add-chosen-and-memory-nodes.patch \
           file://0019-board-amlogic-add-support-for-S400-board.patch \
           file://0020-ARM-meson-factorise-common-code-out-amlogic-s-boards.patch \
           file://0021-ARM-meson-Add-boot-device-discovery.patch \
           file://0022-spi-Add-Amlogic-Meson-SPI-Flash-Controller-driver.patch \
           file://0023-mtd-sf_probe-add-jedec-spi-nor-compatible.patch \
           file://0024-board-amlogic-apollo-support.patch \
           file://0025-configs-apollo-add-env-checking-and-reset.patch \
           file://0026-gpio-meson-Fix-Synchronous-Abort-when-accessing-GPIO.patch \
           file://0027-pinctrl-meson-Fix-GPIO-direction-registers-access.patch \
           file://0028-mender-Add-missing-header-which-fails-on-recent-GCC.patch \
           file://0029-mender-Generic-boot-code-for-Mender.patch \
           file://0030-mender-Integration-of-Mender-boot-code-into-U-Boot.patch \
           file://0031-mender-Disable-CONFIG_BOOTCOMMAND-and-enable-CONFIG_.patch \
           file://0032-mender-apollo-Import-generated-config_mender_defines.patch \
           file://0033-mender-apollo-Apply-mender_auto_configured.patch.patch \
           file://0034-mender-apollo-Move-again-env-to-the-boot0-partition.patch \
           file://0035-mender-apollo-Introduce-the-initramfs.patch \
           file://0036-mender-apollo-Do-not-set-CONFIG_ENV_OFFSET_REDUND.patch \
           file://0037-mender-apollo-Set-default-env-on-first-run.patch \
           file://0038-defconfig-apollo-Regenerate-defconfig.patch \
           file://0039-defconfig-apollo-Enable-fixed-bootargs.patch \
           file://0040-apollo-Restore-kernel_addr_r.patch \
           file://0041-defconfig-apollo-Enable-CONFIG_CMD_SETEXPR.patch \
           file://0042-recovery-apollo-Introduce-check_reset_button.patch \
           file://0043-apollo-Improve-legibility-of-bootcmd-script.patch \
           file://0044-recovery-apollo-Add-support-for-recovery-reset.patch \
           file://0045-recovery-apollo-No-initramfs-on-recovery-partition.patch \
           file://0046-recovery-apollo-Pass-the-correct-init-parameter.patch \
           file://0047-recovery-apollo-Check-registers-to-detect-button.patch \
           file://0048-recovery-apollo-Save-partition-A-number-hex-for-rese.patch \
           file://0049-eol-apollo-Introduce-eol-env-variable.patch \
           file://0050-apollo-Drop-the-EVT0-suffix.patch \
           file://0051-apollo-Fix-the-initramfs-name.patch \
           file://0052-pinctrl-meson-axg-Fix-GPIO-pin-offsets.patch \
           file://0053-apollo-Implement-LED-boot-protocol-as-dictated-by-Av.patch \
           file://0054-apollo-Move-force_run_eol-definition.patch \
           file://0055-apollo-Run-MFC-on-first-boot.patch \
           file://fw_env.config \
"

# we will keep old initial image support for multiple env.
SRC_URI += '${@bb.utils.contains_any("IMAGE_FEATURES", 'debug-tweaks', "", " file://0099-dissable-boot-dalay-and-abort.patch ",d)}'

SRCREV = "f88b6facb87dc4a52f1630eb9d858c0f54c6628e"

S = "${WORKDIR}/git"

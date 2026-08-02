# SPDX-License-Identifier: GPL-2.0
#
# Avast Omni - Amlogic A113D (meson-axg), quad A53, 512 MB RAM, eMMC,
# one RTL8211F RGMII gigabit NIC, no display, no wireless, headless, in a closet.
#
# ==============================================================================
#  THIS BOARD IS A KERNEL FACTORY ONLY.
# ==============================================================================
#  Armbian is used to produce linux-image / linux-dtb / linux-headers /
#  linux-libc-dev .debs and NOTHING ELSE. The rootfs is built separately with
#  mmdebstrap; Armbian never builds an image for this board and must never,
#  under any circumstance, compile or write a bootloader:
#
#    * the Omni boots a vendor U-Boot 2018.09 carrying the Mender A/B contract,
#    * its environment is a SINGLE non-redundant 8 KB copy at offset 0 of
#      /dev/mmcblk0boot0 (no redundant copy to fall back to), and
#    * that U-Boot is the only thing standing between us and a device that has
#      to come back from a customer site to be re-flashed over USB.
#
#  BOOTCONFIG="none" below is the load-bearing line. Everything else is detail.
#
#  Source of truth for this file is <omni-firmware>/board/avast-omni.csc.
#  It is copied into armbian/config/boards/ by tools/sync-armbian-board.sh.
#  Do not edit the copy inside the armbian/ submodule - it is overwritten.
#
#  Build with:
#    cd armbian && ./compile.sh kernel BOARD=avast-omni BRANCH=oldlts
#    cd armbian && ./compile.sh dts-check BOARD=avast-omni BRANCH=oldlts
# ==============================================================================

BOARD_NAME="Avast Omni"
BOARD_VENDOR="avast"
# meson-axg is a real Armbian family (config/sources/families/meson-axg.conf ->
# include/meson64_common.inc). It gives us LINUXFAMILY=meson64, ARCH=arm64,
# SERIALCON=ttyAML0 and the oldlts/current/edge -> 6.12/6.18/7.1 mapping.
BOARDFAMILY="meson-axg"
# Deliberately empty: this board is not upstreamed to Armbian and has no Armbian
# maintainer. Armbian's inventory tooling only warns on an empty value.
BOARD_MAINTAINER=""
INTRODUCED="2026"

# ------------------------------------------------------------------------------
# Bootloader: NEVER.
# ------------------------------------------------------------------------------
# "none" is checked verbatim in four places in the framework (verified against
# armbian/build main @ 587b6f2c):
#   lib/functions/main/config-prepare.sh:298  -> ARMBIAN_WILL_BUILD_UBOOT=no
#   lib/functions/main/build-packages.sh:11   -> "uboot" artifact is not built
#   lib/functions/image/rootfs-to-image.sh:101-> write_uboot_to_loop_image skipped
#   lib/functions/rootfs/distro-agnostic.sh:359
# With this set, no u-boot source is fetched, no defconfig is compiled, no FIP
# blobs are pulled, and nothing is ever dd'd to a device or loop image.
# Same pattern as config/sources/families/cix-p1.conf and genio.conf upstream.
BOOTCONFIG="none"

# ------------------------------------------------------------------------------
# Kernel
# ------------------------------------------------------------------------------
# Single target on purpose. meson64_common.inc maps oldlts -> 6.12 today; the
# post_family_config__avast-omni extension re-asserts KERNEL_MAJOR_MINOR="6.12"
# so that an armbian/ submodule bump which re-points "oldlts" at a newer series
# fails loudly instead of silently shipping a different kernel to the field.
KERNEL_TARGET="oldlts"
KERNEL_TEST_TARGET="oldlts"

# Required by ./compile.sh dts-check (lib/functions/compilation/kernel-dts-check.sh:13
# exits with an error when unset) and by kernel.sh:186 which copies the
# preprocessed + binary DTB out for development. The .dts lands in the tree via
# patch/kernel/archive/meson64-6.12/dt/ (dts-directories in 0000.patching_config.yaml).
# NOTE: this file does not exist until Phase 3; dts-check fails until it does.
BOOT_FDT_FILE="amlogic/meson-axg-apollo.dtb"

# Set by meson64_common.inc already; repeated here because the Omni has exactly
# one usable console (3.3 V UART on ttyAML0, case open) and if that is ever
# wrong there is no second way into the box - no video, no keyboard, and SSH
# needs the network that the serial console is used to debug.
SERIALCON="ttyAML0"
DEFAULT_CONSOLE="serial"
HAS_VIDEO_OUTPUT="no"

# Disable BTF/DWARF debug info. Two reasons, both real:
#  1. armbian_kernel_config__600_enable_ebpf_and_btf_info() (armbian-kernel.sh:112)
#     FORCES CONFIG_DEBUG_INFO/DWARF5/BTF=y unless KERNEL_BTF="no". Those opts are
#     applied to .config AFTER our kernel config override is copied in, so the
#     "# CONFIG_DEBUG_INFO is not set" line in board/linux-meson64-omni.config
#     CANNOT win on its own - this variable is the only thing that makes it stick.
#  2. that same function hard-aborts the build on any host with < 6451 MiB of
#     available RAM (armbian-kernel.sh:133).
# The plan's kernel-config delta requires DEBUG_INFO unset (5.4 had it on).
KERNEL_BTF="no"

# Mainline added nand-controller@7800 whose "emmc" reg window IS sd_emmc_c's
# window, with no status property (verified on v6.12), and Armbian ships
# MTD_NAND_MESON=m - so the module exists and would bind to the eMMC pads.
# The DTS disables &nfc and CONFIG_MTD_NAND_MESON=n in the config delta is the
# real fix; this line is belt-and-braces and only has any effect if an Armbian
# rootfs/BSP is ever built for this board (it is not - see the header).
MODULES_BLACKLIST="meson_nand"

# Advisory / documentation only: no Armbian image is ever produced for this
# board, so SRC_CMDLINE is never consumed. It records the cmdline the Omni's
# U-Boot must end up passing. root= is deliberately absent because
# MENDER_BOOTARGS prepends root=${mender_kernel_root} on every boot, and a
# second root= would win by last-occurrence and cross-wire the A/B slots.
SRC_CMDLINE="console=ttyAML0,115200n8 rootwait rw panic=10"

# Pulls in board/post_family_config__avast-omni.sh, which
# tools/sync-armbian-board.sh installs to armbian/userpatches/extensions/.
# enable_extension() searches ${USERPATCHES_PATH}/extensions first, then
# ${SRC}/extensions, and exits 17 if the file is missing - so a build run
# against an un-synced tree fails immediately instead of silently building an
# unpinned kernel. Must be called from the board file: enable_extension() is
# only legal before initialize_extension_manager() runs, which happens right
# before the post_family_config hook point in do_main_configuration().
enable_extension "post_family_config__avast-omni"

# ------------------------------------------------------------------------------
# Tripwires
# ------------------------------------------------------------------------------
# post_family_config runs after config/sources/families/meson-axg.conf (and thus
# after meson64_common.inc) has been sourced, so this is the correct place to
# override things the family defined. Same technique as
# config/boards/gateway-gz80x.conf, which defines write_uboot_platform() here.
function post_family_config__avast_omni_forbid_uboot() {
	# Re-assert, in case a user config or a future family default sets it.
	declare -g BOOTCONFIG="none"

	# meson64_common.inc defines a write_uboot_platform() that dd's u-boot.bin
	# over the first sectors of $2. Replace it with something that cannot do
	# damage. With BOOTCONFIG="none" it is never called; if a framework change
	# ever calls it anyway, the build dies here instead of on the device.
	write_uboot_platform() {
		exit_with_error "avast-omni: refusing to write U-Boot" \
			"BOOTCONFIG=none; the Omni's vendor U-Boot 2018.09 and its single non-redundant env copy must never be touched (target was: '${2:-?}')"
	}

	# Same for the Amlogic FIP post-processing step.
	uboot_custom_postprocess() {
		exit_with_error "avast-omni: refusing to post-process U-Boot" \
			"BOOTCONFIG=none; no bootloader is built for this board"
	}
}

# extension_finish_config is called at the end of config_post_main, i.e. AFTER
# config-prepare.sh:298 has computed ARMBIAN_WILL_BUILD_UBOOT. Assert the
# outcome rather than trusting the input.
function extension_finish_config__avast_omni_assert_no_uboot() {
	if [[ "${ARMBIAN_WILL_BUILD_UBOOT}" != "no" ]]; then
		exit_with_error "avast-omni: ARMBIAN_WILL_BUILD_UBOOT='${ARMBIAN_WILL_BUILD_UBOOT}'" \
			"expected 'no'. Something re-set BOOTCONFIG (currently '${BOOTCONFIG}'). Refusing to continue."
	fi
	display_alert "avast-omni" "u-boot build disabled (BOOTCONFIG=none), kernel-only build" "info"
}

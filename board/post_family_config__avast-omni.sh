#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Armbian userpatches extension: post_family_config__avast-omni
#
#  Source of truth is <omni-firmware>/board/post_family_config__avast-omni.sh.
#  tools/sync-armbian-board.sh installs it to
#      armbian/userpatches/extensions/post_family_config__avast-omni.sh
#  which is where enable_extension() looks first
#  (lib/functions/general/extensions.sh:478: "${USERPATCHES_PATH}/extensions"
#  then "${SRC}/extensions"; the file name IS the extension name). It is pulled
#  in by `enable_extension "post_family_config__avast-omni"` in
#  config/boards/avast-omni.csc - board files are sourced by
#  config_source_board_file() well before initialize_extension_manager(), which
#  is the deadline for calling enable_extension().
#
#  Purpose
#  -------
#  1. Pin KERNEL_MAJOR_MINOR so a KERNEL_TARGET branch NAME cannot silently roll
#     the kernel series forward.  config/sources/families/include/meson64_common.inc
#     maps BRANCH names to versions in a plain `case`:
#         oldlts -> 6.12   current -> 6.18   edge -> 7.1   bleedingedge -> 7.2
#     Those mappings move. KERNEL_MAJOR_MINOR is not cosmetic: it selects the
#     kernel git branch (mainline-kernel.conf.sh:40 -> branch:linux-<X.Y>.y),
#     the patch archive (config/sources/common.conf:127 ->
#     patch/kernel/archive/meson64-<X.Y>) and the source worktree
#     (config-prepare.sh:284). An armbian/ submodule bump that re-points
#     "oldlts" would otherwise ship a different kernel to a fleet of headless
#     boxes with no console, and the only symptom would be the deb version.
#     This is plan risk #8.
#
#  2. Force CONFIG_OVERLAY_FS=y past Armbian's own opts_m+=("OVERLAY_FS").
#     See the long comment on that hook below.
#
#  post_family_config is the right hook point for (1): it is called from
#  do_main_configuration() immediately after
#  config/sources/families/${LINUXFAMILY}.conf has been sourced, i.e. after the
#  family has set KERNEL_MAJOR_MINOR and before config_post_main() consumes it.
#

# The pin. Changing the kernel series is a deliberate, reviewed act: bump this,
# bump AVAST_OMNI_PINNED_BRANCH if the branch name changes, move
# board/meson-axg-apollo.dts to the matching patch/kernel/archive/meson64-<X.Y>/dt/
# via tools/sync-armbian-board.sh --kernel-version, and re-run the Phase 4 gate.
# Pinned to 6.18 (Armbian "current"), NOT 6.12 ("oldlts"), for two reasons found
# by building rather than by reading:
#   1. 6.12 does not build at the pinned armbian SHA. Its published artifact is
#      not anonymously pullable ("denied: requested access to the resource is
#      denied"), so the build falls back to source, and that fails inside
#      Armbian's own patching.py before any patch is applied -- reproduced on the
#      stock gateway-gz80x board with none of our files involved.
#   2. 6.12 LTS reaches EOL in Dec 2026; 6.18 runs into late 2027.
# board/meson-axg-apollo.dts compiles clean against both series, so this is a
# one-line pin, not a port.
declare -g AVAST_OMNI_PINNED_KERNEL="6.18"
declare -g AVAST_OMNI_PINNED_BRANCH="current"

function post_family_config__avast_omni_pin_kernel_major_minor() {
	declare want="${AVAST_OMNI_PINNED_KERNEL}"
	declare got="${KERNEL_MAJOR_MINOR:-}"

	# Only pin the branch we actually ship. Someone deliberately building
	# BRANCH=current to evaluate 6.18 must not be silently dragged back to 6.12.
	if [[ "${BRANCH}" != "${AVAST_OMNI_PINNED_BRANCH}" ]]; then
		display_alert "avast-omni" \
			"BRANCH='${BRANCH}' is not the pinned '${AVAST_OMNI_PINNED_BRANCH}'; leaving KERNEL_MAJOR_MINOR='${got:-unset}' alone. This build is NOT the shipping configuration." "wrn"
		return 0
	fi

	if [[ -z "${got}" ]]; then
		# Family config did not resolve the branch at all - the case statement
		# no longer has an "oldlts" arm. Loud, not silent.
		display_alert "avast-omni" \
			"family '${BOARDFAMILY}' left KERNEL_MAJOR_MINOR unset for BRANCH='${BRANCH}'; forcing '${want}'" "wrn"
	elif [[ "${got}" != "${want}" ]]; then
		# This is the failure this whole file exists to catch.
		display_alert "avast-omni" \
			"UPSTREAM MOVED: Armbian now maps BRANCH='${BRANCH}' to kernel ${got}, but this board is pinned to ${want}. Forcing ${want}. Re-validate before changing the pin (Phase 4 gate)." "wrn"
	fi

	declare -g KERNEL_MAJOR_MINOR="${want}"

	# Fail now, with a useful message, rather than 20 minutes into a build:
	# once upstream drops the archive for a series, the pin cannot be honoured.
	declare archive_dir="${SRC}/patch/kernel/archive/meson64-${want}"
	if [[ ! -d "${archive_dir}" ]]; then
		exit_with_error "avast-omni: pinned kernel ${want} has no patch archive" \
			"missing '${archive_dir}' - the armbian/ submodule no longer carries meson64-${want}. Either roll the submodule back to a commit that does, or move the pin (and the DTS drop directory) forward deliberately."
	fi

	# The DTS is dropped in by the dts-directories mechanism declared in
	# ${archive_dir}/0000.patching_config.yaml. Warn (do not fail) if it is not
	# there yet: Phase 2 stands up the factory, Phase 3 authors the DTS.
	if [[ ! -f "${archive_dir}/dt/meson-axg-apollo.dts" ]]; then
		display_alert "avast-omni" \
			"no meson-axg-apollo.dts in ${archive_dir}/dt/ - kernel will build, dts-check and BOOT_FDT_FILE will not (expected before Phase 3)" "wrn"
	fi

	display_alert "avast-omni" "kernel pinned to ${want} (BRANCH=${BRANCH})" "info"
}

# --------------------------------------------------------------------------
# CONFIG_OVERLAY_FS=y
# --------------------------------------------------------------------------
# board/linux-meson64-omni.config asks for OVERLAY_FS=y, but it cannot win on
# its own. Order of operations in kernel_config_initialize()
# (lib/functions/compilation/kernel-config.sh:63-85):
#
#   1. userpatches/config/kernel/linux-meson64-oldlts.config -> .config
#   2. call_extensions_kernel_config()
#        a. armbian_kernel_config__*  hooks  (Armbian core)
#        b. custom_kernel_config__*   hooks  (us, this function)
#        c. armbian_kernel_config_apply_opts_from_arrays()  <- applies EVERYTHING
#   3. make olddefconfig
#
# Both hook sets append to the SAME arrays, and step 2c applies them strictly in
# the order opts_n -> opts_y -> opts_m -> opts_val
# (armbian-kernel.sh:723-739). armbian_kernel_config__enable_docker_support()
# does opts_m+=("OVERLAY_FS") at armbian-kernel.sh:538, so:
#   - the =y in our .config is overwritten in step 2c, and
#   - opts_y+=("OVERLAY_FS") from here would still lose, because opts_m runs after.
# opts_val is applied last and maps to `./scripts/config --set-val OVERLAY_FS y`,
# which writes CONFIG_OVERLAY_FS=y verbatim; olddefconfig then keeps it.
#
# Opting out of armbian_kernel_config__enable_docker_support() wholesale is the
# other option and is worse - it also carries ~40 cgroup/netfilter/namespace
# options Docker genuinely needs.
#
# Why built-in at all: the A/B overlay is assembled by
# /etc/initramfs-tools/scripts/local-bottom/omni-overlay. With =m, a bootable
# root depends on overlay.ko having been packed into the initramfs by
# MODULES=list; with =y it does not. On a box that has no console unless someone
# drives to the site and opens the case, that difference is worth a few KB.
#
# The hook is called twice, once with no .config present; using the opts arrays
# (rather than calling kernel_config_set_* directly) handles both cases and gets
# the change into kernel_config_modifying_hashes for artifact versioning
# automatically (armbian-kernel.sh:705-720).
function custom_kernel_config__avast_omni_overlayfs_builtin() {
	opts_val["OVERLAY_FS"]="y"
}

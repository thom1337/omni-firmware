#!/bin/sh
# /usr/lib/omni/omni-uboot-env.sh -- shared helpers for touching the U-Boot
# environment on the Avast Omni.  SOURCE this file; it is not executable.
#
#   . /usr/lib/omni/omni-uboot-env.sh
#
# Why a library: the environment is ONE non-redundant 8 KB copy at offset 0 of
# /dev/mmcblk0boot0 (U-Boot patch 0036 removed CONFIG_ENV_OFFSET_REDUND).  There
# is no second copy, no canary and no in-band recovery -- a torn write needs the
# serial "=>" prompt and an `mmc write` from omni-boot0.img.  Every writer must
# therefore do the same three things, correctly, every time:
#
#   1. verify fw_printenv/fw_setenv exist and /etc/fw_env.config is sane
#   2. clear force_ro on the eMMC boot hardware partition before writing
#   3. restore force_ro on EVERY exit path, including signals
#
# All functions return non-zero on failure and print to stderr.  Nothing here
# ever writes on its own; the caller decides.

# Guard against double-sourcing.
[ "${_OMNI_UBOOT_ENV_SH:-}" = 1 ] && return 0
_OMNI_UBOOT_ENV_SH=1

OMNI_FW_ENV_CONFIG=${OMNI_FW_ENV_CONFIG:-/etc/fw_env.config}

omni_env_err() { printf 'omni-uboot-env: %s\n' "$*" >&2; }

omni_have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# omni_env_check_tools -- fw_printenv and fw_setenv must both exist.
# Debian provides them from either `libubootenv-tool` or `u-boot-tools`.
# ---------------------------------------------------------------------------
omni_env_check_tools() {
	_missing=
	omni_have fw_printenv || _missing="$_missing fw_printenv"
	omni_have fw_setenv   || _missing="$_missing fw_setenv"
	if [ -n "$_missing" ]; then
		omni_env_err "missing tool(s):$_missing"
		omni_env_err "install libubootenv-tool (preferred) or u-boot-tools"
		return 1
	fi
	return 0
}

# ---------------------------------------------------------------------------
# omni_env_device -- print the block device named on the first non-comment line
# of /etc/fw_env.config.  Everything else (which force_ro node to poke) is
# derived from this, so there is exactly one place that knows the layout.
# ---------------------------------------------------------------------------
omni_env_device() {
	[ -r "$OMNI_FW_ENV_CONFIG" ] || {
		omni_env_err "$OMNI_FW_ENV_CONFIG is missing or unreadable"
		return 1
	}
	_dev=$(sed -n 's/^[[:space:]]*\([^#[:space:]][^[:space:]]*\).*/\1/p' \
		"$OMNI_FW_ENV_CONFIG" 2>/dev/null | head -n 1)
	[ -n "$_dev" ] || {
		omni_env_err "$OMNI_FW_ENV_CONFIG has no usable device line"
		return 1
	}
	printf '%s\n' "$_dev"
}

# ---------------------------------------------------------------------------
# omni_env_check_config -- sanity-check the env location before writing.
# Warn (do not fail) on an unexpected layout: Phase 0 may legitimately find a
# different offset on a field unit, and refusing to commit would roll a
# perfectly good slot back.  Fail only if the device does not exist at all.
# ---------------------------------------------------------------------------
omni_env_check_config() {
	_dev=$(omni_env_device) || return 1
	if [ ! -e "$_dev" ]; then
		omni_env_err "env device '$_dev' from $OMNI_FW_ENV_CONFIG does not exist"
		return 1
	fi
	case "$_dev" in
	/dev/mmcblk*boot[01]) : ;;
	*)
		omni_env_err "WARNING: env device is '$_dev', not an eMMC boot hardware partition."
		omni_env_err "WARNING: expected /dev/mmcblk0boot0 per the Yocto fw_env.config."
		;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# force_ro handling.  eMMC boot partitions come up read-only; the kernel exposes
# /sys/block/<name>/force_ro.  Derived from the configured device so there is
# no hard-coded mmcblk0boot0 anywhere in the writers.
# ---------------------------------------------------------------------------
omni_env_force_ro_path() {
	_dev=$(omni_env_device) || return 1
	case "$_dev" in
	/dev/*) _base=${_dev#/dev/} ;;
	*)      return 1 ;;
	esac
	_p="/sys/block/$_base/force_ro"
	[ -e "$_p" ] || return 1
	printf '%s\n' "$_p"
}

# Remember the previous value so we can restore rather than blindly set 1.
_OMNI_FORCE_RO_SAVED=""
_OMNI_FORCE_RO_PATH=""

omni_env_unlock() {
	_OMNI_FORCE_RO_PATH=$(omni_env_force_ro_path 2>/dev/null) || _OMNI_FORCE_RO_PATH=""
	if [ -z "$_OMNI_FORCE_RO_PATH" ]; then
		# Not a boot hardware partition (e.g. env in a normal partition or a
		# file during a qemu dry-run): nothing to unlock.
		return 0
	fi
	_OMNI_FORCE_RO_SAVED=$(cat "$_OMNI_FORCE_RO_PATH" 2>/dev/null || echo 1)
	if ! printf '0\n' >"$_OMNI_FORCE_RO_PATH" 2>/dev/null; then
		omni_env_err "cannot clear $_OMNI_FORCE_RO_PATH (are we root?)"
		return 1
	fi
	return 0
}

omni_env_lock() {
	[ -n "$_OMNI_FORCE_RO_PATH" ] || return 0
	printf '%s\n' "${_OMNI_FORCE_RO_SAVED:-1}" >"$_OMNI_FORCE_RO_PATH" 2>/dev/null ||
		omni_env_err "WARNING: could not restore $_OMNI_FORCE_RO_PATH"
	_OMNI_FORCE_RO_PATH=""
	return 0
}

# Install this as your EXIT/INT/TERM trap after calling omni_env_unlock.
omni_env_cleanup() { omni_env_lock; }

# ---------------------------------------------------------------------------
# omni_env_get NAME -- print the value, empty if unset.  Never fails the caller
# just because a variable is absent (fw_printenv exits 1 for "not defined").
# ---------------------------------------------------------------------------
omni_env_get() {
	fw_printenv -n "$1" 2>/dev/null || printf ''
}

# ---------------------------------------------------------------------------
# omni_env_set NAME VALUE -- one variable, one write.
#
# Deliberately NOT using `fw_setenv -s <file>`: U-Boot 2018.09's own fw_setenv
# parses a script file as "key<space>value" while libubootenv parses "key=value",
# and which of the two Debian installed is not knowable at runtime.  The
# two-argument form is identical in both.  Callers that must minimise the armed
# window (the flasher) batch their writes; the commit path only writes two
# variables and orders them so that an interruption still leaves a safe state.
# ---------------------------------------------------------------------------
omni_env_set() {
	_n=$1 _v=$2
	if [ "${OMNI_DRY_RUN:-0}" = 1 ]; then
		printf 'omni-uboot-env: [dry-run] fw_setenv %s %s\n' "$_n" "$_v" >&2
		return 0
	fi
	fw_setenv "$_n" "$_v" || {
		omni_env_err "fw_setenv $_n $_v FAILED"
		return 1
	}
	return 0
}

# omni_env_assert NAME EXPECTED -- read back and compare.  Every write to a
# non-redundant environment gets verified.
omni_env_assert() {
	_n=$1 _want=$2
	if [ "${OMNI_DRY_RUN:-0}" = 1 ]; then
		printf 'omni-uboot-env: [dry-run] would assert %s == %s\n' "$_n" "$_want" >&2
		return 0
	fi
	_got=$(omni_env_get "$_n")
	if [ "$_got" != "$_want" ]; then
		omni_env_err "read-back MISMATCH: $_n is '$_got', expected '$_want'"
		return 1
	fi
	return 0
}

# ---------------------------------------------------------------------------
# omni_slot_root_part -- which rootfs partition are we actually running from?
#
# `findmnt -no SOURCE /` answers "overlay" once the overlay root is up, so the
# authoritative source is /run/omni/slot.env, written by the initramfs
# local-bottom script before switch_root.  Fall back to the LAST root= on
# /proc/cmdline (last occurrence wins, exactly as the kernel does it), because
# MENDER_BOOTARGS prepends root= to a bootargs that may already contain one.
# ---------------------------------------------------------------------------
omni_slot_root_part() {
	if [ -r /run/omni/slot.env ]; then
		_p=$(sed -n 's/^OMNI_ROOT_PART=//p' /run/omni/slot.env | tail -n 1)
		case "$_p" in
		''|*[!0-9]*) : ;;
		*) printf '%s\n' "$_p"; return 0 ;;
		esac
	fi
	[ -r /proc/cmdline ] || return 1
	_dev=""
	for _x in $(cat /proc/cmdline); do
		case "$_x" in
		root=*) _dev=${_x#root=} ;;
		esac
	done
	case "$_dev" in
	/dev/mmcblk[0-9]*p[0-9]*)
		_p=${_dev##*p}
		case "$_p" in
		''|*[!0-9]*) return 1 ;;
		*) printf '%s\n' "$_p"; return 0 ;;
		esac
		;;
	esac
	return 1
}

# omni_is_recovery_boot -- U-Boot's APOLLO_CHECK_RECOVERY prepends
# "init=/init hard_recovery" or "init=/init factory_reset" when it diverts to p7
# (reset button, latched watchdog register, or force_hard_recovery=1).  A slot
# must never be committed from a recovery boot.
omni_is_recovery_boot() {
	[ -r /run/omni/slot.env ] &&
		grep -qx 'OMNI_RECOVERY=1' /run/omni/slot.env 2>/dev/null && return 0
	[ -r /proc/cmdline ] || return 1
	for _x in $(cat /proc/cmdline); do
		case "$_x" in
		hard_recovery|factory_reset) return 0 ;;
		esac
	done
	return 1
}

#!/bin/sh
#
# omni-rollback.sh - deliberately roll back to the other A/B slot on the
# Avast Omni.
#
# Runs ON the device.  This is the manual equivalent of what U-Boot's
# mender_altbootcmd does when bootlimit is exceeded: flip mender_boot_part
# (and _hex), clear bootcount, clear upgrade_available - then reboot.
#
# POSIX sh, not bash: the stock image has no bash and /bin/sh is zsh.  The full
# rationale and the list of banned constructs live in omni-lib.sh's header.
#
# pipefail is not POSIX and dash does not have it; enable it only where the
# shell has it.  Nothing here relies on it (this script runs no pipelines).
set -eu
if ( set -o pipefail ) 2>/dev/null; then set -o pipefail; fi

OMNI_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=omni-lib.sh
. "${OMNI_LIB:-$OMNI_DIR/omni-lib.sh}"

PROG=omni-rollback.sh

usage() {
    cat <<'EOF'
omni-rollback.sh - deliberate rollback to the other A/B slot

USAGE
  omni-rollback.sh [--to N] [options]

  With no --to, flips to the slot mender_boot_part does NOT currently point at.

WHAT IT WRITES  (one batched fw_setenv -s, then read back and asserted)
  mender_boot_part      = <other slot>
  mender_boot_part_hex  = <other slot in hex>
  bootcount             = 0
  upgrade_available     = 0

  This mirrors mender_altbootcmd exactly (see U-Boot patch 0029), including
  upgrade_available=0.

  The four values go out as ONE `fw_setenv -s FILE` batch, so there is a single
  rewrite of the single, non-redundant 8 KB environment - and it is read back
  and asserted afterwards.  Batching is only about OUR write: with
  upgrade_available=0 the target boots unarmed, so U-Boot will not be
  rewriting the environment behind you on the way in.

READ THIS BEFORE YOU RUN IT
  upgrade_available=0 means the target slot boots WITHOUT bootcount protection.
  If it does not come up, nothing will roll you back automatically - you are
  down to the serial "=>" prompt or the reset button.  That is the correct
  semantic for a rollback (the slot you are going back to is the known-good
  one), but it is only true if the target really is known-good.

  If instead you want a protected trial of the other slot, use:
      omni-arm.sh --slot N        (upgrade_available=1, bootcount armed)

OPTIONS
  --to N            roll back to slot N (1 or 2) instead of "the other one".
                    Must differ from the active slot.
  --no-reboot       do everything except the reboot.  The env is already
                    written when this returns - the very next boot, whenever
                    it happens, goes to the target slot.
  --no-check-boot   skip the check that the target slot contains
                    /boot/<mender_kernel_name>, <mender_dtb_name> and
                    <mender_ramdisk_name>.
  --no-fs-check     skip the ext4 superblock sanity check on the target.
  --dry-run         print every decision and the exact env batch, write nothing.
  --log FILE        append all output to FILE as well.
  -h, --help        this text.

PRECONDITIONS (all enforced before any write)
  * running as root
  * fw_printenv / fw_setenv present, /etc/fw_env.config sane
  * mender_boot_part is 1 or 2
  * the target block device exists and is not mounted, nor is its overlay upper
  * the target is not the running root
  * the target carries an ext4 superblock and the three /boot artefacts

EXIT STATUS
  0 rolled back (rebooting, or --no-reboot), or dry run     1 refused / failed
EOF
}

TARGET=""
DO_REBOOT=1
CHECK_BOOT=1
FS_CHECK=1

while [ $# -gt 0 ]; do
    case "$1" in
        --to)            [ $# -ge 2 ] || die "--to needs a value"; TARGET="$2"; shift 2 ;;
        --to=*)          TARGET="${1#*=}"; shift ;;
        --no-reboot)     DO_REBOOT=0; shift ;;
        --no-check-boot) CHECK_BOOT=0; shift ;;
        --no-fs-check)   FS_CHECK=0; shift ;;
        --dry-run)       DRY_RUN=1; shift ;;
        --log)           [ $# -ge 2 ] || die "--log needs a value"; log_open "$2"; shift 2 ;;
        --log=*)         log_open "${1#*=}"; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) err "unknown argument: $1"; usage >&2; exit 1 ;;
    esac
done

trap 'omni_rundir_cleanup' EXIT

banner "$PROG"
[ "$DRY_RUN" = "1" ] && log "DRY RUN - nothing will be written"

need_root
env_need_tools
env_assert_config_sane

ACTIVE=$(active_slot)
log "active slot (stored mender_boot_part): p$ACTIVE"
log "running slot (/proc/cmdline root=):    $(describe_running_slot)"

if [ -z "$TARGET" ]; then
    TARGET=$(other_slot "$ACTIVE") || die "cannot derive the other slot from mender_boot_part=$ACTIVE"
fi
is_valid_slot "$TARGET" || die "target slot must be $OMNI_SLOT_A or $OMNI_SLOT_B, got '$TARGET'"
[ "$TARGET" != "$ACTIVE" ] || die "target p$TARGET is already the active slot - nothing to roll back to"

TGT_DEV=$(slot_dev "$TARGET")
OVL_DEV=$(overlay_dev "$TARGET")
log "rolling back to:  p$TARGET  ($TGT_DEV)"
log "target overlay:   p$(overlay_part "$TARGET")  ($OVL_DEV)"
log "NOTE: p$(overlay_part "$TARGET") is that slot's OWN overlay upper.  Anything you changed"
log "      under /etc or /var since p$TARGET last ran reverts to ITS stale state."

need_blockdev "$TGT_DEV" "target slot p$TARGET"

RUNNING=""
RUNNING=$(running_slot 2>/dev/null) || RUNNING=""
if [ -n "$RUNNING" ] && [ "$RUNNING" = "$TARGET" ]; then
    die "target p$TARGET is the RUNNING root filesystem - a rollback to yourself is not a rollback"
fi
if [ -n "$RUNNING" ] && [ "$RUNNING" = "$OMNI_RECOVERY_PART" ]; then
    warn "running from RECOVERY p$OMNI_RECOVERY_PART - the rollback pointer will be set, but check"
    warn "  force_hard_recovery / force_run_mfc / the watchdog register first, or the"
    warn "  next boot lands in recovery again instead of p$TARGET."
fi

assert_not_mounted "$TGT_DEV" "target slot p$TARGET"
if [ -b "$OVL_DEV" ]; then
    assert_not_mounted "$OVL_DEV" "target overlay p$(overlay_part "$TARGET")"
else
    warn "overlay upper $OVL_DEV does not exist as a block device"
fi

if [ "$FS_CHECK" = "1" ]; then
    assert_looks_like_ext4 "$TGT_DEV" "target slot p$TARGET"
else
    warn "--no-fs-check: skipping the ext4 superblock check on $TGT_DEV"
fi

if [ "$CHECK_BOOT" = "1" ]; then
    log "verifying boot artefacts on the rollback target"
    if ! check_slot_boot_artifacts "$TARGET"; then
        err "the rollback target is missing at least one boot artefact."
        err "  Rolling back to a slot that cannot load is strictly worse than staying"
        err "  put: upgrade_available=0 means nothing will bring you back."
        err "  Override with --no-check-boot only if you have serial access."
        die "boot artefact check failed"
    fi
else
    warn "--no-check-boot: NOT verifying /boot artefacts on p$TARGET"
fi

warn_recovery_diversion
warn_watchdog_diversion

log "current env state before the write:"
env_show_ab_state

TARGET_HEX=$(slot_hex "$TARGET")

env_batch_write \
    mender_boot_part     "$TARGET" \
    mender_boot_part_hex "$TARGET_HEX" \
    bootcount            "0" \
    upgrade_available    "0"

if [ "$DRY_RUN" = "1" ]; then
    log_dry "dry run complete - the stored environment is untouched"
    exit 0
fi

FINAL_PART=$(env_get_required mender_boot_part)
FINAL_HEX=$(env_get_required mender_boot_part_hex)
FINAL_BC=$(env_get_or bootcount '<undefined>')
FINAL_UA=$(env_get_or upgrade_available '<undefined>')
[ "$FINAL_PART" = "$TARGET" ]     || die "post-write mender_boot_part=$FINAL_PART, expected $TARGET"
[ "$FINAL_HEX"  = "$TARGET_HEX" ] || die "post-write mender_boot_part_hex=$FINAL_HEX, expected $TARGET_HEX"
[ "$FINAL_BC"   = "0" ]           || die "post-write bootcount=$FINAL_BC, expected 0"
[ "$FINAL_UA"   = "0" ]           || die "post-write upgrade_available=$FINAL_UA, expected 0"

ok "boot pointer moved to p$TARGET (unprotected: upgrade_available=0)"

if [ "$DO_REBOOT" = "1" ]; then
    reboot_now "rebooting into p$TARGET"
else
    warn "--no-reboot: the environment is ALREADY written."
    warn "  The next boot - planned or not - goes to p$TARGET."
fi

exit 0

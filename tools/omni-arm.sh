#!/bin/bash
#
# omni-arm.sh - arm an A/B rootfs slot on the Avast Omni.
#
# Runs ON the device.  Performs the Mender "install" half of the bootloader
# contract: point mender_boot_part at a slot, reset bootcount, and set
# upgrade_available=1 so U-Boot's bootcount/bootlimit machinery is live for
# the next boot.  One batched, verified environment write.
#
set -euo pipefail

OMNI_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=omni-lib.sh
. "${OMNI_LIB:-$OMNI_DIR/omni-lib.sh}"

PROG=omni-arm.sh

usage() {
    cat <<'EOF'
omni-arm.sh - arm an A/B rootfs slot (Mender "install" env write)

USAGE
  omni-arm.sh [--slot N | --same-slot] [options]

  With no slot selector, arms the INACTIVE slot (the one mender_boot_part does
  not currently point at).

WHAT IT WRITES  (one batched fw_setenv -s, then read back and asserted)
  mender_boot_part      = <target>
  mender_boot_part_hex  = <target in hex>
  bootcount             = 0
  upgrade_available     = 1

  Nothing else is touched.  In particular mender_kernel_name / mender_dtb_name /
  mender_ramdisk_name are GLOBAL, not per-slot, and are never rewritten.

OPTIONS
  --slot N            arm slot N (1 or 2).  Must differ from the active slot
                      unless --same-slot is also given.
  --same-slot         arm the CURRENTLY ACTIVE slot: mender_boot_part is
                      rewritten to the value it already has, bootcount is
                      cleared and upgrade_available is set to 1.  This is the
                      Phase 1 drill - it proves bootcount persistence, bootlimit
                      and altbootcmd WITHOUT moving the boot pointer, so the
                      only thing that changes on a failure is which slot the
                      rollback lands on.
  --reboot            reboot immediately after a successful, verified write.
                      (Default: do not reboot; print next steps.)
  --no-check-boot     skip the pre-arm check that the target slot actually
                      contains /boot/<mender_kernel_name>, <mender_dtb_name>
                      and <mender_ramdisk_name>.  Required for the Phase 1 T9
                      drill, which deliberately truncates /boot/Image on the
                      inactive slot to prove that a failed load drops to the
                      "=>" prompt instead of hanging.
  --no-fs-check       skip the ext4 superblock sanity check on the target.
  --dry-run           print every decision and the exact env batch, write nothing.
  --log FILE          append all output to FILE as well.
  -h, --help          this text.

PRECONDITIONS (all enforced; any failure aborts before any write)
  * running as root
  * fw_printenv / fw_setenv present, /etc/fw_env.config sane
  * mender_boot_part is 1 or 2 (7 = recovery aborts loudly)
  * the target block device exists, is not mounted, and its overlay upper
    (p<target+4>) is not mounted either
  * the target is not the running root, unless --same-slot
  * the target carries an ext4 superblock         (unless --no-fs-check)
  * the target's /boot holds the three artefacts  (unless --no-check-boot)

AFTER ARMING
  Reboot promptly, then run omni-commit.sh on the new slot.  While
  upgrade_available=1 the box is in the armed window:

    U-Boot rewrites the ENTIRE single, non-redundant 8 KB environment on every
    armed boot (CONFIG_BOOTCOUNT_ENV=y persists bootcount), and mender_altbootcmd
    saveenv's again when bootlimit is exceeded.  Batching our write does not and
    cannot make those atomic.  Keep the window short.  Do not power-cycle while
    armed.

EXIT STATUS
  0 armed and verified (or dry run)    1 refused / failed
EOF
}

TARGET=""
SAME_SLOT=0
DO_REBOOT=0
CHECK_BOOT=1
FS_CHECK=1

while [ $# -gt 0 ]; do
    case "$1" in
        --slot)          [ $# -ge 2 ] || die "--slot needs a value"; TARGET="$2"; shift 2 ;;
        --slot=*)        TARGET="${1#*=}"; shift ;;
        --same-slot)     SAME_SLOT=1; shift ;;
        --reboot)        DO_REBOOT=1; shift ;;
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

if [ "$SAME_SLOT" = "1" ]; then
    if [ -n "$TARGET" ] && [ "$TARGET" != "$ACTIVE" ]; then
        die "--same-slot conflicts with --slot $TARGET (active slot is p$ACTIVE)"
    fi
    TARGET="$ACTIVE"
elif [ -z "$TARGET" ]; then
    TARGET=$(other_slot "$ACTIVE") || die "cannot derive the inactive slot from mender_boot_part=$ACTIVE"
fi

is_valid_slot "$TARGET" || die "target slot must be $OMNI_SLOT_A or $OMNI_SLOT_B, got '$TARGET'"

if [ "$TARGET" = "$ACTIVE" ] && [ "$SAME_SLOT" != "1" ]; then
    die "target p$TARGET is already the active slot. Use --same-slot for the Phase 1 drill if that is what you meant."
fi

TGT_DEV=$(slot_dev "$TARGET")
OVL_DEV=$(overlay_dev "$TARGET")
log "target slot:      p$TARGET  ($TGT_DEV)"
log "target overlay:   p$(overlay_part "$TARGET")  ($OVL_DEV)"

# --- preconditions ---------------------------------------------------------
need_blockdev "$TGT_DEV" "target slot p$TARGET"
[ -b "$OVL_DEV" ] || warn "overlay upper $OVL_DEV does not exist as a block device"

RUNNING=""
if RUNNING=$(running_slot 2>/dev/null); then
    if [ "$RUNNING" = "$OMNI_RECOVERY_PART" ]; then
        warn "you are running from the RECOVERY partition p$OMNI_RECOVERY_PART."
        warn "  Arming A/B from recovery is allowed, but the next boot only reaches"
        warn "  the armed slot if nothing diverts to recovery again (reset button,"
        warn "  latched watchdog register, force_run_mfc, force_hard_recovery)."
    fi
else
    warn "could not determine the running slot from /proc/cmdline"
fi

if [ "$SAME_SLOT" = "1" ]; then
    if [ -n "$RUNNING" ] && [ "$RUNNING" != "$TARGET" ]; then
        die "--same-slot targets p$TARGET but this system booted from p$RUNNING; refusing (the stored pointer and the running slot disagree)"
    fi
    log "--same-slot: the boot pointer will NOT move; only bootcount and upgrade_available change"
else
    if [ -n "$RUNNING" ] && [ "$RUNNING" = "$TARGET" ]; then
        die "target p$TARGET is the RUNNING root filesystem; refusing to arm it as an update target"
    fi
    assert_not_mounted "$TGT_DEV" "target slot p$TARGET"
    if [ -b "$OVL_DEV" ]; then
        assert_not_mounted "$OVL_DEV" "target overlay p$(overlay_part "$TARGET")"
    fi
fi

if [ "$FS_CHECK" = "1" ]; then
    assert_looks_like_ext4 "$TGT_DEV" "target slot p$TARGET"
else
    warn "--no-fs-check: skipping the ext4 superblock check on $TGT_DEV"
fi

if [ "$CHECK_BOOT" = "1" ]; then
    log "verifying boot artefacts on the target slot"
    if ! check_slot_boot_artifacts "$TARGET"; then
        err "the target slot does not carry all three boot artefacts."
        err "U-Boot loads /boot/<mender_kernel_name>, /boot/<mender_dtb_name> and"
        err "/boot/<mender_ramdisk_name> from INSIDE the selected rootfs.  Arming a"
        err "slot that is missing one of them means a failed load."
        err "(A failed load does drop to the '=>' prompt, which is the Phase 1 T9"
        err " drill - if that is deliberate, re-run with --no-check-boot.)"
        die "boot artefact check failed"
    fi
else
    warn "--no-check-boot: NOT verifying /boot artefacts on p$TARGET"
fi

# --- advisory warnings that change what "armed" means ----------------------
warn_recovery_diversion
warn_watchdog_diversion

BOOTLIMIT=$(env_get_or bootlimit '<undefined>')
if [ "$BOOTLIMIT" = "<undefined>" ]; then
    warn "bootlimit is not defined in the STORED env (compiled default is 1)."
    warn "  U-Boot falls back to the compiled value, so rollback should still fire,"
    warn "  but this is exactly the open question Phase 1 exists to close."
else
    log "bootlimit = $BOOTLIMIT"
fi
if ! env_defined altbootcmd; then
    warn "altbootcmd is NOT defined in the stored env."
    warn "  MENDER_DEFAULT_ALTBOOTCMD compiles it in, and U-Boot uses the compiled"
    warn "  default when the stored env lacks it, but confirm on serial that the"
    warn "  bootlimit path prints 'Warning: Bootlimit (1) exceeded. Using altbootcmd.'"
fi

log "current env state before the write:"
env_show_ab_state

# --- the write -------------------------------------------------------------
TARGET_HEX=$(slot_hex "$TARGET")

env_batch_write \
    mender_boot_part     "$TARGET" \
    mender_boot_part_hex "$TARGET_HEX" \
    bootcount            "0" \
    upgrade_available    "1"

if [ "$DRY_RUN" = "1" ]; then
    log_dry "dry run complete - the stored environment is untouched"
    exit 0
fi

# Independent re-read: prove the four values coexist in the env we just wrote,
# not merely that each one round-tripped during the batch.
FINAL_PART=$(env_get_required mender_boot_part)
FINAL_HEX=$(env_get_required mender_boot_part_hex)
FINAL_BC=$(env_get_or bootcount '<undefined>')
FINAL_UA=$(env_get_or upgrade_available '<undefined>')
[ "$FINAL_PART" = "$TARGET" ]     || die "post-write mender_boot_part=$FINAL_PART, expected $TARGET"
[ "$FINAL_HEX"  = "$TARGET_HEX" ] || die "post-write mender_boot_part_hex=$FINAL_HEX, expected $TARGET_HEX"
[ "$FINAL_BC"   = "0" ]           || die "post-write bootcount=$FINAL_BC, expected 0"
[ "$FINAL_UA"   = "1" ]           || die "post-write upgrade_available=$FINAL_UA, expected 1"

ok "slot p$TARGET is ARMED (bootcount=0, upgrade_available=1)"
warn_armed_window

cat >&2 <<EOF

Next steps
  1. reboot
  2. on the way up, watch ttyAML0 - the armed boot rewrites the env to persist
     bootcount, so you should see bootcount become 1
  3. once the box is up and healthy:   omni-commit.sh
     (or, if it is not healthy and you can still get a shell:  omni-rollback.sh)
  4. if it never comes back: the bootlimit is $BOOTLIMIT, so the SECOND
     uncommitted boot prints "Warning: Bootlimit (1) exceeded. Using altbootcmd."
     and mender_altbootcmd flips the pointer for you.  Something must actually
     reboot the box for that to happen - CONFIG_PANIC_TIMEOUT=15 on the current
     5.4 kernel does it after a panic; a hang does not.
EOF

if [ "$DO_REBOOT" = "1" ]; then
    reboot_now "rebooting into the armed slot p$TARGET"
fi

exit 0

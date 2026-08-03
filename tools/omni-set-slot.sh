#!/bin/sh
# omni-set-slot.sh - set the A/B boot pointer directly, for the states the
# normal tools correctly refuse to handle.
#
# WHY THIS EXISTS
# ---------------
# Phase 1 on real hardware (2026-08-02, docs/HARDWARE-MEASURED.md) ended in a
# state neither omni-arm.sh nor omni-rollback.sh would touch, and both were
# right to refuse:
#
#   * the stored mender_boot_part said p2,
#   * but p2 was unbootable, so the box had been brought up by hand from the
#     "=>" prompt onto p1,
#   * so the RUNNING root was p1 while the POINTER said p2.
#
# omni-arm.sh: "target p1 is the RUNNING root filesystem; refusing to arm it as
# an update target."  omni-rollback.sh: "a rollback to yourself is not a
# rollback."  Both guards are correct for normal operation. But the one thing
# that situation needs is simply to put the pointer back, and nothing offered
# it. The recovery was composed by hand out of the library:
#
#     sh -c '. omni-lib.sh; env_batch_write mender_boot_part 1 \
#            mender_boot_part_hex 1 bootcount 0 upgrade_available 0'
#
# which is exactly right and exactly the wrong thing to be improvising at the
# point where you need it. This is that, as a reviewed tool.
#
# It goes through the same audited path as everything else: validate all pairs
# BEFORE opening the write window, force_ro unlock, ONE batched fw_setenv,
# re-lock unconditionally, then read back and assert every value.
#
# IT DELIBERATELY DOES NOT CHECK whether the target is the running slot. That
# is the whole point -- every other tool does, and that is what leaves this hole.
# In exchange it refuses to guess: --slot is mandatory, and it prints exactly
# what it is about to do.
set -eu

OMNI_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=omni-lib.sh
. "${OMNI_LIB:-$OMNI_DIR/omni-lib.sh}"

PROG=omni-set-slot.sh
TARGET=""
CLEAR_COUNT=1
DISARM=1
DO_REBOOT=0

usage() {
    cat <<'EOF'
omni-set-slot.sh - set the A/B boot pointer directly (recovery tool)

USAGE
  omni-set-slot.sh --slot N [options]

  Writes, in one batched environment write:
      mender_boot_part      = N
      mender_boot_part_hex  = N
      bootcount             = 0    (unless --keep-bootcount)
      upgrade_available     = 0    (unless --keep-armed)

WHEN TO USE IT
  When the pointer and reality have diverged and the normal tools refuse:
  typically after a rollback landed on an unbootable slot and you booted the
  good one by hand from the "=>" prompt. omni-arm.sh will not arm the running
  root; omni-rollback.sh will not roll back to itself. Both are right. This
  puts the pointer where you say.

  For normal operation use omni-arm.sh / omni-commit.sh / omni-rollback.sh.
  They have guards this one deliberately lacks.

OPTIONS
  --slot N            REQUIRED. 1 or 2. No default, no inference.
  --keep-bootcount    do not reset bootcount to 0
  --keep-armed        do not clear upgrade_available (leaves the slot ARMED --
                      the next boot counts against bootlimit)
  --reboot            reboot after a verified write
  --dry-run           print the batch and change nothing
  --log FILE          append output to FILE as well
  -h, --help          this text

EXIT
  0 written and verified   1 refused or failed
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --slot)            [ $# -ge 2 ] || die "--slot needs a value"; TARGET="$2"; shift 2 ;;
        --slot=*)          TARGET="${1#*=}"; shift ;;
        --keep-bootcount)  CLEAR_COUNT=0; shift ;;
        --keep-armed)      DISARM=0; shift ;;
        --reboot)          DO_REBOOT=1; shift ;;
        --dry-run)         DRY_RUN=1; shift ;;
        --log)             [ $# -ge 2 ] || die "--log needs a value"; log_open "$2"; shift 2 ;;
        --log=*)           log_open "${1#*=}"; shift ;;
        -h|--help)         usage; exit 0 ;;
        *) err "unknown argument: $1"; usage >&2; exit 1 ;;
    esac
done

banner "$PROG"
[ "$DRY_RUN" = "1" ] && log "DRY RUN - nothing will be written"

need_root
env_need_tools
env_assert_config_sane

[ -n "$TARGET" ] || { usage >&2; die "--slot is required (this tool never guesses)"; }
is_valid_slot "$TARGET" || die "--slot must be $OMNI_SLOT_A or $OMNI_SLOT_B, got '$TARGET'"

ACTIVE=$(active_slot 2>/dev/null || printf '?')
RUNNING=$(running_slot 2>/dev/null || printf '?')
TGT_DEV=$(slot_dev "$TARGET")

log "stored mender_boot_part : p$ACTIVE"
log "running root            : $(describe_running_slot)"
log "setting pointer to      : p$TARGET  ($TGT_DEV)"

if [ "$ACTIVE" = "$TARGET" ]; then
    log "note: the pointer already reads p$TARGET; rewriting it anyway (harmless, and"
    log "      it still clears bootcount/upgrade_available unless you asked otherwise)"
fi

# The one sanity check worth keeping: refuse to point at a slot with no kernel.
# This is advisory precisely because the tool exists for broken states -- pass
# --keep-armed/--dry-run and read the warning if you mean to do it anyway.
if check_slot_boot_artifacts "$TARGET" >/dev/null 2>&1; then
    ok "p$TARGET has the three boot artefacts U-Boot will look for"
else
    warn "p$TARGET does NOT appear to have all three boot artefacts."
    warn "  U-Boot will fail the load and drop to the '=>' prompt -- which IS"
    warn "  recoverable (measured, Phase 1), but it will not boot unattended."
fi

warn_recovery_diversion
warn_watchdog_diversion

set -- mender_boot_part "$TARGET" mender_boot_part_hex "$(slot_hex "$TARGET")"
[ "$CLEAR_COUNT" = "1" ] && set -- "$@" bootcount 0
[ "$DISARM" = "1" ]      && set -- "$@" upgrade_available 0

env_batch_write "$@"

if [ "$DRY_RUN" = "1" ]; then
    log_dry "dry run complete - the stored environment is untouched"
    exit 0
fi

ok "boot pointer is now p$TARGET"
[ "$DISARM" = "1" ] || warn_armed_window

if [ "$DO_REBOOT" = "1" ]; then
    reboot_now "rebooting into p$TARGET"
else
    log "not rebooting (pass --reboot to do that). Verify first:"
    log "    fw_printenv mender_boot_part bootcount upgrade_available"
fi
exit 0

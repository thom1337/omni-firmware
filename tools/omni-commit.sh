#!/bin/sh
#
# omni-commit.sh - mark the RUNNING slot good on the Avast Omni.
#
# Runs ON the device.  Performs the Mender "commit" half of the bootloader
# contract: upgrade_available=0 and bootcount=0, in one batched, verified
# environment write.  This closes the armed window: from here on a reboot no
# longer counts against bootlimit and mender_altbootcmd will not flip the slot.
#
# POSIX sh, not bash: the stock Yocto image has no bash at all and /bin/sh is
# zsh, so a #!/bin/bash script does not start and bash's pipeline-status array
# does not exist.  See the header of omni-lib.sh for the full rationale and the
# banned-construct list; it is not repeated here.
#
set -eu
# pipefail is NOT POSIX and dash does not have it: probe, never assume.  Nothing
# in this script pipes, and no safety decision here rests on it.
if ( set -o pipefail ) 2>/dev/null; then set -o pipefail; fi

OMNI_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=omni-lib.sh
. "${OMNI_LIB:-$OMNI_DIR/omni-lib.sh}"

PROG=omni-commit.sh

usage() {
    cat <<'EOF'
omni-commit.sh - mark the running slot good (Mender "commit" env write)

USAGE
  omni-commit.sh [options]

WHAT IT WRITES  (one batched fw_setenv -s, then read back and asserted)
  upgrade_available = 0
  bootcount         = 0

  mender_boot_part is NOT written: committing means "the slot the bootloader
  already points at, and which I am demonstrably running from, is good".

  Both values go out as ONE `fw_setenv -s FILE` batch - a single rewrite of the
  single, non-redundant 8 KB environment - and are read back and asserted.
  Run this as soon as the box is up: until it succeeds, CONFIG_BOOTCOUNT_ENV=y
  has U-Boot rewriting that same 8 KB on every boot to persist bootcount, and
  batching our write does nothing about that.

THE SAFETY CHECK THAT MATTERS
  Committing the wrong slot is how you disarm a rollback that was about to save
  you.  So before writing anything this script:

    1. parses /proc/cmdline for root= (LAST occurrence wins - the same rule
       U-Boot's MENDER_BOOTARGS depends on, which is why pre-flight check P2
       forbids a stored 'bootargs')
    2. resolves it to a partition number
    3. requires that number to equal the stored mender_boot_part

  If they disagree - or if root= cannot be parsed, or you booted p7 recovery -
  it refuses.  A genuine mismatch is NEVER overridable: it means the running
  rootfs is not the one the bootloader will select next, and committing would
  bless a slot you are not testing.

OPTIONS
  --expect-slot N   additionally require the running slot to be N (belt and
                    braces for scripted upgrades: pass the slot you flashed).
  --force           permit committing when root= cannot be parsed at all, PROVIDED
                    --expect-slot N is given and N equals the stored
                    mender_boot_part.  Does not override a real mismatch.
  --dry-run         print every decision and the exact env batch, write nothing.
  --log FILE        append all output to FILE as well.
  -h, --help        this text.

IDEMPOTENCY
  If upgrade_available is already 0 and bootcount is already 0, no environment
  write is performed at all and the script exits 0.  Re-running it is free -
  and every avoided write is one fewer torn-write exposure on a single,
  non-redundant 8 KB environment.

EXIT STATUS
  0 committed, already committed, or dry run     1 refused / failed
EOF
}

EXPECT_SLOT=""
FORCE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --expect-slot)   [ $# -ge 2 ] || die "--expect-slot needs a value"; EXPECT_SLOT="$2"; shift 2 ;;
        --expect-slot=*) EXPECT_SLOT="${1#*=}"; shift ;;
        --force)         FORCE=1; shift ;;
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
CMDLINE_ROOT=$(running_root_dev 2>/dev/null || printf '')
log "stored mender_boot_part: p$ACTIVE"
log "/proc/cmdline root=:     ${CMDLINE_ROOT:-<not present>}"

RUNNING=""
if RUNNING=$(running_slot 2>/dev/null); then
    log "running slot:            p$RUNNING"
else
    RUNNING=""
fi

# --- refuse to commit a slot we are not demonstrably running from ----------
if [ -z "$RUNNING" ]; then
    err "cannot determine the running slot from /proc/cmdline."
    err "  root= resolved to: '${CMDLINE_ROOT:-<none>}'"
    if [ "$FORCE" = "1" ] && [ -n "$EXPECT_SLOT" ]; then
        is_valid_slot "$EXPECT_SLOT" || die "--expect-slot must be $OMNI_SLOT_A or $OMNI_SLOT_B"
        [ "$EXPECT_SLOT" = "$ACTIVE" ] || die "--force requires --expect-slot to equal the stored mender_boot_part (p$ACTIVE)"
        warn "--force with --expect-slot p$EXPECT_SLOT: proceeding on the operator's word"
        RUNNING="$EXPECT_SLOT"
    else
        err "  re-run with:  --force --expect-slot <N>   only if you are certain."
        die "refusing to commit a slot I cannot identify"
    fi
fi

if [ "$RUNNING" = "$OMNI_RECOVERY_PART" ]; then
    err "this system is running from the RECOVERY partition p$OMNI_RECOVERY_PART."
    err "  Nothing about the A/B slots has been demonstrated by reaching recovery."
    err "  Committing here would clear upgrade_available for slot p$ACTIVE without"
    err "  that slot ever having booted."
    die "refusing to commit from recovery"
fi

is_valid_slot "$RUNNING" || die "running root is p$RUNNING, which is not an A/B slot"

if [ "$RUNNING" != "$ACTIVE" ]; then
    err "MISMATCH: running from p$RUNNING but mender_boot_part=p$ACTIVE."
    err "  The bootloader will select p$ACTIVE next, not the filesystem you are"
    err "  currently testing.  Committing now would bless the wrong slot."
    err "  Likely causes:"
    err "    * a stale stored 'bootargs' with its own root= (pre-flight P2)"
    err "    * mender_altbootcmd flipped the pointer after this kernel was loaded"
    err "    * someone ran omni-arm.sh after this boot started"
    err "  Resolve it deliberately (omni-arm.sh / omni-rollback.sh), then reboot."
    die "refusing to commit a mismatched slot"
fi

if [ -n "$EXPECT_SLOT" ]; then
    is_valid_slot "$EXPECT_SLOT" || die "--expect-slot must be $OMNI_SLOT_A or $OMNI_SLOT_B"
    [ "$EXPECT_SLOT" = "$RUNNING" ] || die "--expect-slot p$EXPECT_SLOT but running from p$RUNNING"
    ok "--expect-slot p$EXPECT_SLOT matches"
fi

ok "verified: running from p$RUNNING and mender_boot_part=p$ACTIVE"

# The lower filesystem really is that block device (a sanity check against a
# hand-edited cmdline).  The running root is an overlay, so compare the mount
# source of /lower if present, else just report.
if [ -e "/proc/mounts" ]; then
    LOWER_SRC=$(awk '$2 == "/lower" { print $1; exit }' /proc/mounts 2>/dev/null || printf '')
    if [ -n "$LOWER_SRC" ]; then
        log "overlay lower is mounted from: $LOWER_SRC"
        if [ "$(readlink -f -- "$LOWER_SRC" 2>/dev/null || printf '%s' "$LOWER_SRC")" != "$(slot_dev "$RUNNING")" ]; then
            warn "  ... which is not $(slot_dev "$RUNNING") - investigate before trusting this commit"
        fi
    fi
fi

CUR_UA=$(env_get_or upgrade_available '<undefined>')
CUR_BC=$(env_get_or bootcount '<undefined>')
log "upgrade_available = $CUR_UA"
log "bootcount         = $CUR_BC"

if [ "$CUR_UA" = "0" ] && [ "$CUR_BC" = "0" ]; then
    ok "already committed (upgrade_available=0, bootcount=0) - no environment write needed"
    exit 0
fi

if [ "$CUR_UA" != "1" ] && [ "$CUR_UA" != "0" ]; then
    warn "upgrade_available='$CUR_UA' is neither 0 nor 1; normalising it to 0"
fi

env_batch_write \
    upgrade_available "0" \
    bootcount         "0"

if [ "$DRY_RUN" = "1" ]; then
    log_dry "dry run complete - the stored environment is untouched"
    exit 0
fi

FINAL_UA=$(env_get_or upgrade_available '<undefined>')
FINAL_BC=$(env_get_or bootcount '<undefined>')
FINAL_PART=$(env_get_required mender_boot_part)
[ "$FINAL_UA"   = "0" ]        || die "post-write upgrade_available=$FINAL_UA, expected 0"
[ "$FINAL_BC"   = "0" ]        || die "post-write bootcount=$FINAL_BC, expected 0"
[ "$FINAL_PART" = "$RUNNING" ] || die "post-write mender_boot_part=$FINAL_PART, expected $RUNNING (the env moved under us!)"

ok "slot p$RUNNING COMMITTED - armed window closed"
log "the bootloader will keep booting p$RUNNING until something changes it"
log "to go back deliberately:  omni-rollback.sh"

exit 0

#!/bin/sh
#
# omni-flash.sh - install a rootfs image into the inactive A/B slot of the
# Avast Omni, verify it, and arm it.
#
# POSIX sh, deliberately: the stock Yocto image has no bash at all and /bin/sh
# is a symlink to /bin/zsh, whose sh-emulation has no PIPESTATUS.  The rationale
# and the full list of banned constructs live at the top of omni-lib.sh; the
# ${PIPESTATUS[*]} truncation guard below is now pipe_status_reset/_mark/_string
# from that file.
#
# Runs ON the device.  This is the "Flashing and rollback" section of
# docs/ARMBIAN-MIGRATION.md, implemented properly:
#
#   quiesce (watchdog OFF, asserted) -> memory gate -> writeback tuning
#   -> mkfs.ext4 on the TARGET's overlay upper (before the rootfs, so stale
#      Avast files cannot resurrect over the new lower)
#   -> stream image -> dd conv=fsync
#   -> truncation-proof verification (exact byte count + sha256 of exactly
#      IMG_SIZE bytes read back from the device) + e2fsck -fn
#   -> omni-arm.sh  -> reboot
#
# INVARIANT: every failure path leaves the box bootable on the CURRENT slot.
# Nothing outside the target slot's rootfs partition and its own overlay upper
# is ever written, and the boot pointer moves only after every check passed.
#
set -eu
# pipefail is not POSIX and dash does not have it.  Keep it where the shell has
# it, carry on without it where it does not: the safety decisions below are made
# by pipe_status_* (which works everywhere), never by pipefail.
if ( set -o pipefail ) 2>/dev/null; then set -o pipefail; fi

OMNI_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=omni-lib.sh
. "${OMNI_LIB:-$OMNI_DIR/omni-lib.sh}"

PROG=omni-flash.sh

usage() {
    cat <<'EOF'
omni-flash.sh - install, verify and arm a rootfs image in the inactive A/B slot

USAGE
  omni-flash.sh --image <URL|FILE> --sha256 <HEX64> --size <BYTES> [options]

REQUIRED
  --image SRC     http(s)/ftp URL or a local file.  May be raw or compressed
                  (.gz/.xz/.zst - see --compression).
  --sha256 HEX    sha256 of the DECOMPRESSED image, i.e. of exactly the first
                  <size> bytes that land on the partition.
  --size BYTES    exact decompressed image size.  Accepts a K/M/G suffix.
                  This is what makes truncation detectable: a short transfer
                  cannot produce the right byte count AND the right digest.

OPTIONS
  --slot N            target slot (1 or 2).  Default: the inactive slot.
  --compression C     auto|none|gzip|xz|zstd   (default: auto, from the name)
  --stage MODE        auto|yes|no  (default auto).  "yes" downloads the image to
                      --stage-dir first, so a network that dies mid-transfer
                      cannot leave a half-written slot.  "auto" stages a URL
                      when the stage dir has room, and never stages a local file.
  --stage-dir DIR     default /data/omni-stage  (p3 is not A/B protected, which
                      is exactly why it is a good scratch area)
  --keep-stage        do not delete the staged download afterwards
  --min-mem-kb N      require this much MemAvailable before writing (default
                      250000).  /var/volatile/log alone is a 140 MB tmpfs on
                      this image, so this is a real gate on a 512 MB box.
  --keep-overlay      do NOT mkfs the target's overlay upper.  UNSAFE: the
                      overlay upper for p<N> is p<N+4> and it is per-slot, so
                      years-old Avast files in it reappear on top of the brand
                      new lower filesystem.
  --overlay-mkfs-opts "..."  replace the computed mke2fs feature flags
  --skip-fsck         skip e2fsck -fn on the written slot.  Only defensible
                      when the sha256 matched, because the image was fsck'd at
                      build time.  The stock Yocto image ships e2fsprogs-mke2fs
                      only - no e2fsck - which is why this escape hatch exists.
  --stop-service U    also stop unit U during the write (repeatable).  The
                      defaults are docker.socket, docker.service,
                      containerd.service and syslog-ng.service.  The Debian
                      image no longer ships Docker (see rootfs/packages.list),
                      but this script runs from whichever slot is CURRENTLY
                      booted -- during migration that is the Yocto slot, which
                      does have it -- so the units stay in the list.  Anything
                      not installed or not running is skipped, not an error.
  --no-arm            write and verify, then stop.  Does not touch the
                      environment at all.  Use this for a Phase 4 style trial
                      boot driven entirely from the "=>" prompt.
  --no-reboot         arm, but do not reboot.  The armed window stays open
                      until you reboot - keep it short.  `fw_setenv -s FILE`
                      collapses OUR four values into one 8 KB rewrite, but
                      CONFIG_BOOTCOUNT_ENV=y means U-Boot itself calls
                      env_save() on every armed boot, and mender_altbootcmd
                      saveenv's again - batching cannot make those atomic, and
                      there is no redundant copy of that 8 KB.
  --dry-run           print every decision and every command, change nothing.
  --log FILE          append all output to FILE as well.
  -h, --help          this text.

WHAT IT STOPS AND RESTORES
  A 400 MB write on a 512 MB box can starve PID 1 past its 10 s watchdog ping,
  and a watchdog reset on this platform goes to the p7 RECOVERY partition, NOT
  to the other slot (check_watchdog runs ahead of slot selection, and
  altbootcmd re-enters bootcmd, so bootcount rollback cannot escape it).

  So the script writes /run/systemd/system.conf.d/99-omni-flash.conf with
  RuntimeWatchdogSec=0, runs `systemctl daemon-reexec`, and ASSERTS that
  RuntimeWatchdogUSec really became 0 before touching anything.  It then stops
  docker.socket, docker.service, containerd.service and syslog-ng.service -
  only those that exist and are actually running, so on a Debian slot (which
  ships none of the container units) this reduces to syslog-ng or nothing -
  and tunes vm.dirty_bytes,
  vm.dirty_background_bytes and kernel.printk.

  An EXIT trap restores ALL of it: the sysctls (including the dirty_ratio
  values that writing dirty_bytes zeroes), the systemd drop-in plus a second
  daemon-reexec, and every service it stopped, in reverse order - containerd
  included.  On the reboot path it deliberately leaves the watchdog off and
  does not restart services, because the box is going down anyway.

ORDER OF DESTRUCTION (and why the box stays bootable at every point)
  1. every precondition and every tool is checked first
  2. mkfs.ext4 on p<target+4>   - target slot's own overlay, nothing else uses it
  3. dd onto p<target>          - the inactive slot
  4. verification
  5. omni-arm.sh                - the ONLY environment write, and the only step
                                  that changes which slot boots
  A failure anywhere in 1-4 leaves mender_boot_part untouched: the running slot
  still boots, with its own overlay upper intact.

EXIT STATUS
  0 written, verified, armed (or --no-arm / dry run)    1 refused / failed
EOF
}

# --- defaults --------------------------------------------------------------
IMAGE=""
IMG_SHA=""
IMG_SIZE=""
TARGET=""
COMPRESSION="auto"
STAGE_MODE="auto"
STAGE_DIR="/data/omni-stage"
KEEP_STAGE=0
MIN_MEM_KB=250000
DO_OVERLAY_MKFS=1
OVERLAY_MKFS_OPTS=""
OVERLAY_MKFS_OPTS_SET=0
SKIP_FSCK=0
DO_ARM=1
DO_REBOOT=1

# Kept deliberately even though the Debian image ships no container runtime: this
# script runs on the slot that is booted NOW, and for the whole migration that is
# the legacy Yocto slot, where docker/containerd are installed. Units that are
# absent or inactive are skipped.
DEFAULT_QUIESCE_UNITS="docker.socket docker.service containerd.service syslog-ng.service"
EXTRA_QUIESCE_UNITS=""

# --- argument parsing ------------------------------------------------------
parse_size() {
    # digits with an optional K/M/G (binary) suffix
    local s="$1" n suffix
    case "$s" in
        *[Kk]|*[Kk][Ii][Bb]) n="${s%%[KkIiBb]*}"; suffix=1024 ;;
        *[Mm]|*[Mm][Ii][Bb]) n="${s%%[MmIiBb]*}"; suffix=1048576 ;;
        *[Gg]|*[Gg][Ii][Bb]) n="${s%%[GgIiBb]*}"; suffix=1073741824 ;;
        *)                   n="$s";              suffix=1 ;;
    esac
    case "$n" in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s' "$(( n * suffix ))"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --image)         [ $# -ge 2 ] || die "--image needs a value"; IMAGE="$2"; shift 2 ;;
        --image=*)       IMAGE="${1#*=}"; shift ;;
        --sha256)        [ $# -ge 2 ] || die "--sha256 needs a value"; IMG_SHA="$2"; shift 2 ;;
        --sha256=*)      IMG_SHA="${1#*=}"; shift ;;
        --size)          [ $# -ge 2 ] || die "--size needs a value"; IMG_SIZE="$2"; shift 2 ;;
        --size=*)        IMG_SIZE="${1#*=}"; shift ;;
        --slot)          [ $# -ge 2 ] || die "--slot needs a value"; TARGET="$2"; shift 2 ;;
        --slot=*)        TARGET="${1#*=}"; shift ;;
        --compression)   [ $# -ge 2 ] || die "--compression needs a value"; COMPRESSION="$2"; shift 2 ;;
        --compression=*) COMPRESSION="${1#*=}"; shift ;;
        --stage)         [ $# -ge 2 ] || die "--stage needs a value"; STAGE_MODE="$2"; shift 2 ;;
        --stage=*)       STAGE_MODE="${1#*=}"; shift ;;
        --stage-dir)     [ $# -ge 2 ] || die "--stage-dir needs a value"; STAGE_DIR="$2"; shift 2 ;;
        --stage-dir=*)   STAGE_DIR="${1#*=}"; shift ;;
        --keep-stage)    KEEP_STAGE=1; shift ;;
        --min-mem-kb)    [ $# -ge 2 ] || die "--min-mem-kb needs a value"; MIN_MEM_KB="$2"; shift 2 ;;
        --min-mem-kb=*)  MIN_MEM_KB="${1#*=}"; shift ;;
        --keep-overlay)  DO_OVERLAY_MKFS=0; shift ;;
        --overlay-mkfs-opts)   [ $# -ge 2 ] || die "--overlay-mkfs-opts needs a value"
                               OVERLAY_MKFS_OPTS="$2"; OVERLAY_MKFS_OPTS_SET=1; shift 2 ;;
        --overlay-mkfs-opts=*) OVERLAY_MKFS_OPTS="${1#*=}"; OVERLAY_MKFS_OPTS_SET=1; shift ;;
        --skip-fsck)     SKIP_FSCK=1; shift ;;
        --stop-service)  [ $# -ge 2 ] || die "--stop-service needs a value"
                         EXTRA_QUIESCE_UNITS="$EXTRA_QUIESCE_UNITS $2"; shift 2 ;;
        --no-arm)        DO_ARM=0; shift ;;
        --no-reboot)     DO_REBOOT=0; shift ;;
        --dry-run)       DRY_RUN=1; shift ;;
        --log)           [ $# -ge 2 ] || die "--log needs a value"; log_open "$2"; shift 2 ;;
        --log=*)         log_open "${1#*=}"; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) err "unknown argument: $1"; usage >&2; exit 1 ;;
    esac
done

[ -n "$IMAGE" ]   || { usage >&2; die "--image is required"; }
[ -n "$IMG_SHA" ] || { usage >&2; die "--sha256 is required"; }
[ -n "$IMG_SIZE" ] || { usage >&2; die "--size is required"; }

IMG_SHA=$(printf '%s' "$IMG_SHA" | tr 'A-Z' 'a-z')
case "$IMG_SHA" in
    ????????????????????????????????????????????????????????????????) ;;
    *) die "--sha256 must be 64 hex characters, got ${#IMG_SHA}" ;;
esac
case "$IMG_SHA" in
    *[!0-9a-f]*) die "--sha256 contains non-hex characters" ;;
esac
IMG_SIZE=$(parse_size "$IMG_SIZE") || die "--size must be a byte count, optionally with a K/M/G suffix"
[ "$IMG_SIZE" -gt 0 ] || die "--size must be greater than zero"
case "$MIN_MEM_KB" in ''|*[!0-9]*) die "--min-mem-kb must be a number" ;; esac

# --- state for the cleanup trap -------------------------------------------
DROPIN_PATH=/run/systemd/system.conf.d/99-omni-flash.conf
DROPIN_MADE=0
STOPPED_UNITS=""
SYSCTL_SAVED=0
SAVED_DIRTY_BYTES=""
SAVED_DIRTY_BG_BYTES=""
SAVED_DIRTY_RATIO=""
SAVED_DIRTY_BG_RATIO=""
SAVED_PRINTK=""
STAGED_FILE=""
REBOOTING=0
CLEANED=0

read_sysfile() { [ -r "$1" ] && cat "$1" 2>/dev/null || printf ''; }
write_sysfile() {
    # write_sysfile <path> <value...>
    local p="$1"; shift
    if [ "$DRY_RUN" = "1" ]; then log_dry "would write '$*' to $p"; return 0; fi
    [ -w "$p" ] || { warn "cannot write $p"; return 1; }
    printf '%s\n' "$*" > "$p" 2>/dev/null || { warn "failed writing $p"; return 1; }
    return 0
}

restore_sysctls() {
    [ "$SYSCTL_SAVED" = "1" ] || return 0
    log "restoring writeback / printk sysctls"
    # Writing a *_ratio zeroes the corresponding *_bytes and vice versa, so
    # restore in the order that reproduces the original pair.
    if [ "${SAVED_DIRTY_BYTES:-0}" = "0" ]; then
        [ -n "$SAVED_DIRTY_RATIO" ]    && write_sysfile /proc/sys/vm/dirty_ratio "$SAVED_DIRTY_RATIO" || true
        [ -n "$SAVED_DIRTY_BG_RATIO" ] && write_sysfile /proc/sys/vm/dirty_background_ratio "$SAVED_DIRTY_BG_RATIO" || true
    else
        write_sysfile /proc/sys/vm/dirty_bytes "$SAVED_DIRTY_BYTES" || true
        [ -n "$SAVED_DIRTY_BG_BYTES" ] && write_sysfile /proc/sys/vm/dirty_background_bytes "$SAVED_DIRTY_BG_BYTES" || true
    fi
    [ -n "$SAVED_PRINTK" ] && write_sysfile /proc/sys/kernel/printk "$SAVED_PRINTK" || true
    SYSCTL_SAVED=0
}

restore_watchdog() {
    [ "$DROPIN_MADE" = "1" ] || return 0
    log "removing $DROPIN_PATH and re-exec'ing systemd (watchdog back to its unit default)"
    if [ "$DRY_RUN" = "1" ]; then
        log_dry "would run: rm -f $DROPIN_PATH; systemctl daemon-reexec"
    else
        rm -f "$DROPIN_PATH" 2>/dev/null || warn "could not remove $DROPIN_PATH"
        rmdir /run/systemd/system.conf.d 2>/dev/null || true
        systemctl daemon-reexec 2>/dev/null || warn "systemctl daemon-reexec failed - watchdog may still be disabled"
    fi
    DROPIN_MADE=0
}

restore_units() {
    [ -n "$STOPPED_UNITS" ] || return 0
    # Reverse order, so containerd comes back before docker.
    local u rev=""
    for u in $STOPPED_UNITS; do rev="$u $rev"; done
    log "restarting units that were stopped: $rev"
    for u in $rev; do
        if [ "$DRY_RUN" = "1" ]; then
            log_dry "would run: systemctl start $u"
        else
            systemctl start "$u" 2>/dev/null || warn "could not restart $u - start it by hand"
        fi
    done
    STOPPED_UNITS=""
}

cleanup() {
    local rc=$?
    [ "$CLEANED" = "1" ] && return $rc
    CLEANED=1
    set +e
    banner "cleanup"
    restore_sysctls
    if [ "$REBOOTING" = "1" ]; then
        log "reboot in progress: leaving the watchdog disabled and services stopped"
    else
        restore_watchdog
        restore_units
    fi
    if [ -n "$STAGED_FILE" ] && [ "$KEEP_STAGE" != "1" ]; then
        log "removing staged download $STAGED_FILE"
        rm -f -- "$STAGED_FILE" "$STAGED_FILE.part" 2>/dev/null || true
    fi
    omni_rundir_cleanup
    if [ "$rc" -ne 0 ]; then
        err "omni-flash.sh FAILED (exit $rc)"
        err "The boot pointer was NOT moved by this run unless omni-arm.sh reported"
        err "success above.  Confirm with:  fw_printenv mender_boot_part upgrade_available bootcount"
        err "The running slot is still bootable."
    fi
    return $rc
}
trap cleanup EXIT
trap 'err "interrupted"; exit 130' INT TERM

# ===========================================================================
banner "$PROG"
[ "$DRY_RUN" = "1" ] && log "DRY RUN - nothing will be written"

need_root
env_need_tools
env_assert_config_sane
need_cmd dd
need_dd_features
need_cmd sha256sum
need_cmd od
need_cmd awk
need_cmd blockdev "util-linux"
[ -x "$OMNI_DIR/omni-arm.sh" ] || die "omni-arm.sh not found next to $0 ($OMNI_DIR/omni-arm.sh)"

if [ "$SKIP_FSCK" = "0" ]; then
    need_cmd e2fsck "the stock Yocto image ships e2fsprogs-mke2fs only; build and dpkg -i e2fsprogs-e2fsck, or pass --skip-fsck"
fi

MKFS_CMD=""
if [ "$DO_OVERLAY_MKFS" = "1" ]; then
    if have_cmd mkfs.ext4; then MKFS_CMD="mkfs.ext4"
    elif have_cmd mke2fs;  then MKFS_CMD="mke2fs"
    else die "neither mkfs.ext4 nor mke2fs found, and --keep-overlay was not given"; fi
    log "overlay mkfs tool: $MKFS_CMD"
fi

# --- slot selection and guards --------------------------------------------
ACTIVE=$(active_slot)
RUNNING=""
RUNNING=$(running_slot 2>/dev/null) || RUNNING=""
log "active slot (mender_boot_part): p$ACTIVE"
log "running slot:                   $(describe_running_slot)"

if [ -z "$TARGET" ]; then
    TARGET=$(other_slot "$ACTIVE") || die "cannot derive the inactive slot from mender_boot_part=$ACTIVE"
fi
is_valid_slot "$TARGET" || die "--slot must be $OMNI_SLOT_A or $OMNI_SLOT_B, got '$TARGET'"
[ "$TARGET" != "$ACTIVE" ] || die "refusing to flash p$TARGET: it is the ACTIVE slot"
if [ -n "$RUNNING" ]; then
    [ "$TARGET" != "$RUNNING" ] || die "refusing to flash p$TARGET: it is the RUNNING root filesystem"
fi

TGT_DEV=$(slot_dev "$TARGET")
OVL_NO=$(overlay_part "$TARGET")
OVL_DEV=$(overlay_dev "$TARGET")

need_blockdev "$TGT_DEV" "target slot p$TARGET"
assert_not_mounted "$TGT_DEV" "target slot p$TARGET"

# Overlay guards.  The overlay upper is ROOT_PART_NO + 4, i.e. p5 for slot A
# and p6 for slot B.  Anything else here would be catastrophic: p3 is /data and
# p7 is the recovery partition.
case "$OVL_NO" in
    5|6) ;;
    *) die "computed overlay partition p$OVL_NO for slot p$TARGET is outside {5,6} - refusing" ;;
esac
[ "$OVL_NO" != "$OMNI_DATA_PART" ]     || die "overlay partition resolves to /data (p$OMNI_DATA_PART) - refusing"
[ "$OVL_NO" != "$OMNI_RECOVERY_PART" ] || die "overlay partition resolves to recovery (p$OMNI_RECOVERY_PART) - refusing"
[ "$OVL_DEV" != "$TGT_DEV" ]           || die "overlay device equals the rootfs device - refusing"
if [ "$DO_OVERLAY_MKFS" = "1" ]; then
    need_blockdev "$OVL_DEV" "target overlay p$OVL_NO"
    assert_not_mounted "$OVL_DEV" "target overlay p$OVL_NO"
    # Belt and braces: the ACTIVE slot's overlay must never be the one we wipe.
    ACTIVE_OVL=$(overlay_dev "$ACTIVE")
    [ "$OVL_DEV" != "$ACTIVE_OVL" ] || die "target overlay $OVL_DEV is the ACTIVE slot's overlay - refusing"
fi

TGT_SIZE=$(dev_size_bytes "$TGT_DEV") || die "cannot determine the size of $TGT_DEV"
log "target slot p$TARGET   $TGT_DEV   $(human_bytes "$TGT_SIZE") ($TGT_SIZE bytes)"
log "target overlay p$OVL_NO $OVL_DEV"
log "image size             $(human_bytes "$IMG_SIZE") ($IMG_SIZE bytes)"
log "image sha256           $IMG_SHA"
if [ "$IMG_SIZE" -gt "$TGT_SIZE" ]; then
    die "image ($IMG_SIZE bytes) does not fit in $TGT_DEV ($TGT_SIZE bytes)"
fi
if [ "$IMG_SIZE" -lt "$TGT_SIZE" ]; then
    log "image is $(human_bytes "$(( TGT_SIZE - IMG_SIZE ))") smaller than the partition; the tail is left as-is"
    log "  (that is fine - the filesystem inside the image defines its own size, and"
    log "   verification hashes exactly the first $IMG_SIZE bytes)"
fi

warn_recovery_diversion
warn_watchdog_diversion

# --- source classification -------------------------------------------------
SRC_KIND=""
case "$IMAGE" in
    http://*|https://*|ftp://*|ftps://*) SRC_KIND=url ;;
    file://*) IMAGE="${IMAGE#file://}"; SRC_KIND=file ;;
    *) SRC_KIND=file ;;
esac

SRC_BASENAME="$IMAGE"
SRC_BASENAME="${SRC_BASENAME%%\?*}"        # strip any query string
SRC_BASENAME="${SRC_BASENAME%%#*}"
SRC_BASENAME=$(basename -- "$SRC_BASENAME")

if [ "$SRC_KIND" = "file" ]; then
    [ -f "$IMAGE" ] || die "--image '$IMAGE' is not an existing file (and does not look like a URL)"
    log "image source: local file $IMAGE"
else
    need_cmd curl
    log "image source: URL $IMAGE"
fi

if [ "$COMPRESSION" = "auto" ]; then
    case "$SRC_BASENAME" in
        *.gz|*.gzip) COMPRESSION=gzip ;;
        *.xz)        COMPRESSION=xz ;;
        *.zst|*.zstd) COMPRESSION=zstd ;;
        *)           COMPRESSION=none ;;
    esac
fi
case "$COMPRESSION" in
    none) ;;
    gzip) need_cmd gzip ;;
    xz)   need_cmd xz ;;
    zstd) need_cmd zstd ;;
    *) die "--compression must be auto|none|gzip|xz|zstd, got '$COMPRESSION'" ;;
esac
log "compression: $COMPRESSION"

free_bytes() {
    # free_bytes <dir> -> bytes available to root
    local d="$1" kb
    kb=$(df -kP "$d" 2>/dev/null | awk 'NR==2 {print $4; exit}') || return 1
    case "$kb" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' "$(( kb * 1024 ))"
}

remote_content_length() {
    curl -fsIL --max-time 30 -- "$1" 2>/dev/null \
        | tr -d '\r' \
        | awk 'BEGIN{IGNORECASE=1} /^content-length:/ {v=$2} END{ if (v != "") print v }'
}

# --- staging ---------------------------------------------------------------
STAGE=0
case "$STAGE_MODE" in
    no) STAGE=0 ;;
    yes)
        [ "$SRC_KIND" = "url" ] || die "--stage yes makes no sense for a local file"
        STAGE=1
        ;;
    auto)
        if [ "$SRC_KIND" = "url" ]; then
            NEED=$(remote_content_length "$IMAGE" || printf '')
            case "$NEED" in ''|*[!0-9]*) NEED="$IMG_SIZE" ;; esac
            if mkdir -p "$STAGE_DIR" 2>/dev/null && AVAIL=$(free_bytes "$STAGE_DIR"); then
                if [ "$AVAIL" -gt "$(( NEED + 16777216 ))" ]; then
                    STAGE=1
                    log "staging: $STAGE_DIR has $(human_bytes "$AVAIL") free, need ~$(human_bytes "$NEED")"
                else
                    warn "staging skipped: $STAGE_DIR has only $(human_bytes "$AVAIL") free, need ~$(human_bytes "$NEED")"
                    warn "  streaming straight to the slot instead - a dropped transfer will be"
                    warn "  caught by the byte count and sha256 checks, but the slot will be"
                    warn "  left half written (harmless: it is not the active slot)"
                fi
            else
                warn "staging skipped: cannot use $STAGE_DIR"
            fi
        fi
        ;;
    *) die "--stage must be auto|yes|no, got '$STAGE_MODE'" ;;
esac

# ===========================================================================
# QUIESCE
# ===========================================================================
banner "quiesce"

if have_cmd systemctl; then
    log "disabling the systemd runtime watchdog for the duration of the write"
    if [ "$DRY_RUN" = "1" ]; then
        log_dry "would create $DROPIN_PATH with RuntimeWatchdogSec=0"
        log_dry "would run: systemctl daemon-reexec"
        log_dry "would assert: systemctl show -p RuntimeWatchdogUSec --value == 0"
        DROPIN_MADE=1   # so the dry run also shows the symmetric restore
    else
        mkdir -p /run/systemd/system.conf.d || die "cannot create /run/systemd/system.conf.d"
        printf '[Manager]\nRuntimeWatchdogSec=0\n' > "$DROPIN_PATH" || die "cannot write $DROPIN_PATH"
        DROPIN_MADE=1
        systemctl daemon-reexec || die "systemctl daemon-reexec failed"
        WD=$(systemctl show -p RuntimeWatchdogUSec --value 2>/dev/null || printf '')
        if [ -z "$WD" ]; then
            WD=$(systemctl show -p RuntimeWatchdogUSec 2>/dev/null | sed 's/^RuntimeWatchdogUSec=//' || printf '')
        fi
        case "$WD" in
            0|0s|off) ok "RuntimeWatchdogUSec=$WD - watchdog disabled" ;;
            *)
                err "RuntimeWatchdogUSec=$WD after daemon-reexec (wanted 0)."
                err "  A watchdog bite during the write diverts the NEXT boot to the p7"
                err "  recovery partition, ahead of A/B selection.  Refusing to write."
                die "watchdog could not be disabled"
                ;;
        esac
    fi
else
    warn "systemctl not found - cannot assert that the runtime watchdog is off"
    warn "  If a hardware watchdog is being pet by something else, a stall during"
    warn "  the write diverts the next boot to recovery p$OMNI_RECOVERY_PART."
fi

QUIESCE_UNITS="$DEFAULT_QUIESCE_UNITS $EXTRA_QUIESCE_UNITS"
if have_cmd systemctl; then
    for u in $QUIESCE_UNITS; do
        if ! systemctl list-unit-files "$u" >/dev/null 2>&1; then
            debug "unit $u: not installed"
        fi
        if systemctl is-active --quiet "$u" 2>/dev/null; then
            log "stopping $u"
            if [ "$DRY_RUN" = "1" ]; then
                log_dry "would run: systemctl stop $u"
                STOPPED_UNITS="$STOPPED_UNITS $u"
            elif systemctl stop "$u" 2>/dev/null; then
                STOPPED_UNITS="$STOPPED_UNITS $u"
            else
                warn "could not stop $u - continuing"
            fi
        else
            debug "unit $u: not active, leaving alone"
        fi
    done
    [ -n "$STOPPED_UNITS" ] && ok "stopped:$STOPPED_UNITS" || log "nothing to stop"
fi

# --- writeback tuning ------------------------------------------------------
log "tuning writeback so a 400 MB dd cannot build a huge dirty pile on 512 MB"
SAVED_DIRTY_BYTES=$(read_sysfile /proc/sys/vm/dirty_bytes)
SAVED_DIRTY_BG_BYTES=$(read_sysfile /proc/sys/vm/dirty_background_bytes)
SAVED_DIRTY_RATIO=$(read_sysfile /proc/sys/vm/dirty_ratio)
SAVED_DIRTY_BG_RATIO=$(read_sysfile /proc/sys/vm/dirty_background_ratio)
SAVED_PRINTK=$(read_sysfile /proc/sys/kernel/printk)
SYSCTL_SAVED=1
log "  saved: dirty_bytes=$SAVED_DIRTY_BYTES dirty_background_bytes=$SAVED_DIRTY_BG_BYTES"
log "         dirty_ratio=$SAVED_DIRTY_RATIO dirty_background_ratio=$SAVED_DIRTY_BG_RATIO"
log "         printk='$SAVED_PRINTK'"
write_sysfile /proc/sys/vm/dirty_bytes 16777216 || warn "could not set vm.dirty_bytes"
write_sysfile /proc/sys/vm/dirty_background_bytes 8388608 || warn "could not set vm.dirty_background_bytes"
write_sysfile /proc/sys/kernel/printk "3 4 1 3" || warn "could not quiet the console"

log "sync + drop_caches"
if [ "$DRY_RUN" != "1" ]; then
    sync
    [ -w /proc/sys/vm/drop_caches ] && printf '3\n' > /proc/sys/vm/drop_caches || true
fi

# --- memory gate -----------------------------------------------------------
MEM_AVAIL=$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null || printf '')
if [ -z "$MEM_AVAIL" ]; then
    MEM_AVAIL=$(awk '/^MemFree:/ {f=$2} /^Cached:/ {c=$2} END {print f + c}' /proc/meminfo 2>/dev/null || printf '0')
    warn "MemAvailable not exported; using MemFree+Cached = ${MEM_AVAIL} kB"
fi
case "$MEM_AVAIL" in
    ''|*[!0-9]*) die "could not read a usable memory figure from /proc/meminfo (got '$MEM_AVAIL')" ;;
esac
log "MemAvailable: ${MEM_AVAIL} kB (require >= ${MIN_MEM_KB} kB)"
if [ "$MEM_AVAIL" -lt "$MIN_MEM_KB" ]; then
    err "not enough free memory to write safely."
    err "  This box has 512 MB and /var/volatile/log alone is a 140 MB tmpfs."
    err "  Free some up (journalctl --vacuum-size=, rm -rf /var/volatile/log/*,"
    err "  stop more services) or lower the gate with --min-mem-kb."
    die "memory gate failed"
fi
ok "memory gate passed"

# ===========================================================================
# STAGE (optional)
# ===========================================================================
if [ "$STAGE" = "1" ]; then
    banner "stage"
    mkdir -p "$STAGE_DIR" || die "cannot create $STAGE_DIR"
    STAGED_FILE="$STAGE_DIR/$SRC_BASENAME"
    log "downloading to $STAGED_FILE"
    if [ "$DRY_RUN" = "1" ]; then
        log_dry "would run: curl -fL --retry 3 --retry-delay 5 -o $STAGED_FILE.part $IMAGE"
        log_dry "would run: mv $STAGED_FILE.part $STAGED_FILE"
    else
        rm -f -- "$STAGED_FILE.part"
        curl -fL --retry 3 --retry-delay 5 --connect-timeout 20 \
             -o "$STAGED_FILE.part" -- "$IMAGE" \
            || die "download failed - nothing has been written to the slot"
        mv -f -- "$STAGED_FILE.part" "$STAGED_FILE" || die "cannot rename staged download"
        ok "staged $(human_bytes "$(wc -c < "$STAGED_FILE")")"
    fi
    IMAGE="$STAGED_FILE"
    SRC_KIND=file
fi

# ===========================================================================
# DESTRUCTIVE FROM HERE ON - target slot only
# ===========================================================================
banner "wipe the target slot's overlay upper (p$OVL_NO)"

mke2fs_accepts() {
    # Probe whether this mke2fs understands "-O ^<feature>" without touching
    # any real device.  1.46 (kirkstone) does not know orphan_file; 1.47
    # (trixie) enables it by default.
    local feat="$1" probe
    [ "$DRY_RUN" = "1" ] && return 1
    probe="$(omni_rundir)/mkfs-probe.img"
    : > "$probe" 2>/dev/null || return 1
    if mke2fs -q -F -n -O "^$feat" -b 1024 "$probe" 1024 >/dev/null 2>&1; then
        rm -f -- "$probe"; return 0
    fi
    rm -f -- "$probe"; return 1
}

if [ "$DO_OVERLAY_MKFS" = "1" ]; then
    if [ "$OVERLAY_MKFS_OPTS_SET" = "0" ] && have_cmd mke2fs; then
        # Keep the overlay mountable by BOTH kernels.  If this script ever runs
        # from a Debian trixie slot (e2fsprogs 1.47) while the other slot is
        # still the 5.4 Yocto kernel, an overlay carrying metadata_csum_seed or
        # orphan_file would not mount there, and a rollback would strand you.
        DISABLE=""
        for f in metadata_csum_seed orphan_file; do
            if mke2fs_accepts "$f"; then
                DISABLE="${DISABLE:+$DISABLE,}^$f"
            else
                debug "mke2fs does not know feature '$f'; nothing to disable"
            fi
        done
        [ -n "$DISABLE" ] && OVERLAY_MKFS_OPTS="-O $DISABLE"
    fi
    log "$MKFS_CMD -F -q ${OVERLAY_MKFS_OPTS:-} $OVL_DEV"
    log "  (the initramfs recreates /overlay/upper and /overlay/work itself)"
    if [ "$DRY_RUN" = "1" ]; then
        log_dry "would run: $MKFS_CMD -F -q ${OVERLAY_MKFS_OPTS:-} $OVL_DEV"
    else
        # shellcheck disable=SC2086
        if [ "$MKFS_CMD" = "mkfs.ext4" ]; then
            mkfs.ext4 -F -q $OVERLAY_MKFS_OPTS "$OVL_DEV" || die "mkfs of $OVL_DEV failed"
        else
            mke2fs -t ext4 -F -q $OVERLAY_MKFS_OPTS "$OVL_DEV" || die "mkfs of $OVL_DEV failed"
        fi
        ok "overlay upper p$OVL_NO reformatted - no stale Avast files can resurrect"
    fi
else
    warn "--keep-overlay: p$OVL_NO was NOT reformatted."
    warn "  Whatever is in that overlay upper will be layered on top of the new"
    warn "  rootfs at the next boot of slot p$TARGET."
fi

banner "write the image to p$TARGET ($TGT_DEV)"

stream_source() {
    case "$SRC_KIND" in
        file) cat -- "$IMAGE" ;;
        url)  curl -fL --retry 3 --retry-delay 5 --connect-timeout 20 -- "$IMAGE" ;;
    esac
}
decompress() {
    case "$COMPRESSION" in
        none) cat ;;
        gzip) gzip -dc ;;
        xz)   xz -dc ;;
        zstd) zstd -dc ;;
    esac
}

if [ "$DRY_RUN" = "1" ]; then
    log_dry "would run: <source> | <decompress> | dd of=$TGT_DEV bs=1M iflag=fullblock conv=fsync"
    log_dry "would assert dd copied exactly $IMG_SIZE bytes"
    log_dry "would assert sha256 of the first $IMG_SIZE bytes of $TGT_DEV == $IMG_SHA"
    [ "$SKIP_FSCK" = "0" ] && log_dry "would run: e2fsck -fn $TGT_DEV"
else
    DDERR="$(omni_rundir)/dd.err"
    set +e
    # Truncation guard #1a: every stage's own exit status.  A transfer that is
    # cut short still lets dd exit 0, so the source stage's status is the only
    # thing that reports it.  Each stage records its status in a file (POSIX
    # pipelines run each stage in a subshell, so a variable cannot come back);
    # pipe_status_string renders them in bash's "${PIPESTATUS[*]}" format.
    pipe_status_reset
    { stream_source; pipe_status_mark 1; } \
        | { decompress; pipe_status_mark 2; } \
        | { dd of="$TGT_DEV" bs=1M iflag=fullblock conv=fsync 2>"$DDERR"; pipe_status_mark 3; }
    PIPE_RC=$(pipe_status_string 3)
    set -e
    [ -s "$DDERR" ] && sed 's/^/    dd: /' "$DDERR" >&2

    case "$PIPE_RC" in
        "0 0 0") ok "pipeline exited cleanly" ;;
        *)
            err "write pipeline failed (exit codes source/decompress/dd = $PIPE_RC)"
            err "  A non-zero source status usually means the transfer was cut short;"
            err "  a non-zero decompress status means a truncated or corrupt archive."
            die "image write failed - the ACTIVE slot p$ACTIVE is untouched and still boots"
            ;;
    esac

    # Truncation guard #1: exact byte count out of dd.
    WROTE=$(awk '/bytes/ {print $1; exit}' "$DDERR" 2>/dev/null || printf '')
    case "$WROTE" in
        ''|*[!0-9]*)
            warn "could not parse dd's byte count from its output; relying on the digest"
            ;;
        *)
            log "dd wrote $WROTE bytes"
            if [ "$WROTE" -ne "$IMG_SIZE" ]; then
                err "dd wrote $WROTE bytes, but --size says $IMG_SIZE."
                err "  The image was truncated in transit, or --size is wrong."
                die "byte count mismatch - slot p$TARGET is now inconsistent, the active slot p$ACTIVE is not"
            fi
            ok "byte count matches --size exactly"
            ;;
    esac

    log "flushing"
    sync
    blockdev --flushbufs "$OMNI_EMMC" 2>/dev/null || true
    blockdev --flushbufs "$TGT_DEV" 2>/dev/null || true
    # Make the read-back come from the eMMC, not from the page cache we just filled.
    [ -w /proc/sys/vm/drop_caches ] && printf '3\n' > /proc/sys/vm/drop_caches || true

    # Truncation guard #2: digest over exactly IMG_SIZE bytes read back from
    # the device.  A short write leaves stale bytes in the tail of that range,
    # so this catches truncation even if dd's own accounting looked fine.
    banner "verify"
    log "hashing the first $IMG_SIZE bytes of $TGT_DEV"
    set +e
    pipe_status_reset
    ACTUAL=$( { head -c "$IMG_SIZE" "$TGT_DEV"; pipe_status_mark 1; } \
              | { sha256sum; pipe_status_mark 2; } \
              | { cut -d' ' -f1; pipe_status_mark 3; } )
    VRC=$(pipe_status_string 3)
    set -e
    case "$VRC" in
        "0 0 0") ;;
        *) die "read-back hashing failed (exit codes $VRC)" ;;
    esac
    log "expected sha256: $IMG_SHA"
    log "actual   sha256: $ACTUAL"
    if [ "$ACTUAL" != "$IMG_SHA" ]; then
        err "SHA256 MISMATCH."
        err "  Slot p$TARGET does not contain the image you asked for.  It has NOT"
        err "  been armed; mender_boot_part is still p$ACTIVE and the running slot"
        err "  still boots.  Re-run once you know why (bad download, wrong --size,"
        err "  wrong --sha256, or failing eMMC)."
        die "verification failed"
    fi
    ok "sha256 matches"

    if [ "$SKIP_FSCK" = "0" ]; then
        log "e2fsck -fn $TGT_DEV"
        set +e
        e2fsck -fn "$TGT_DEV"
        FSCK_RC=$?
        set -e
        case "$FSCK_RC" in
            0) ok "e2fsck reports a clean filesystem" ;;
            *) die "e2fsck exited $FSCK_RC on $TGT_DEV (0 required) - not arming" ;;
        esac
    else
        warn "--skip-fsck: the written filesystem was not checked (the digest did match)"
    fi
fi

# ===========================================================================
# ARM
# ===========================================================================
if [ "$DO_ARM" = "0" ]; then
    banner "done (not armed)"
    ok "slot p$TARGET holds the verified image"
    log "--no-arm was given: the environment was not touched."
    log "To try it from the U-Boot prompt without any persistent change:"
    log "    ext4load mmc 0:$TARGET \${fdt_addr_r}     /boot/$(env_get_or mender_dtb_name '<mender_dtb_name>')"
    log "    ext4load mmc 0:$TARGET \${kernel_addr_r}  /boot/$(env_get_or mender_kernel_name '<mender_kernel_name>')"
    log "    ext4load mmc 0:$TARGET \${ramdisk_addr_r} /boot/$(env_get_or mender_ramdisk_name '<mender_ramdisk_name>')"
    log "    setenv bootargs root=$TGT_DEV rootwait rw console=ttyAML0 panic=10"
    log "    booti \${kernel_addr_r} \${ramdisk_addr_r}:\${filesize} \${fdt_addr_r}"
    log "  (never 'saveenv' at the prompt - MENDER_BOOTARGS prepends its own root=)"
    log "Or arm it later with:  $OMNI_DIR/omni-arm.sh --slot $TARGET"
    exit 0
fi

banner "arm slot p$TARGET"
ARM_ARGS="--slot $TARGET"
[ "$DRY_RUN" = "1" ] && ARM_ARGS="$ARM_ARGS --dry-run"
[ -n "$OMNI_LOG_FILE" ] && ARM_ARGS="$ARM_ARGS --log $OMNI_LOG_FILE"
log "running: $OMNI_DIR/omni-arm.sh $ARM_ARGS"
# shellcheck disable=SC2086
"$OMNI_DIR/omni-arm.sh" $ARM_ARGS || die "omni-arm.sh failed - the boot pointer was not moved"

if [ "$DRY_RUN" = "1" ]; then
    log_dry "dry run complete"
    exit 0
fi

banner "done"
ok "slot p$TARGET written, verified and armed"
warn_armed_window

if [ "$DO_REBOOT" = "1" ]; then
    REBOOTING=1
    log "rebooting into p$TARGET; run omni-commit.sh once it is up and healthy"
    reboot_now "rebooting"
else
    warn "--no-reboot: the slot is ARMED and the armed window is open NOW."
    warn "  Reboot soon, then run omni-commit.sh."
fi

exit 0

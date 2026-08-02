#!/bin/bash
# omni-lib.sh - shared helpers for the Avast Omni A/B lifecycle scripts.
#
# Source this from the other omni-*.sh scripts:
#
#     OMNI_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
#     . "$OMNI_DIR/omni-lib.sh"
#
# It can also be executed directly for `--help` and `--self-test`.
#
# TARGET: runs ON the Omni (Amlogic A113D / meson-axg, 512 MB, eMMC), under the
# stock Yocto userland (bash 3.2, coreutils 6.9, no mktemp, no e2fsck) *and*
# under Debian trixie after the migration.  Everything here is deliberately
# written to bash 3.2 / POSIX-ish tool levels: no associative arrays, no
# readarray, no ${var,,}, no `mapfile`, no GNU-only flags without a probe.
#
# ---------------------------------------------------------------------------
# THE ONE THING TO REMEMBER ABOUT THIS BOX
# ---------------------------------------------------------------------------
# The U-Boot environment is ONE non-redundant 8 KB copy at offset 0 of
# /dev/mmcblk0boot0 (see repo/meta-apollo/recipes-bsp/u-boot-apollo/files/
# fw_env.config and patch 0036, which explicitly drops CONFIG_ENV_OFFSET_REDUND).
# There is no second copy and no checksum-protected fallback: a torn write is
# unrecoverable in-band.  On canary loss U-Boot runs `env default -a; saveenv`,
# which restores force_run_mfc=1 and traps the unit in a recovery partition that
# this repo cannot even build an initrd for.
#
# Consequences, all enforced below:
#   * boot0 is a read-only-by-default eMMC boot partition.  EVERY write must be
#     bracketed by `echo 0 > /sys/block/mmcblk0boot0/force_ro` ... `echo 1 > ...`.
#   * Every env write is ONE batched `fw_setenv -s <file>` call, never a series
#     of individual fw_setenv invocations.
#   * Every env write is followed by sync + drop_caches + read-back assertion.
#
# BATCHING IS NOT ATOMICITY.  `fw_setenv -s file` collapses *our* write into a
# single 8 KB rewrite, but it does nothing about U-Boot's own writes:
# CONFIG_BOOTCOUNT_ENV=y (patch 0038) means U-Boot calls env_save() on EVERY
# armed boot to persist `bootcount`, and `mender_altbootcmd` calls saveenv again
# when it flips the slot.  Those are two further torn-write windows we do not
# control.  The only mitigation is time: keep the armed window (upgrade_available=1)
# as short as possible and do not power-cycle between arm and commit.
# ---------------------------------------------------------------------------

# Guard against double-sourcing.
if [ -n "${OMNI_LIB_LOADED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
OMNI_LIB_LOADED=1
OMNI_LIB_VERSION="1.0.0"

# Deterministic parsing of dd/df/sfdisk output.
export LC_ALL=C
# /sbin and /usr/sbin hold fw_printenv, fw_setenv, blockdev, e2fsck, mkfs.ext4.
case ":$PATH:" in *:/sbin:*) ;; *) PATH="$PATH:/sbin" ;; esac
case ":$PATH:" in *:/usr/sbin:*) ;; *) PATH="$PATH:/usr/sbin" ;; esac
export PATH

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
OMNI_EMMC="${OMNI_EMMC:-/dev/mmcblk0}"
OMNI_PART_PREFIX="${OMNI_PART_PREFIX:-/dev/mmcblk0p}"
OMNI_SLOT_A=1                  # MENDER_ROOTFS_PART_A_NUMBER
OMNI_SLOT_B=2                  # MENDER_ROOTFS_PART_B_NUMBER
OMNI_DATA_PART=3               # /data (data.mount)
OMNI_RECOVERY_PART=7           # APOLLO_ROOTFS_PART_R_NUMBER
OMNI_OVERLAY_OFFSET=4          # OVERLAY_PART_NO = ROOT_PART_NO + 4
OMNI_FW_ENV_CONFIG="${OMNI_FW_ENV_CONFIG:-/etc/fw_env.config}"

# Test hooks.  These exist ONLY so the safety-critical parsing and the
# force_ro/write/read-back sequence can be exercised off-device (the unit is
# not reachable and there is no passwordless sudo on the build host).  They
# default to the real kernel interfaces and should never be set in production.
OMNI_CMDLINE="${OMNI_CMDLINE:-/proc/cmdline}"
OMNI_PROC_MOUNTS="${OMNI_PROC_MOUNTS:-/proc/mounts}"
OMNI_FORCE_RO_PATH="${OMNI_FORCE_RO_PATH:-}"

# Runtime state, overridable by the calling script.
DRY_RUN="${DRY_RUN:-0}"
OMNI_LOG_FILE="${OMNI_LOG_FILE:-}"
OMNI_RUNDIR="${OMNI_RUNDIR:-}"
OMNI_ENV_FORMAT="${OMNI_ENV_FORMAT:-auto}"   # auto | space | equals

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
if [ -t 2 ] && [ -z "${OMNI_NO_COLOUR:-}" ]; then
    _C_RED=$'\033[1;31m'; _C_YEL=$'\033[1;33m'; _C_GRN=$'\033[1;32m'
    _C_BLU=$'\033[1;34m'; _C_DIM=$'\033[2m';    _C_OFF=$'\033[0m'
else
    _C_RED=''; _C_YEL=''; _C_GRN=''; _C_BLU=''; _C_DIM=''; _C_OFF=''
fi

_omni_stamp() { date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || printf 'no-clock'; }

_omni_emit() {
    # _omni_emit <colour> <tag> <message...>
    local colour="$1" tag="$2"; shift 2
    local line
    line="$(_omni_stamp) [$tag] $*"
    printf '%s%s%s\n' "$colour" "$line" "$_C_OFF" >&2
    if [ -n "$OMNI_LOG_FILE" ]; then
        printf '%s\n' "$line" >> "$OMNI_LOG_FILE" 2>/dev/null || true
    fi
}

log()      { _omni_emit "$_C_BLU" "INFO " "$@"; }
ok()       { _omni_emit "$_C_GRN" "OK   " "$@"; }
warn()     { _omni_emit "$_C_YEL" "WARN " "$@"; }
err()      { _omni_emit "$_C_RED" "ERROR" "$@"; }
debug()    { [ -n "${OMNI_DEBUG:-}" ] && _omni_emit "$_C_DIM" "DEBUG" "$@"; return 0; }
log_dry()  { _omni_emit "$_C_DIM" "DRY  " "$@"; }

die() {
    err "$@"
    err "aborting - no further action taken"
    exit 1
}

log_open() {
    # log_open <file>  - tee all subsequent log output into <file>.
    local f="$1" d
    d=$(dirname -- "$f")
    [ -d "$d" ] || mkdir -p "$d" || die "cannot create log directory $d"
    : >> "$f" || die "cannot write log file $f"
    OMNI_LOG_FILE="$f"
    printf '%s\n' "=== omni-lib $OMNI_LIB_VERSION log opened $(_omni_stamp) ===" >> "$f"
}

banner() {
    local msg="$1"
    printf '%s\n' "-------------------------------------------------------------------" >&2
    printf '%s%s%s\n' "$_C_BLU" "  $msg" "$_C_OFF" >&2
    printf '%s\n' "-------------------------------------------------------------------" >&2
}

# run <cmd...> - execute, or describe when DRY_RUN=1.
run() {
    if [ "$DRY_RUN" = "1" ]; then
        log_dry "would run: $*"
        return 0
    fi
    "$@"
}

# ---------------------------------------------------------------------------
# Preconditions / tool discovery
# ---------------------------------------------------------------------------
have_cmd() { command -v "$1" >/dev/null 2>&1; }

need_cmd() {
    # need_cmd <name> [hint]
    local c="$1" hint="${2:-}"
    if ! have_cmd "$c"; then
        err "required command not found: $c"
        [ -n "$hint" ] && err "  hint: $hint"
        die "missing prerequisite"
    fi
}

need_root() {
    local uid
    uid=$(id -u 2>/dev/null || printf '%s' "${EUID:-1}")
    [ "$uid" = "0" ] || die "must run as root (uid 0), got uid=$uid"
}

need_file() { [ -f "$1" ] || die "required file missing: $1${2:+ ($2)}"; }
need_blockdev() { [ -b "$1" ] || die "not a block device: $1${2:+ ($2)}"; }

# dd on this box is coreutils 6.9 (meta-gplv2).  Confirm the two flags the
# flash path depends on actually exist rather than discovering it mid-write.
need_dd_features() {
    local h
    h=$(dd --help 2>&1 || true)
    case "$h" in
        *fullblock*) ;;
        *) die "dd does not support iflag=fullblock - refusing to stream an image" ;;
    esac
    case "$h" in
        *fsync*) ;;
        *) die "dd does not support conv=fsync - refusing to stream an image" ;;
    esac
    debug "dd supports iflag=fullblock and conv=fsync"
}

# ---------------------------------------------------------------------------
# Temp / run directory  (coreutils 6.9 has no mktemp)
# ---------------------------------------------------------------------------
omni_rundir() {
    # Lazily create a private, root-only scratch directory on tmpfs.
    if [ -n "$OMNI_RUNDIR" ] && [ -d "$OMNI_RUNDIR" ]; then
        printf '%s' "$OMNI_RUNDIR"; return 0
    fi
    local base d
    if [ -d /run ] && [ -w /run ]; then base=/run
    elif [ -d /tmp ] && [ -w /tmp ]; then base=/tmp
    else die "no writable /run or /tmp for scratch files"; fi
    if have_cmd mktemp; then
        d=$(mktemp -d "$base/omni.XXXXXX" 2>/dev/null) || d=""
    fi
    if [ -z "${d:-}" ]; then
        # mkdir is atomic; loop until we win a name.
        local n=0
        while :; do
            d="$base/omni.$$.$n"
            mkdir "$d" 2>/dev/null && break
            n=$((n + 1))
            [ "$n" -gt 64 ] && die "cannot create scratch directory under $base"
        done
    fi
    chmod 0700 "$d" 2>/dev/null || true
    OMNI_RUNDIR="$d"
    printf '%s' "$OMNI_RUNDIR"
}

omni_rundir_cleanup() {
    [ -n "$OMNI_RUNDIR" ] || return 0
    case "$OMNI_RUNDIR" in
        /run/omni.*|/tmp/omni.*) rm -rf -- "$OMNI_RUNDIR" 2>/dev/null || true ;;
        *) warn "refusing to remove unexpected scratch dir $OMNI_RUNDIR" ;;
    esac
    OMNI_RUNDIR=""
}

# ---------------------------------------------------------------------------
# Block-device helpers
# ---------------------------------------------------------------------------
slot_dev()    { printf '%s%s' "$OMNI_PART_PREFIX" "$1"; }
overlay_part(){ printf '%s' "$(( $1 + OMNI_OVERLAY_OFFSET ))"; }
overlay_dev() { printf '%s%s' "$OMNI_PART_PREFIX" "$(( $1 + OMNI_OVERLAY_OFFSET ))"; }

other_slot() {
    case "$1" in
        "$OMNI_SLOT_A") printf '%s' "$OMNI_SLOT_B" ;;
        "$OMNI_SLOT_B") printf '%s' "$OMNI_SLOT_A" ;;
        *) return 1 ;;
    esac
}

is_valid_slot() {
    case "$1" in "$OMNI_SLOT_A"|"$OMNI_SLOT_B") return 0 ;; *) return 1 ;; esac
}

dev_size_bytes() {
    # dev_size_bytes <dev> -> bytes on stdout
    local d="$1"
    if have_cmd blockdev; then
        blockdev --getsize64 "$d" 2>/dev/null && return 0
    fi
    # /sys fallback: sectors are always 512 B here regardless of logical size.
    local name sectors
    name=$(basename -- "$(readlink -f -- "$d" 2>/dev/null || printf '%s' "$d")")
    if [ -r "/sys/class/block/$name/size" ]; then
        read -r sectors < "/sys/class/block/$name/size"
        printf '%s' "$(( sectors * 512 ))"
        return 0
    fi
    return 1
}

human_bytes() {
    local b="$1"
    if   [ "$b" -ge 1073741824 ] 2>/dev/null; then printf '%s GiB' "$(( b / 1073741824 ))"
    elif [ "$b" -ge 1048576 ]    2>/dev/null; then printf '%s MiB' "$(( b / 1048576 ))"
    elif [ "$b" -ge 1024 ]       2>/dev/null; then printf '%s KiB' "$(( b / 1024 ))"
    else printf '%s B' "$b"; fi
}

dev_id() {
    # dev_id <path> -> "major:minor" for a block device, empty otherwise.
    local p="$1"
    [ -b "$p" ] || return 1
    if have_cmd stat; then
        stat -Lc '%t:%T' -- "$p" 2>/dev/null && return 0
    fi
    readlink -f -- "$p" 2>/dev/null
}

# ext4 superblock magic 0xEF53 lives at byte offset 0x438 (little endian).
# Used when dumpe2fs is unavailable - the stock image ships only e2fsprogs-mke2fs.
ext4_magic_ok() {
    local dev="$1" magic
    [ -b "$dev" ] || return 1
    magic=$(dd if="$dev" bs=1 skip=1080 count=2 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')
    [ "$magic" = "53ef" ]
}

assert_looks_like_ext4() {
    # assert_looks_like_ext4 <dev> <label-for-messages>
    local dev="$1" what="${2:-$1}"
    if have_cmd dumpe2fs; then
        if dumpe2fs -h "$dev" >/dev/null 2>&1; then
            debug "$what: dumpe2fs -h succeeded"
            return 0
        fi
        die "$what ($dev) does not hold a readable ext2/3/4 superblock (dumpe2fs -h failed)"
    fi
    if ext4_magic_ok "$dev"; then
        warn "$what: dumpe2fs unavailable; accepted on raw ext4 magic at 0x438 only"
        return 0
    fi
    die "$what ($dev) has no ext4 magic at offset 0x438 - refusing"
}

# ---------------------------------------------------------------------------
# Mount safety
# ---------------------------------------------------------------------------
_mount_sources() {
    # Print the resolved source of every mount, one per line.
    local src rest
    while read -r src rest; do
        case "$src" in
            /*) printf '%s\n' "$src" ;;
        esac
    done < "$OMNI_PROC_MOUNTS"
}

is_mounted() {
    # is_mounted <dev>  - true if <dev> (by device number, so symlinks and
    # /dev/root aliases are caught) backs any current mount.
    local dev="$1" want src sid
    [ -b "$dev" ] || return 1
    want=$(dev_id "$dev") || return 1
    for src in $(_mount_sources); do
        [ -b "$src" ] || continue
        sid=$(dev_id "$src" 2>/dev/null) || continue
        [ "$sid" = "$want" ] && return 0
    done
    return 1
}

assert_not_mounted() {
    # assert_not_mounted <dev> <label>
    local dev="$1" what="${2:-$1}"
    if is_mounted "$dev"; then
        err "$what ($dev) is currently mounted:"
        grep -F -- "$dev" "$OMNI_PROC_MOUNTS" >&2 || true
        die "refusing to touch a mounted filesystem"
    fi
    debug "$what ($dev) is not mounted"
}

running_root_dev() {
    # Last root= on /proc/cmdline wins - this is exactly the rule U-Boot's
    # MENDER_BOOTARGS relies on, and exactly why pre-flight check P2 demands
    # that no `bootargs` be stored in the environment.
    local tok last=""
    for tok in $(cat "$OMNI_CMDLINE" 2>/dev/null); do
        case "$tok" in root=*) last="${tok#root=}" ;; esac
    done
    [ -n "$last" ] || return 1
    case "$last" in
        PARTUUID=*|UUID=*|LABEL=*|PARTLABEL=*)
            if have_cmd blkid; then
                local t v resolved
                t="${last%%=*}"; v="${last#*=}"
                resolved=$(blkid -t "$t=$v" -o device 2>/dev/null | head -n1)
                [ -n "$resolved" ] && { printf '%s' "$resolved"; return 0; }
            fi
            printf '%s' "$last"
            return 0
            ;;
    esac
    readlink -f -- "$last" 2>/dev/null || printf '%s' "$last"
}

running_slot() {
    # Echo 1 or 2 for a normal A/B boot, 7 for recovery.  Non-zero if unknown.
    local d n
    d=$(running_root_dev) || return 1
    case "$d" in
        "$OMNI_PART_PREFIX"*)
            n="${d#$OMNI_PART_PREFIX}"
            case "$n" in
                ''|*[!0-9]*) return 1 ;;
                *) printf '%s' "$n"; return 0 ;;
            esac
            ;;
    esac
    return 1
}

describe_running_slot() {
    local s
    if s=$(running_slot); then
        case "$s" in
            "$OMNI_RECOVERY_PART") printf 'p%s (RECOVERY)' "$s" ;;
            *) printf 'p%s' "$s" ;;
        esac
    else
        printf 'unknown (root= on /proc/cmdline: %s)' "$(running_root_dev 2>/dev/null || printf '<none>')"
    fi
}

# ---------------------------------------------------------------------------
# U-Boot environment
# ---------------------------------------------------------------------------
env_config_device() {
    # First whitespace-separated field of the first non-comment line of
    # /etc/fw_env.config.  Expected: /dev/mmcblk0boot0
    local dev rest
    [ -r "$OMNI_FW_ENV_CONFIG" ] || { printf '/dev/mmcblk0boot0'; return 0; }
    while read -r dev rest; do
        case "$dev" in ''|\#*) continue ;; esac
        printf '%s' "$dev"
        return 0
    done < "$OMNI_FW_ENV_CONFIG"
    printf '/dev/mmcblk0boot0'
}

env_force_ro_path() {
    # Derive the force_ro knob from whatever fw_env.config actually points at,
    # so a device with a different env location is not silently written with
    # the wrong partition unlocked.
    local dev name p
    if [ -n "$OMNI_FORCE_RO_PATH" ]; then
        printf '%s' "$OMNI_FORCE_RO_PATH"; return 0
    fi
    dev=$(env_config_device)
    name=$(basename -- "$(readlink -f -- "$dev" 2>/dev/null || printf '%s' "$dev")")
    p="/sys/block/$name/force_ro"
    [ -f "$p" ] && { printf '%s' "$p"; return 0; }
    return 1
}

env_assert_config_sane() {
    # Cheap sanity gate before any env write.  Warn (do not die) on a layout
    # that differs from the one this repo builds - the operator may be running
    # against a rebuilt bootloader.
    local dev off size sect line
    if [ ! -r "$OMNI_FW_ENV_CONFIG" ]; then
        warn "$OMNI_FW_ENV_CONFIG is missing; fw_setenv will use its built-in default"
        return 0
    fi
    while read -r dev off size sect; do
        case "$dev" in ''|\#*) continue ;; esac
        line="dev=$dev offset=${off:-?} size=${size:-?} sector=${sect:-?}"
        break
    done < "$OMNI_FW_ENV_CONFIG"
    log "env config: $line"
    case "$dev" in
        *boot0) ;;
        *) warn "env device is $dev, not an eMMC boot0 partition - force_ro handling may not apply" ;;
    esac
    case "$off" in
        0|0x0|0x0000|0x00000000) ;;
        *) warn "env offset is $off, expected 0 for this platform" ;;
    esac
    case "$size" in
        0x2000|8192) ;;
        *) warn "env size is $size, expected 0x2000 (8 KB, single non-redundant copy)" ;;
    esac
    # A second non-comment line means a REDUNDANT env, which patch 0036 removed.
    local n=0
    while read -r dev off size sect; do
        case "$dev" in ''|\#*) continue ;; esac
        n=$((n + 1))
    done < "$OMNI_FW_ENV_CONFIG"
    if [ "$n" -gt 1 ]; then
        warn "$OMNI_FW_ENV_CONFIG declares $n env copies; this repo builds ONE (patch 0036)"
    fi
    return 0
}

env_need_tools() {
    need_cmd fw_printenv "provided by u-boot-fw-utils-apollo (/sbin/fw_printenv)"
    need_cmd fw_setenv   "provided by u-boot-fw-utils-apollo (/sbin/fw_setenv)"
}

env_get() {
    # env_get <name> -> value on stdout.  Returns 1 when the variable is not
    # defined in the STORED environment (fw_printenv exits non-zero and prints
    # "## Error: \"name\" not defined" on stderr).
    local name="$1" v
    v=$(fw_printenv -n "$name" 2>/dev/null) || return 1
    printf '%s' "$v"
}

env_defined() { fw_printenv -n "$1" >/dev/null 2>&1; }

env_get_required() {
    local name="$1" v
    v=$(env_get "$name") || die "environment variable '$name' is not defined in the stored env"
    [ -n "$v" ] || die "environment variable '$name' is defined but empty"
    printf '%s' "$v"
}

env_get_or() {
    # env_get_or <name> <default>
    local v
    v=$(env_get "$1") || { printf '%s' "$2"; return 0; }
    printf '%s' "$v"
}

_env_format() {
    # Which separator does `fw_setenv -s FILE` expect?
    #
    #   U-Boot 2018.09 tools/env/fw_env.c:  name = strtok(line, " \t\n")
    #                                       value = strtok(NULL, "\t\n")   -> "name value"
    #   libubootenv  libuboot_load_file():  name = strtok(line, "=")       -> "name=value"
    #
    # This device ships U-Boot's own tool (recipe u-boot-fw-utils-apollo installs
    # tools/env/fw_printenv to /sbin/fw_{printenv,setenv}), so "space" is right
    # here; Debian trixie ships libubootenv, so the migrated rootfs needs "equals".
    # Detection is non-destructive - we never probe by writing.
    if [ "$OMNI_ENV_FORMAT" != "auto" ]; then
        printf '%s' "$OMNI_ENV_FORMAT"; return 0
    fi
    local bin ver
    bin=$(command -v fw_setenv 2>/dev/null || printf '')
    if [ -n "$bin" ]; then
        ver=$("$bin" --version 2>&1 || true)
        case "$ver" in *libubootenv*|*"libuboot"*) printf 'equals'; return 0 ;; esac
        if [ -r "$bin" ] && grep -aqs 'libubootenv' -- "$bin" 2>/dev/null; then
            printf 'equals'; return 0
        fi
        if have_cmd ldd && ldd "$bin" 2>/dev/null | grep -qs 'libubootenv'; then
            printf 'equals'; return 0
        fi
    fi
    printf 'space'
}

_env_validate_pair() {
    local name="$1" value="$2"
    case "$name" in
        ''|*[!A-Za-z0-9_]*) die "refusing to write env variable with unsafe name: '$name'" ;;
    esac
    case "$name" in
        [0-9]*) die "refusing to write env variable whose name starts with a digit: '$name'" ;;
    esac
    case "$value" in
        *"="*)   die "refusing to write env value containing '=' ($name=$value) - not representable in both fw_setenv batch dialects" ;;
        *$'\t'*) die "refusing to write env value containing a tab ($name)" ;;
        *$'\n'*) die "refusing to write env value containing a newline ($name)" ;;
    esac
}

_force_ro() {
    # _force_ro <0|1> - unlock/relock the eMMC boot partition that holds the env.
    local want="$1" p got
    if ! p=$(env_force_ro_path); then
        warn "no force_ro knob found for $(env_config_device) - continuing without it"
        return 0
    fi
    if [ "$DRY_RUN" = "1" ]; then
        log_dry "would run: echo $want > $p"
        return 0
    fi
    printf '%s\n' "$want" > "$p" 2>/dev/null || {
        err "cannot write $p"
        return 1
    }
    got=$(cat "$p" 2>/dev/null || printf '?')
    if [ "$got" != "$want" ]; then
        err "$p reads '$got' after writing '$want'"
        return 1
    fi
    debug "force_ro=$want ($p)"
    return 0
}

env_flush_and_reread() {
    # Make the read-back honest: push the 8 KB out and drop the page cache so
    # fw_printenv re-reads the eMMC boot partition instead of RAM.
    [ "$DRY_RUN" = "1" ] && return 0
    sync 2>/dev/null || true
    if have_cmd blockdev; then
        blockdev --flushbufs "$(env_config_device)" 2>/dev/null || true
    fi
    if [ -w /proc/sys/vm/drop_caches ]; then
        printf '3\n' > /proc/sys/vm/drop_caches 2>/dev/null || true
    fi
}

env_batch_write() {
    # env_batch_write NAME VALUE [NAME VALUE ...]
    #
    # ONE batched fw_setenv -s call, bracketed by the force_ro dance, followed
    # by sync + drop_caches + a read-back assertion on every pair.
    [ $# -ge 2 ] || die "env_batch_write: need at least one NAME VALUE pair"
    [ $(( $# % 2 )) -eq 0 ] || die "env_batch_write: odd number of arguments"

    env_need_tools

    local fmt sep file rc i
    fmt=$(_env_format)
    case "$fmt" in
        space)  sep=' ' ;;
        equals) sep='=' ;;
        *) die "unknown env batch format '$fmt' (set OMNI_ENV_FORMAT=space|equals)" ;;
    esac

    # Validate everything before opening the write window.
    local -a pairs
    pairs=()
    i=1
    while [ $# -gt 0 ]; do
        _env_validate_pair "$1" "$2"
        pairs[$i]="$1"; i=$((i + 1))
        pairs[$i]="$2"; i=$((i + 1))
        shift 2
    done

    file="$(omni_rundir)/env-batch.txt"
    : > "$file" || die "cannot create $file"
    chmod 0600 "$file" 2>/dev/null || true
    i=1
    while [ $i -lt ${#pairs[@]} ]; do
        printf '%s%s%s\n' "${pairs[$i]}" "$sep" "${pairs[$((i+1))]}" >> "$file"
        i=$((i + 2))
    done

    banner "U-Boot environment write (batched, ${fmt} dialect)"
    log "batch file $file:"
    local line
    while read -r line; do log "    $line"; done < "$file"
    log "NOTE: batching makes OUR write a single 8 KB rewrite.  It cannot make"
    log "      U-Boot's own bootcount env_save() atomic (CONFIG_BOOTCOUNT_ENV=y),"
    log "      nor mender_altbootcmd's saveenv.  Keep the armed window short."

    if [ "$DRY_RUN" = "1" ]; then
        log_dry "would run: echo 0 > $(env_force_ro_path 2>/dev/null || printf '<force_ro>')"
        log_dry "would run: fw_setenv -s $file"
        log_dry "would run: echo 1 > $(env_force_ro_path 2>/dev/null || printf '<force_ro>')"
        log_dry "would read back and assert every pair above"
        return 0
    fi

    _force_ro 0 || die "could not unlock $(env_config_device) for writing (force_ro)"

    set +e
    fw_setenv -s "$file" >/dev/null 2>"$(omni_rundir)/fw_setenv.err"
    rc=$?
    set -e

    # Relock unconditionally, even if the write failed.
    if ! _force_ro 1; then
        err "FAILED TO RE-LOCK $(env_config_device) - it is still writable!"
        err "run manually:  echo 1 > $(env_force_ro_path 2>/dev/null || printf '<force_ro>')"
    fi

    if [ "$rc" -ne 0 ]; then
        err "fw_setenv -s exited $rc"
        [ -s "$(omni_rundir)/fw_setenv.err" ] && cat "$(omni_rundir)/fw_setenv.err" >&2
        err "the stored environment may be unchanged or partially written."
        err "verify with: fw_printenv | sort   and compare against your Phase 0 backup"
        die "environment write failed"
    fi

    env_flush_and_reread

    # Read-back assertion.
    local bad=0 got
    i=1
    while [ $i -lt ${#pairs[@]} ]; do
        got=$(env_get "${pairs[$i]}" || printf '<undefined>')
        if [ "$got" = "${pairs[$((i+1))]}" ]; then
            ok "readback ${pairs[$i]} = $got"
        else
            err "readback MISMATCH ${pairs[$i]}: wanted '${pairs[$((i+1))]}', got '$got'"
            bad=$((bad + 1))
        fi
        i=$((i + 2))
    done
    rm -f -- "$file" 2>/dev/null || true

    if [ "$bad" -ne 0 ]; then
        err "$bad environment variable(s) did not read back correctly."
        err "The stored env is NOT in the state this script intended."
        err "Do NOT reboot until you have inspected 'fw_printenv | sort'."
        err "If the env looks corrupt, restore it from the Phase 0 omni-boot0.img"
        err "at the U-Boot prompt (see omni-backup.sh's restore cheat-sheet)."
        die "environment read-back assertion failed"
    fi
    ok "environment write verified"
    return 0
}

env_show_ab_state() {
    # Print the A/B-relevant variables, tolerating undefined ones.
    local n
    for n in mender_boot_part mender_boot_part_hex bootcount bootlimit \
             upgrade_available force_run_mfc force_run_eol force_hard_recovery \
             check_watchdog bootdelay ethaddr \
             mender_kernel_name mender_dtb_name mender_ramdisk_name; do
        printf '  %-22s %s\n' "$n" "$(env_get "$n" 2>/dev/null || printf '<undefined>')" >&2
    done
}

active_slot() {
    # The slot the BOOTLOADER will pick next, per the stored env.
    local v
    v=$(env_get_required mender_boot_part)
    case "$v" in
        "$OMNI_SLOT_A"|"$OMNI_SLOT_B") printf '%s' "$v"; return 0 ;;
        "$OMNI_RECOVERY_PART")
            die "mender_boot_part=$v (recovery p$OMNI_RECOVERY_PART). The unit is pointed at the recovery partition; fix that before touching A/B."
            ;;
        *)
            die "mender_boot_part='$v' is neither $OMNI_SLOT_A, $OMNI_SLOT_B nor $OMNI_RECOVERY_PART - refusing to guess"
            ;;
    esac
}

slot_hex() {
    # mender_boot_part_hex for slot N.  1 -> "1", 2 -> "2".
    printf '%x' "$1"
}

warn_armed_window() {
    warn "ARMED WINDOW OPEN (upgrade_available=1)."
    warn "  * U-Boot rewrites the whole 8 KB env on every armed boot to persist"
    warn "    bootcount (CONFIG_BOOTCOUNT_ENV=y), and mender_altbootcmd saveenv's"
    warn "    again when it flips the slot.  There is no redundant copy."
    warn "  * Reboot NOW and commit as soon as the box is up."
    warn "  * Do NOT power-cycle between arm and commit."
}

warn_watchdog_diversion() {
    local cw
    cw=$(env_get check_watchdog 2>/dev/null || printf '<undefined>')
    case "$cw" in
        false|"") : ;;
        *)
            warn "check_watchdog = '$cw'"
            warn "  A watchdog reset (or a latched 0xff80023c==0xd000) diverts to p$OMNI_RECOVERY_PART"
            warn "  AHEAD of A/B slot selection, and altbootcmd re-enters bootcmd, so"
            warn "  bootcount rollback cannot escape it.  Characterise this (pre-flight P5)"
            warn "  and consider 'check_watchdog=false' for the duration of the migration."
            ;;
    esac
}

warn_recovery_diversion() {
    local v
    v=$(env_get force_run_mfc 2>/dev/null || printf '<undefined>')
    case "$v" in
        0) : ;;
        *) warn "force_run_mfc='$v' - APOLLO_CHECK_MFC forces p$OMNI_RECOVERY_PART before A/B selection (pre-flight P1)" ;;
    esac
    v=$(env_get force_hard_recovery 2>/dev/null || printf '<undefined>')
    case "$v" in
        1) warn "force_hard_recovery=1 - the next boot goes to p$OMNI_RECOVERY_PART regardless of mender_boot_part" ;;
    esac
    if env_defined bootargs; then
        warn "a stored 'bootargs' exists (pre-flight P2 FAIL): '$(env_get bootargs)'"
        warn "  MENDER_BOOTARGS prepends root=\${mender_kernel_root}; last root= wins,"
        warn "  so a stale stored bootargs can boot one slot's kernel against the other's rootfs."
    fi
}

# ---------------------------------------------------------------------------
# Boot-artifact verification
# ---------------------------------------------------------------------------
boot_names() {
    # Echo the three GLOBAL (not per-slot) artefact names, one per line.
    # Never hardcode these - a field binary may predate patches 0050/0051.
    printf '%s\n' "$(env_get_required mender_kernel_name)"
    printf '%s\n' "$(env_get_required mender_dtb_name)"
    printf '%s\n' "$(env_get_required mender_ramdisk_name)"
}

check_boot_artifacts_at() {
    # check_boot_artifacts_at <rootdir> - all three artefacts present, non-empty.
    local root="$1" missing=0 n sz
    local k d r
    k=$(env_get_required mender_kernel_name)
    d=$(env_get_required mender_dtb_name)
    r=$(env_get_required mender_ramdisk_name)
    for n in "$k" "$d" "$r"; do
        if [ -s "$root/boot/$n" ]; then
            sz=$(wc -c < "$root/boot/$n" 2>/dev/null || printf '?')
            ok "found $root/boot/$n ($sz bytes)"
        elif [ -e "$root/boot/$n" ]; then
            err "$root/boot/$n exists but is EMPTY"
            missing=$((missing + 1))
        else
            err "$root/boot/$n is MISSING"
            missing=$((missing + 1))
        fi
    done
    [ "$missing" -eq 0 ]
}

check_slot_boot_artifacts() {
    # check_slot_boot_artifacts <slot>
    #
    # If <slot> is the running slot, inspect /boot directly (the overlay-merged
    # view is what U-Boot's ext4load will NOT see, but the lower is what it
    # reads - see the caveat printed below).  Otherwise mount the slot
    # read-only at a scratch mountpoint and look there.
    local slot="$1" dev mp rc rslot
    dev=$(slot_dev "$slot")
    need_blockdev "$dev" "slot $slot"

    if rslot=$(running_slot 2>/dev/null) && [ "$rslot" = "$slot" ]; then
        warn "slot $slot is the RUNNING slot; checking the merged overlay view at /boot."
        warn "  U-Boot reads the LOWER filesystem only.  A /boot file that exists"
        warn "  solely in the overlay upper (p$(overlay_part "$slot")) will not be loadable."
        check_boot_artifacts_at "" && return 0
        return 1
    fi

    assert_not_mounted "$dev" "slot $slot"
    mp="$(omni_rundir)/mnt-p$slot"
    mkdir -p "$mp" || die "cannot create $mp"

    if [ "$DRY_RUN" = "1" ]; then
        log_dry "would mount -o ro,noload $dev $mp and check /boot artefacts"
        return 0
    fi

    if ! mount -o ro,noload "$dev" "$mp" 2>/dev/null; then
        if ! mount -o ro "$dev" "$mp" 2>/dev/null; then
            rmdir "$mp" 2>/dev/null || true
            die "cannot mount $dev read-only to verify /boot (use --no-check-boot to skip)"
        fi
        warn "mounted $dev without 'noload'; the journal may have been replayed"
    fi
    set +e
    check_boot_artifacts_at "$mp"
    rc=$?
    set -e
    umount "$mp" 2>/dev/null || { sleep 1; umount -l "$mp" 2>/dev/null || warn "could not unmount $mp"; }
    rmdir "$mp" 2>/dev/null || true
    return $rc
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------
require_writable_proc_sys() {
    [ -w /proc/sys/vm/drop_caches ] || warn "/proc/sys/vm/drop_caches not writable; verification reads may hit the page cache"
}

reboot_now() {
    # reboot_now [reason]
    log "${1:-rebooting}"
    if [ "$DRY_RUN" = "1" ]; then
        log_dry "would run: sync; reboot"
        return 0
    fi
    sync; sync
    if have_cmd systemctl; then
        systemctl reboot || reboot || die "reboot command failed"
    else
        reboot || die "reboot command failed"
    fi
}

omni_lib_self_test() {
    # Pure-function tests.  Touches no hardware, writes nothing.
    local fails=0
    _t() { # _t <desc> <expected> <actual>
        if [ "$2" = "$3" ]; then printf 'ok    %s\n' "$1"
        else printf 'FAIL  %s (expected "%s", got "%s")\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi
    }
    _t "slot_dev 1"        "/dev/mmcblk0p1" "$(slot_dev 1)"
    _t "slot_dev 2"        "/dev/mmcblk0p2" "$(slot_dev 2)"
    _t "overlay_dev 1"     "/dev/mmcblk0p5" "$(overlay_dev 1)"
    _t "overlay_dev 2"     "/dev/mmcblk0p6" "$(overlay_dev 2)"
    _t "overlay_part 1"    "5"              "$(overlay_part 1)"
    _t "other_slot 1"      "2"              "$(other_slot 1)"
    _t "other_slot 2"      "1"              "$(other_slot 2)"
    _t "slot_hex 1"        "1"              "$(slot_hex 1)"
    _t "slot_hex 2"        "2"              "$(slot_hex 2)"
    if other_slot 7 >/dev/null 2>&1; then
        printf 'FAIL  other_slot 7 should fail\n'; fails=$((fails + 1))
    else
        printf 'ok    other_slot 7 refuses\n'
    fi
    if is_valid_slot 7; then printf 'FAIL  is_valid_slot 7\n'; fails=$((fails + 1)); else printf 'ok    is_valid_slot 7 false\n'; fi
    _t "human_bytes 1048576" "1 MiB" "$(human_bytes 1048576)"
    printf '\n'
    if [ "$fails" -eq 0 ]; then printf 'omni-lib self-test: ALL PASS\n'; return 0
    else printf 'omni-lib self-test: %d FAILURE(S)\n' "$fails"; return 1; fi
}

omni_lib_usage() {
    cat <<'EOF'
omni-lib.sh - shared helpers for the Avast Omni A/B lifecycle scripts

This file is meant to be SOURCED, not run:

    OMNI_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
    . "$OMNI_DIR/omni-lib.sh"

Direct invocation supports only:

    omni-lib.sh --help        this text
    omni-lib.sh --self-test   run the pure-function tests (safe anywhere)
    omni-lib.sh --state       print the A/B-relevant stored env (needs fw_printenv)

What it provides
  logging          log/ok/warn/err/debug/die/banner/log_open, DRY_RUN-aware run()
  preconditions    need_root, need_cmd, need_file, need_blockdev, need_dd_features
  slots            active_slot, other_slot, slot_dev, overlay_dev, running_slot,
                   slot_hex, is_valid_slot
  mount safety     is_mounted, assert_not_mounted (compares device numbers, so
                   /dev/root and symlinks are caught, unlike a grep on /proc/mounts)
  filesystems      assert_looks_like_ext4 (dumpe2fs, else raw 0xEF53 magic)
  environment      env_get, env_defined, env_get_required, env_batch_write,
                   env_show_ab_state, env_assert_config_sane

Environment-write contract enforced by env_batch_write()
  1. validate every NAME/VALUE pair before opening any window
  2. write ONE batch file (dialect auto-detected: U-Boot "name value" vs
     libubootenv "name=value"; override with OMNI_ENV_FORMAT=space|equals)
  3. echo 0 > /sys/block/mmcblk0boot0/force_ro
  4. fw_setenv -s <file>
  5. echo 1 > force_ro  -- ALWAYS, even when step 4 failed
  6. sync + blockdev --flushbufs + drop_caches
  7. read back EVERY pair and die on any mismatch

  Batching is not atomicity.  CONFIG_BOOTCOUNT_ENV=y makes U-Boot rewrite the
  same single 8 KB non-redundant env on every armed boot, and mender_altbootcmd
  saveenv's again.  Minimise the armed window; never power-cycle while armed.

Environment variables
  DRY_RUN=1              describe instead of doing
  OMNI_DEBUG=1           verbose
  OMNI_NO_COLOUR=1       plain output
  OMNI_ENV_FORMAT=...    space | equals | auto (default auto)
  OMNI_FW_ENV_CONFIG=... path to fw_env.config (default /etc/fw_env.config)

Test hooks (never set these in production)
  OMNI_CMDLINE=...       stand-in for /proc/cmdline
  OMNI_PROC_MOUNTS=...   stand-in for /proc/mounts
  OMNI_FORCE_RO_PATH=... stand-in for /sys/block/mmcblk0boot0/force_ro
EOF
}

# ---------------------------------------------------------------------------
# Direct invocation
# ---------------------------------------------------------------------------
_omni_lib_main() {
    case "${1:---help}" in
        -h|--help) omni_lib_usage; return 0 ;;
        --self-test) omni_lib_self_test; return $? ;;
        --state)
            env_need_tools
            env_assert_config_sane
            printf 'running slot: %s\n' "$(describe_running_slot)" >&2
            env_show_ab_state
            return 0
            ;;
        --version) printf 'omni-lib.sh %s\n' "$OMNI_LIB_VERSION"; return 0 ;;
        *) omni_lib_usage; return 2 ;;
    esac
}

# Only run main when executed, not when sourced.  BASH_SOURCE is bash 3.x safe.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -euo pipefail
    _omni_lib_main "$@"
    exit $?
fi

#!/bin/sh
#
# omni-preflight.sh - Phase 0 inventory and gate evaluation for the Avast Omni.
#
# Runs ON the device.  READ-ONLY: it collects the full hardware/bootloader
# inventory into a timestamped report directory and evaluates every pre-flight
# check (P1-P8) that can be decided without a power cycle or a serial console.
# The ones that cannot are printed as explicit manual instructions - never
# silently skipped.
#
# It writes NOTHING to the U-Boot environment, NOTHING to any partition, and
# nothing at all outside the report directory.
#
# POSIX sh, not bash: the stock Yocto image has no bash at all and /bin/sh is
# zsh.  See the porting rationale and the list of banned constructs at the top
# of omni-lib.sh; it is not repeated here.
#
set -eu
# pipefail is not POSIX and dash does not have it.  Enable it only where the
# shell supports it; the pipe_status_* helpers, not pipefail, are what the
# safety checks rely on.
if ( set -o pipefail ) 2>/dev/null; then set -o pipefail; fi

OMNI_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=omni-lib.sh
. "${OMNI_LIB:-$OMNI_DIR/omni-lib.sh}"

PROG=omni-preflight.sh

usage() {
    cat <<'EOF'
omni-preflight.sh - Phase 0 inventory + P1-P8 gate evaluation (read-only)

USAGE
  omni-preflight.sh [--outdir DIR] [options]

WHAT IT COLLECTS  (one file per item, in <outdir>/<timestamp>/)
  lsblk-b.txt            lsblk -b
  blockdev-sizes.txt     blockdev --getsize64 for the disk and every partition
  sfdisk-dump.txt        sfdisk -d /dev/mmcblk0          (the partition table)
  fw_printenv.txt        fw_printenv | sort              (only surviving ethaddr)
  dumpe2fs-pN.txt        dumpe2fs -h for p1 p2 p3 p5 p6 p7, or - when dumpe2fs
                         is not installed, which is the stock image's case - the
                         read-only fallback probe (e2fsck -n, then raw 0xEF53)
  mmc-ios.txt            /sys/kernel/debug/mmc0/ios      (timing spec, clock, width)
  mmc-ext_csd.txt        raw ext_csd, plus a decoded pre_eol_info / life_time_est
  proc-cmdline.txt       /proc/cmdline
  boot-listing.txt       ls -la /boot
  mount.txt              mount + /proc/mounts
  meminfo.txt, partitions.txt, uname.txt, df.txt, tools.txt, interrupts.txt
  boot-names.env         mender_kernel_name / _dtb_ / _ramdisk_ VERBATIM, in
                         /etc/default/omni-boot form - this is the file the
                         Debian kernel postinst hook must consume so the three
                         GLOBAL artefact names are never typed from the patches
  SUMMARY.txt            the PASS/FAIL/MANUAL table, as printed

GATES EVALUATED AUTOMATICALLY
  P1  force_run_mfc AND force_run_eol both 0.  Undefined counts as FAIL: the
      compiled defaults are 1, and APOLLO_CHECK_MFC forces p7 ahead of A/B.
  P2  the stored 'bootargs' contains no "root=".  A stored bootargs is NOT by
      itself a failure - a healthy unit has bootargs="rootwait rw
      console=ttyAML0" (patch 0039's fixed common cmdline) and MENDER_BOOTARGS
      prepends root=${mender_kernel_root} at boot.  A root= INSIDE the stored
      value is the failure: the LAST root= wins, so it would boot one slot's
      kernel against the other slot's rootfs.
  P3  ethaddr defined and non-empty.  check_env is dead code, so a lost ethaddr
      is lost forever and CONFIG_NET_RANDOM_ETHADDR gives a new MAC every boot.
  P4  the three mender_*_name values captured verbatim.
  P8  p2 carries a valid ext2/3/4 superblock (slot B has never been booted -
      nothing ever set upgrade_available=1 - so it may be zeros).  Validated
      with dumpe2fs where it exists, otherwise a read-only 'e2fsck -n', and as
      a last resort the raw ext4 magic at offset 0x438.
  Plus informational checks: is altbootcmd/bootlimit/bootcount in the STORED
  env, is check_watchdog armed, what is bootdelay, is p7 populated.

GATES THAT CANNOT BE DECIDED HERE  (printed as manual instructions)
  P5  the 0xff80023c watchdog latch, across six reset types - needs serial
  P6  reset-button cold boot into p7 - needs the case open and a power cycle
  P7  the env corrupt/restore drill at the "=>" prompt - needs serial

OPTIONS
  --outdir DIR        parent directory for the report (default /data/omni-preflight,
                      falling back to ./omni-preflight if /data is not writable)
  --mount-debugfs     mount debugfs at /sys/kernel/debug if it is not mounted,
                      and unmount it again afterwards (needed for mmc ios and
                      ext_csd).  Off by default because it is a system change.
  --ignore-fail       always exit 0, even when an automatic gate fails
  --dry-run           list what would be collected; create and write nothing
  -h, --help          this text

EXIT STATUS
  0  every automatic gate passed (or --ignore-fail / --dry-run)
  1  at least one automatic gate FAILED
  2  bad usage
EOF
}

OUTDIR=""
MOUNT_DEBUGFS=0
IGNORE_FAIL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --outdir)       [ $# -ge 2 ] || die "--outdir needs a value"; OUTDIR="$2"; shift 2 ;;
        --outdir=*)     OUTDIR="${1#*=}"; shift ;;
        --mount-debugfs) MOUNT_DEBUGFS=1; shift ;;
        --ignore-fail)  IGNORE_FAIL=1; shift ;;
        --dry-run)      DRY_RUN=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *) err "unknown argument: $1"; usage >&2; exit 2 ;;
    esac
done

banner "$PROG"
need_root

# --- report directory ------------------------------------------------------
if [ -z "$OUTDIR" ]; then
    if [ -d /data ] && [ -w /data ]; then OUTDIR=/data/omni-preflight; else OUTDIR=./omni-preflight; fi
fi
STAMP=$(date '+%Y%m%d-%H%M%S' 2>/dev/null || printf 'no-clock')
REPORT="$OUTDIR/$STAMP"

if [ "$DRY_RUN" = "1" ]; then
    log_dry "would create $REPORT and collect the inventory into it"
else
    mkdir -p "$REPORT" || die "cannot create $REPORT"
    log_open "$REPORT/collect.log"
    log "report directory: $REPORT"
fi

# --- collection helpers ----------------------------------------------------
DEBUGFS_MOUNTED_BY_US=0
cleanup() {
    if [ "$DEBUGFS_MOUNTED_BY_US" = "1" ]; then
        log "unmounting debugfs (we mounted it)"
        umount /sys/kernel/debug 2>/dev/null || warn "could not unmount /sys/kernel/debug"
        DEBUGFS_MOUNTED_BY_US=0
    fi
    omni_rundir_cleanup
}
trap cleanup EXIT

capture() {
    # capture <outfile> <description> <command...>
    local out="$1" desc="$2"; shift 2
    if [ "$DRY_RUN" = "1" ]; then
        log_dry "would capture $desc -> $out  ($*)"
        return 0
    fi
    log "collecting $desc"
    {
        printf '### %s\n' "$desc"
        printf '### command: %s\n' "$*"
        printf '### %s\n\n' "$(_omni_stamp)"
    } > "$REPORT/$out"
    if ! "$@" >> "$REPORT/$out" 2>&1; then
        printf '\n### (command exited non-zero)\n' >> "$REPORT/$out"
        warn "$desc: command exited non-zero (recorded in $out)"
    fi
    return 0
}

capture_file() {
    # capture_file <outfile> <description> <path>
    local out="$1" desc="$2" path="$3"
    if [ "$DRY_RUN" = "1" ]; then
        log_dry "would copy $path -> $out ($desc)"
        return 0
    fi
    log "collecting $desc"
    {
        printf '### %s\n' "$desc"
        printf '### source: %s\n\n' "$path"
    } > "$REPORT/$out"
    if [ -r "$path" ]; then
        cat "$path" >> "$REPORT/$out" 2>&1 || printf '### (read failed)\n' >> "$REPORT/$out"
    else
        printf '### (not readable / does not exist)\n' >> "$REPORT/$out"
        warn "$desc: $path not readable"
    fi
    return 0
}

# --- filesystem superblock probe -------------------------------------------
# The stock image ships e2fsprogs-mke2fs and e2fsck but NOT dumpe2fs (see
# docs/HARDWARE-MEASURED.md), so every dumpe2fs call in this script is guarded
# and the run degrades one rung at a time instead of aborting:
#
#     dumpe2fs -h    best: label, block count, features, last mount time
#  -> e2fsck -n      present on the stock image; -n NEVER writes, and it is
#                    only run on an UNMOUNTED device
#  -> ext4_magic_ok  raw 0xEF53 at offset 0x438 via dd+od (omni-lib.sh)
#
# The rungs below dumpe2fs are used ONLY when dumpe2fs is absent, so a unit that
# HAS dumpe2fs keeps exactly the old pass/fail semantics.
#
# Results are cached per device under the run directory, so the read-only fsck
# runs at most once per partition even though the inventory loop and the gate
# section both ask.
#
# Sets FS_PROBE_STATE and FS_PROBE_DETAIL and ALWAYS returns 0 (the same
# well-known-global convention omni-lib.sh uses for _ENV_READBACK_BAD), so
# `set -e` can never fire on a probe result.
#
#   FS_PROBE_STATE = nodev     - not a block device
#                    validated - a real superblock reader confirmed it
#                    magic     - 0xEF53 present, but nothing validated it
#                    bad       - no readable ext2/3/4 superblock
FS_PROBE_STATE=""
FS_PROBE_DETAIL=""
fs_probe() {
    local dev="$1" cache raw out rc
    FS_PROBE_STATE="bad"
    FS_PROBE_DETAIL=""

    cache="$(omni_rundir)/fsprobe.${dev##*/}"
    raw="$cache.raw"
    if [ -r "$cache" ]; then
        {   IFS= read -r FS_PROBE_STATE  || FS_PROBE_STATE="bad"
            IFS= read -r FS_PROBE_DETAIL || FS_PROBE_DETAIL=""
        } < "$cache"
        return 0
    fi

    if [ ! -b "$dev" ]; then
        FS_PROBE_STATE="nodev"
        FS_PROBE_DETAIL="$dev is not a block device"
    elif have_cmd dumpe2fs; then
        set +e
        out=$(dumpe2fs -h "$dev" 2>&1)
        rc=$?
        set -e
        printf '%s\n' "$out" > "$raw" 2>/dev/null || true
        if [ "$rc" -eq 0 ]; then
            FS_PROBE_STATE="validated"
            FS_PROBE_DETAIL=$(printf '%s\n' "$out" | awk -F': *' '
                /^Filesystem volume name/ {vol=$2}
                /^Filesystem features/    {feat=$2}
                /^Block count/            {bc=$2}
                /^Last mount time/        {lmt=$2}
                END {printf "label=%s blocks=%s last_mount=%s feats=[%s]", (vol==""?"<none>":vol), bc, (lmt==""?"?":lmt), feat}')
        else
            FS_PROBE_DETAIL="dumpe2fs -h could not read a superblock (exit $rc)"
        fi
    elif have_cmd e2fsck && ! is_mounted "$dev"; then
        # -n answers "no" to every question, so this cannot write.  On a large
        # dirty filesystem it degenerates into a full read-only check, which is
        # slow but harmless.
        log "dumpe2fs is not installed; validating $dev with a read-only 'e2fsck -n' (this can take a minute)"
        set +e
        out=$(e2fsck -n "$dev" 2>&1)
        rc=$?
        set -e
        printf '%s\n' "$out" > "$raw" 2>/dev/null || true
        if [ "$rc" -eq 0 ]; then
            FS_PROBE_STATE="validated"
            FS_PROBE_DETAIL="e2fsck -n: $(printf '%s\n' "$out" | tail -n 1)"
        else
            FS_PROBE_DETAIL="e2fsck -n exited $rc"
        fi
    fi

    # Last rung, and the fall-through from a failed e2fsck.  Only reachable when
    # dumpe2fs is absent, so a unit that has dumpe2fs never downgrades to magic.
    if [ "$FS_PROBE_STATE" = "bad" ] && [ -b "$dev" ] && ! have_cmd dumpe2fs; then
        if ext4_magic_ok "$dev"; then
            FS_PROBE_STATE="magic"
            FS_PROBE_DETAIL="ext4 magic 0xEF53 present at offset 0x438, not validated${FS_PROBE_DETAIL:+ ($FS_PROBE_DETAIL)}"
        else
            FS_PROBE_DETAIL="no ext4 magic at offset 0x438${FS_PROBE_DETAIL:+ ($FS_PROBE_DETAIL)}"
        fi
    fi

    # The cache is one line of state plus one line of detail, so keep the detail
    # on a single line.
    FS_PROBE_DETAIL=$(printf '%s' "$FS_PROBE_DETAIL" | tr "$_OMNI_NL" ' ')
    printf '%s\n%s\n' "$FS_PROBE_STATE" "$FS_PROBE_DETAIL" > "$cache" 2>/dev/null || true
    return 0
}

# --- results table ---------------------------------------------------------
RESULT_LINES_FILE=""
FAIL_COUNT=0
record() {
    # record <id> <status> <detail>
    local id="$1" status="$2"; shift 2
    if [ -z "$RESULT_LINES_FILE" ]; then
        RESULT_LINES_FILE="$(omni_rundir)/results.txt"
        : > "$RESULT_LINES_FILE"
    fi
    printf '%s\t%s\t%s\n' "$id" "$status" "$*" >> "$RESULT_LINES_FILE"
    case "$status" in
        FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    esac
}

# ===========================================================================
banner "inventory"

have_cmd lsblk     && capture lsblk-b.txt        "lsblk -b"                  lsblk -b \
                   || record I0 SKIP "lsblk not installed"
have_cmd sfdisk    && capture sfdisk-dump.txt    "sfdisk -d $OMNI_EMMC"      sfdisk -d "$OMNI_EMMC" \
                   || record I1 SKIP "sfdisk not installed - PARTITION TABLE NOT CAPTURED"

if [ "$DRY_RUN" != "1" ]; then
    log "collecting block device sizes"
    {
        printf '### blockdev --getsize64, and /sys fallbacks\n\n'
        for d in "$OMNI_EMMC" "$OMNI_EMMC"boot0 "$OMNI_EMMC"boot1 \
                 "$OMNI_PART_PREFIX"1 "$OMNI_PART_PREFIX"2 "$OMNI_PART_PREFIX"3 \
                 "$OMNI_PART_PREFIX"4 "$OMNI_PART_PREFIX"5 "$OMNI_PART_PREFIX"6 \
                 "$OMNI_PART_PREFIX"7; do
            if [ -b "$d" ]; then
                sz=$(dev_size_bytes "$d" 2>/dev/null || printf '?')
                printf '%-26s %18s  %s\n' "$d" "$sz" "$(human_bytes "${sz:-0}" 2>/dev/null || printf '')"
            else
                printf '%-26s %18s\n' "$d" "(absent)"
            fi
        done
    } > "$REPORT/blockdev-sizes.txt"
else
    log_dry "would record blockdev --getsize64 for the disk and p1..p7 + boot0/boot1"
fi

capture_file proc-cmdline.txt "/proc/cmdline"     /proc/cmdline
capture_file meminfo.txt      "/proc/meminfo"     /proc/meminfo
capture_file partitions.txt   "/proc/partitions"  /proc/partitions
capture_file mounts.txt       "/proc/mounts"      /proc/mounts
capture_file interrupts.txt   "/proc/interrupts"  /proc/interrupts
capture mount.txt   "mount"        mount
capture uname.txt   "uname -a"     uname -a
capture df.txt      "df -kP"       df -kP
capture boot-listing.txt "ls -la /boot" ls -la /boot

if [ "$DRY_RUN" != "1" ]; then
    log "collecting tool inventory"
    {
        printf '### which of the tools this migration needs are present?\n\n'
        for t in fw_printenv fw_setenv dd sha256sum md5sum od awk sed sfdisk lsblk blockdev \
                 mkfs.ext4 mke2fs e2fsck dumpe2fs curl gzip xz zstd systemctl ethtool iperf3 fio \
                 ip mount umount findmnt stat mktemp devmem; do
            if command -v "$t" >/dev/null 2>&1; then
                printf '%-14s %s\n' "$t" "$(command -v "$t")"
            else
                printf '%-14s MISSING\n' "$t"
            fi
        done
        printf '\n### dd feature probe\n'
        dd --help 2>&1 | grep -E 'fullblock|fsync' || printf '(no fullblock/fsync in dd --help)\n'
    } > "$REPORT/tools.txt"
fi

# --- environment -----------------------------------------------------------
ENV_OK=0
if have_cmd fw_printenv; then
    ENV_OK=1
    capture fw_printenv.txt "fw_printenv | sort" sh -c 'fw_printenv 2>/dev/null | sort'
    capture_file fw_env_config.txt "$OMNI_FW_ENV_CONFIG" "$OMNI_FW_ENV_CONFIG"
else
    warn "fw_printenv is not installed - every environment gate will be UNKNOWN"
fi

# --- filesystems -----------------------------------------------------------
for p in 1 2 3 5 6 7; do
    d="$OMNI_PART_PREFIX$p"
    if have_cmd dumpe2fs; then
        capture "dumpe2fs-p$p.txt" "dumpe2fs -h $d" dumpe2fs -h "$d"
    else
        if [ "$DRY_RUN" != "1" ]; then
            log "collecting superblock probe for $d (dumpe2fs is not installed)"
            fs_probe "$d"
            {
                printf '### dumpe2fs is not installed on this image\n'
                printf '### read-only fallback probe on %s: e2fsck -n when the device is\n' "$d"
                printf '### unmounted, then the raw ext4 superblock magic (0xEF53 at 0x438)\n\n'
                printf 'state:  %s\n' "$FS_PROBE_STATE"
                printf 'detail: %s\n' "$FS_PROBE_DETAIL"
                if [ -r "$(omni_rundir)/fsprobe.${d##*/}.raw" ]; then
                    printf '\n### probe output\n'
                    cat "$(omni_rundir)/fsprobe.${d##*/}.raw"
                fi
            } > "$REPORT/dumpe2fs-p$p.txt"
        fi
    fi
done

# --- eMMC health -----------------------------------------------------------
DEBUG_MP=/sys/kernel/debug
if ! grep -q ' /sys/kernel/debug debugfs ' /proc/mounts 2>/dev/null; then
    if [ "$MOUNT_DEBUGFS" = "1" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            log_dry "would run: mount -t debugfs none /sys/kernel/debug"
        else
            log "mounting debugfs (will unmount on exit)"
            if mount -t debugfs none "$DEBUG_MP" 2>/dev/null; then
                DEBUGFS_MOUNTED_BY_US=1
            else
                warn "could not mount debugfs - mmc ios and ext_csd will be unavailable"
            fi
        fi
    else
        warn "debugfs is not mounted: /sys/kernel/debug/mmc0/ios and ext_csd cannot be read."
        warn "  Re-run with --mount-debugfs to mount it temporarily."
    fi
fi

capture_file mmc-ios.txt "eMMC bus state (timing spec, clock, width)" "$DEBUG_MP/mmc0/ios"

EXT_CSD_SRC=""
for c in "$DEBUG_MP"/mmc0/mmc0:*/ext_csd; do
    [ -r "$c" ] && { EXT_CSD_SRC="$c"; break; }
done
if [ -n "$EXT_CSD_SRC" ] && [ "$DRY_RUN" != "1" ]; then
    log "collecting ext_csd and decoding wear counters"
    RAW=$(cat "$EXT_CSD_SRC" 2>/dev/null | tr -d ' \n' || printf '')
    decode_ext_csd_byte() {
        # decode_ext_csd_byte <index> -> two hex chars.
        # bash's ${RAW:off:2} substring expansion has no POSIX equivalent;
        # awk substr() is exact, and awk is on the stock image.
        local off
        off=$(( $1 * 2 ))
        printf '%s' "$RAW" | awk -v o="$off" '{ printf "%s", substr($0, o + 1, 2) }'
    }
    PRE_EOL=$(decode_ext_csd_byte 267)
    LIFE_A=$(decode_ext_csd_byte 268)
    LIFE_B=$(decode_ext_csd_byte 269)
    describe_pre_eol() {
        case "$1" in
            00) printf 'not defined' ;;
            01) printf 'Normal (consumed < 80%% of reserved blocks)' ;;
            02) printf 'WARNING (consumed 80%% of reserved blocks)' ;;
            03) printf 'URGENT (consumed 90%% of reserved blocks)' ;;
            *)  printf 'unknown (0x%s)' "$1" ;;
        esac
    }
    describe_life() {
        case "$1" in
            00) printf 'not defined' ;;
            0b|0B) printf 'EXCEEDED its maximum estimated device lifetime' ;;
            *)
                case "$1" in
                    0[1-9]|0a|0A)
                        n=$(( 0x$1 ))
                        printf '%d%%-%d%% of device life used' "$(( (n - 1) * 10 ))" "$(( n * 10 ))"
                        ;;
                    *) printf 'unknown (0x%s)' "$1" ;;
                esac
                ;;
        esac
    }
    {
        printf '### ext_csd source: %s\n' "$EXT_CSD_SRC"
        printf '### JEDEC 5.0 byte offsets: 267 PRE_EOL_INFO, 268 LIFE_TIME_EST_TYP_A, 269 TYP_B\n\n'
        printf 'PRE_EOL_INFO            0x%s  %s\n' "${PRE_EOL:-??}" "$(describe_pre_eol "${PRE_EOL:-}")"
        printf 'DEVICE_LIFE_TIME_EST_A  0x%s  %s\n' "${LIFE_A:-??}" "$(describe_life "${LIFE_A:-}")"
        printf 'DEVICE_LIFE_TIME_EST_B  0x%s  %s\n' "${LIFE_B:-??}" "$(describe_life "${LIFE_B:-}")"
        printf '\n### raw ext_csd\n'
        printf '%s\n' "$RAW"
    } > "$REPORT/mmc-ext_csd.txt"
    log "ext_csd: pre_eol=0x${PRE_EOL:-??} life_a=0x${LIFE_A:-??} life_b=0x${LIFE_B:-??}"
    record I9 INFO "eMMC wear: PRE_EOL=0x${PRE_EOL:-??} ($(describe_pre_eol "${PRE_EOL:-}")), LIFE_A=0x${LIFE_A:-??} ($(describe_life "${LIFE_A:-}"))"
elif [ "$DRY_RUN" != "1" ]; then
    warn "ext_csd not readable (debugfs not mounted?) - eMMC wear UNKNOWN"
    record I9 MANUAL "eMMC wear unknown: mount debugfs and read $DEBUG_MP/mmc0/mmc0:*/ext_csd bytes 267-269"
fi

# ===========================================================================
banner "gate evaluation"

if [ "$DRY_RUN" = "1" ]; then
    log_dry "would evaluate P1-P8 against the collected inventory"
    log_dry "dry run complete - nothing written"
    exit 0
fi

# --- P1 --------------------------------------------------------------------
if [ "$ENV_OK" = "1" ]; then
    MFC=$(env_get force_run_mfc 2>/dev/null || printf '<undefined>')
    EOL=$(env_get force_run_eol 2>/dev/null || printf '<undefined>')
    if [ "$MFC" = "0" ] && [ "$EOL" = "0" ]; then
        record P1 PASS "force_run_mfc=0 force_run_eol=0"
    else
        record P1 FAIL "force_run_mfc=$MFC force_run_eol=$EOL (must both be 0; compiled defaults are 1 and APOLLO_CHECK_MFC forces p7 ahead of A/B selection)"
    fi
else
    record P1 MANUAL "fw_printenv missing - check force_run_mfc / force_run_eol by hand"
fi

# --- P2 (RESTATED) ---------------------------------------------------------
# The original gate ("no stored bootargs at all") fails on a healthy unit: the
# measured device stores patch 0039's fixed common cmdline,
# bootargs="rootwait rw console=ttyAML0", which carries no root=.  Every boot
# MENDER_BOOTARGS does  setenv bootargs root=${mender_kernel_root} ${bootargs},
# so the real invariant is that the STORED value contains no root= of its own -
# the last root= wins, and a stored one would boot a slot's kernel against the
# other slot's rootfs.  See docs/HARDWARE-MEASURED.md, "Why P2 needs restating".
if [ "$ENV_OK" = "1" ]; then
    if env_defined bootargs; then
        BA=$(env_get bootargs 2>/dev/null || printf '')
        # Match root= only on a token boundary, so "rootwait", "rootfstype=" and
        # "mender_kernel_root=" are not mistaken for it.  Tabs count as
        # separators too, hence the tr.
        BA_TOK=" $(printf '%s' "$BA" | tr "$_OMNI_TAB" ' ')"
        case "$BA_TOK" in
            *" root="*)
                record P2 FAIL "the stored 'bootargs' contains a root= assignment: '$BA'. MENDER_BOOTARGS prepends root=\${mender_kernel_root}; the LAST root= wins, so this can boot one slot's kernel against the other slot's rootfs"
                ;;
            *)
                record P2 PASS "the stored 'bootargs' contains no root= ('$BA') - MENDER_BOOTARGS prepends root=\${mender_kernel_root} at boot"
                ;;
        esac
    else
        record P2 PASS "no stored 'bootargs'"
    fi
else
    record P2 MANUAL "fw_printenv missing - check 'fw_printenv bootargs' by hand; it must contain no root="
fi

# --- P3 --------------------------------------------------------------------
if [ "$ENV_OK" = "1" ]; then
    ETH=$(env_get ethaddr 2>/dev/null || printf '')
    if [ -n "$ETH" ]; then
        LIVE=""
        for m in /sys/class/net/*/address; do
            [ -r "$m" ] || continue
            case "$m" in */lo/*) continue ;; esac
            LIVE="$LIVE $(basename -- "$(dirname -- "$m")")=$(cat "$m")"
        done
        record P3 PASS "ethaddr=$ETH (live:$LIVE). MAC stability over 3 reboots is still MANUAL - see below"
    else
        record P3 FAIL "ethaddr is empty or undefined. check_env is dead code (patch 0031 replaces bootcmd with CONFIG_MENDER_BOOTCOMMAND), so it will never self-heal, and CONFIG_NET_RANDOM_ETHADDR then gives a new MAC every boot, forever"
    fi
else
    record P3 MANUAL "fw_printenv missing - check 'fw_printenv ethaddr' by hand"
fi

# --- P4 --------------------------------------------------------------------
if [ "$ENV_OK" = "1" ]; then
    KN=$(env_get mender_kernel_name  2>/dev/null || printf '')
    DN=$(env_get mender_dtb_name     2>/dev/null || printf '')
    RN=$(env_get mender_ramdisk_name 2>/dev/null || printf '')
    if [ -n "$KN" ] && [ -n "$DN" ] && [ -n "$RN" ]; then
        {
            printf '# Captured verbatim from the STORED U-Boot environment on %s\n' "$(_omni_stamp)"
            printf '# by omni-preflight.sh.  NEVER retype these from the U-Boot patches:\n'
            printf '# a field binary may predate patches 0050/0051.\n'
            printf '#\n'
            printf '# These three names are GLOBAL, not per-slot.  Both slots must expose\n'
            printf '# real files (cp -f, never ln) at exactly these paths under /boot.\n'
            printf '#\n'
            printf '# Consumed by /etc/kernel/postinst.d/zz-omni-flatten and\n'
            printf '# /etc/initramfs/post-update.d/99-omni-flatten on the Debian rootfs.\n'
            printf 'OMNI_KERNEL_NAME=%s\n'  "$KN"
            printf 'OMNI_DTB_NAME=%s\n'     "$DN"
            printf 'OMNI_RAMDISK_NAME=%s\n' "$RN"
        } > "$REPORT/boot-names.env"
        record P4 PASS "kernel='$KN' dtb='$DN' ramdisk='$RN' (captured to boot-names.env)"

        # Do the artefacts actually exist on the running slot?
        MISS=""
        for n in "$KN" "$DN" "$RN"; do
            [ -s "/boot/$n" ] || MISS="$MISS /boot/$n"
        done
        if [ -n "$MISS" ]; then
            record I4 FAIL "the RUNNING slot is missing:$MISS"
        else
            record I4 PASS "all three artefacts present and non-empty under /boot on the running slot"
        fi
    else
        record P4 FAIL "one or more of mender_kernel_name/mender_dtb_name/mender_ramdisk_name is undefined (got '$KN' / '$DN' / '$RN')"
    fi
else
    record P4 MANUAL "fw_printenv missing - capture the three mender_*_name values by hand"
fi

# --- P8 --------------------------------------------------------------------
P2DEV="$OMNI_PART_PREFIX$OMNI_SLOT_B"
fs_probe "$P2DEV"
case "$FS_PROBE_STATE" in
    nodev)
        record P8 FAIL "$P2DEV does not exist"
        ;;
    validated)
        record P8 PASS "$P2DEV holds a readable ext superblock: $FS_PROBE_DETAIL"
        ;;
    magic)
        record P8 WARN "$P2DEV has the ext4 magic at 0x438, but dumpe2fs is not installed so the superblock was not validated. Install e2fsprogs-dumpe2fs and re-run"
        ;;
    *)
        if have_cmd dumpe2fs; then
            record P8 FAIL "$P2DEV has no readable ext2/3/4 superblock. Nothing ever set upgrade_available=1 on this unit (no mender daemon is installed), so slot B has very likely never been written - it may be zeros"
        else
            record P8 FAIL "$P2DEV has no ext4 magic at offset 0x438 - slot B looks empty/zeroed"
        fi
        ;;
esac

# --- informational env checks ---------------------------------------------
if [ "$ENV_OK" = "1" ]; then
    BP=$(env_get_or mender_boot_part '<undefined>')
    BPH=$(env_get_or mender_boot_part_hex '<undefined>')
    BC=$(env_get_or bootcount '<undefined>')
    BL=$(env_get_or bootlimit '<undefined>')
    UA=$(env_get_or upgrade_available '<undefined>')
    BD=$(env_get_or bootdelay '<undefined>')
    CW=$(env_get_or check_watchdog '<undefined>')
    FHR=$(env_get_or force_hard_recovery '<undefined>')

    record I1 INFO "mender_boot_part=$BP mender_boot_part_hex=$BPH upgrade_available=$UA bootcount=$BC bootlimit=$BL"

    if [ "$UA" != "0" ]; then
        record I2 FAIL "upgrade_available=$UA - this unit is sitting in an ARMED window right now. Commit it (omni-commit.sh) or roll it back before doing anything else"
    else
        record I2 PASS "upgrade_available=0 - not armed"
    fi

    if env_defined altbootcmd; then
        record I3 PASS "altbootcmd IS present in the stored env"
    else
        record I3 WARN "altbootcmd is NOT in the stored env. U-Boot falls back to the compiled MENDER_DEFAULT_ALTBOOTCMD, but Phase 1 must prove on serial that 'Warning: Bootlimit (N) exceeded. Using altbootcmd.' really appears"
    fi

    if [ "$BL" = "<undefined>" ]; then
        record I5 WARN "bootlimit is not in the stored env (compiled default is 1)"
    else
        record I5 PASS "bootlimit=$BL"
    fi

    case "$BD" in
        '<undefined>') record I6 FAIL "bootdelay is not defined. The compiled default on this build is -2, and abortboot() in v2018.09 only prompts when bootdelay >= 0, so you have NO serial '=>' prompt on a successful boot. Fix it: echo 0 > /sys/block/mmcblk0boot0/force_ro; fw_setenv bootdelay 3; echo 1 > /sys/block/mmcblk0boot0/force_ro" ;;
        -*)            record I6 FAIL "bootdelay=$BD (<0). abortboot() never prompts, so there is no '=>' prompt on a normal boot - recovery ladder rank 1 is unavailable. Set it to 3 before arming anything" ;;
        *)             record I6 PASS "bootdelay=$BD - the serial '=>' prompt is reachable" ;;
    esac

    case "$CW" in
        false) record I7 PASS "check_watchdog=false - a watchdog reset will NOT divert to recovery" ;;
        '<undefined>') record I7 WARN "check_watchdog is not in the stored env; the compiled default reads 0xff80023c and forces p$OMNI_RECOVERY_PART ahead of A/B. Characterise with P5" ;;
        *) record I7 WARN "check_watchdog='$CW' - a latched 0xff80023c==0xd000 forces p$OMNI_RECOVERY_PART ahead of A/B selection, and altbootcmd re-enters bootcmd, so bootcount rollback cannot escape it. Consider setting it to false for the duration of the migration" ;;
    esac

    case "$FHR" in
        1) record I8 FAIL "force_hard_recovery=1 - the next boot goes to p$OMNI_RECOVERY_PART regardless of mender_boot_part" ;;
        *) record I8 PASS "force_hard_recovery=$FHR" ;;
    esac
fi

# --- is p7 populated? ------------------------------------------------------
P7DEV="$OMNI_PART_PREFIX$OMNI_RECOVERY_PART"
fs_probe "$P7DEV"
case "$FS_PROBE_STATE" in
    nodev)
        record I10 FAIL "$P7DEV does not exist - recovery ladder rank 2 and 3 are both unavailable"
        ;;
    validated)
        record I10 PASS "$P7DEV holds a readable ext superblock (see dumpe2fs-p7.txt). Whether it BOOTS is P6 - manual"
        ;;
    magic)
        record I10 WARN "$P7DEV has the ext4 magic but was not validated (no dumpe2fs). Whether it BOOTS is P6 - manual"
        ;;
    *)
        record I10 FAIL "$P7DEV has no ext4 magic. Nothing in this repo builds p7 or apollo-mfc-initrd-image-*. If p7 is empty, recovery is serial-only: populate it with a copy of p1 before proceeding (pre-flight P6)"
        ;;
esac

# --- 0xff80023c, best effort ----------------------------------------------
if have_cmd devmem; then
    if V=$(devmem 0xff80023c 16 2>/dev/null); then
        record I11 INFO "0xff80023c currently reads $V from Linux (informational only - P5 must be done from U-Boot, across six reset types)"
    fi
fi

# ===========================================================================
# SUMMARY
# ===========================================================================
SUMMARY="$REPORT/SUMMARY.txt"
{
    printf 'Avast Omni - Phase 0 pre-flight\n'
    printf 'generated %s by omni-preflight.sh\n' "$(_omni_stamp)"
    printf 'report directory: %s\n' "$REPORT"
    printf 'running slot: %s\n' "$(describe_running_slot)"
    printf '\n'
    printf '%-5s %-7s %s\n' "ID" "STATUS" "DETAIL"
    printf '%s\n' "---------------------------------------------------------------------------"
    if [ -n "$RESULT_LINES_FILE" ] && [ -r "$RESULT_LINES_FILE" ]; then
        while IFS="$_OMNI_TAB" read -r id status detail; do
            printf '%-5s %-7s %s\n' "$id" "$status" "$detail"
        done < "$RESULT_LINES_FILE"
    fi
    printf '\n'
    printf 'CHECKS THAT CANNOT BE EVALUATED WITHOUT SERIAL AND A POWER CYCLE\n'
    printf '%s\n' "---------------------------------------------------------------------------"
    cat <<EOF

P5  MANUAL - where does a watchdog reset land?
    Serial console on ttyAML0 (3.3 V USB-TTL, case open) is a hard prerequisite.
    You need a "=>" prompt, so bootdelay must be >= 0 first (see I6 above).

    At the "=>" prompt, read the latch after EACH of these six events, and
    record the value every time:

        md.w 0xff80023c 1

      1. cold power-on (mains removed >= 10 s)
      2. "reset" typed at the "=>" prompt
      3. "reboot" from Linux
      4. a forced watchdog bite from Linux, e.g.:
             systemctl stop <anything petting /dev/watchdog>
             # or provoke a hard hang; RuntimeWatchdogSec=10 is live today
      5. a cold power cut while Linux is running
      6. reset-button press

    PASS means the latch reads 0xd000 ONLY after the watchdog bite (4).
    If a plain reboot or a power cut also latches it, EVERY subsequent boot is
    diverted to p$OMNI_RECOVERY_PART ahead of A/B selection, altbootcmd re-enters bootcmd and
    re-evaluates it, and the whole rollback model changes.  Do not arm anything
    until you know.

P6  MANUAL - does a reset-button cold boot reach a usable shell on p$OMNI_RECOVERY_PART?
    Hold the reset button (GPIOAO_10, active low) and power on.  U-Boot reads
    the button as a raw register (setexpr button *0xff800028 & 0x400), so Linux
    has no say in it.  Expected: bootargs gains "init=/init factory_reset" and
    mender_boot_part becomes $OMNI_RECOVERY_PART.

    PASS means you get a usable shell.  Nothing in this repo builds p$OMNI_RECOVERY_PART or
    apollo-mfc-initrd-image-*, so if p$OMNI_RECOVERY_PART is empty, recovery is serial-only.
    In that case populate p$OMNI_RECOVERY_PART with a copy of p1 BEFORE proceeding.

    While you are at the prompt, also settle the open question:
        setexpr b *0xff800028 & 0x400
    If setexpr is missing, this binary predates patch 0041 and the reset button
    does nothing at all.

P7  MANUAL - the environment restore drill.  Do this BEFORE arming anything.
    The environment is ONE non-redundant 8 KB copy at offset 0 of
    /dev/mmcblk0boot0.  0x2000 bytes = 0x10 blocks of 512 B.

    1. Take the backup first (omni-backup.sh gives you omni-boot0.img).
    2. Deliberately corrupt the stored env (from Linux, with force_ro toggled).
    3. Power-cycle and prove you can restore it from the "=>" prompt alone:

           loady 0x08000000          # ymodem the first 8 KB of omni-boot0.img
           # (or: tftp 0x08000000 omni-env-8k.bin)
           mmc dev 0 1               # 1 = the boot0 hardware partition
           mmc write 0x08000000 0 0x10
           reset

    PASS means you restored a working environment with no working rootfs.
    If you cannot do this, do not arm anything - a torn write to that single
    8 KB copy is otherwise unrecoverable in-band, and U-Boot's own recovery
    (env default -a; saveenv) restores force_run_mfc=1, which wants a file this
    repo cannot build.

P3 (second half)  MANUAL - MAC stability.
    Reboot three times and confirm the MAC never changes.  ethaddr has no
    self-heal on this build.

NEXT STEPS
    * fix every FAIL above before Phase 1
    * if I6 is a FAIL, regain the "=>" prompt (AFTER omni-backup.sh has run):
          echo 0 > /sys/block/mmcblk0boot0/force_ro
          fw_setenv bootdelay 3
          echo 1 > /sys/block/mmcblk0boot0/force_ro
          fw_printenv bootdelay        # read back and assert
    * copy this whole report directory off the device
EOF
} > "$SUMMARY"

cat "$SUMMARY"
log "report written to $REPORT"
log "summary: $SUMMARY"

if [ "$FAIL_COUNT" -gt 0 ]; then
    err "$FAIL_COUNT automatic check(s) FAILED"
    [ "$IGNORE_FAIL" = "1" ] && { warn "--ignore-fail: exiting 0 anyway"; exit 0; }
    exit 1
fi
ok "all automatic checks passed (the MANUAL ones above are still owed)"
exit 0

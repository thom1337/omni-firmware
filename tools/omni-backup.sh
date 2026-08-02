#!/bin/bash
#
# omni-backup.sh - Phase 0 backup of an Avast Omni, taken from the WORKSTATION
# over ssh.
#
# THIS IS THE FIRST THING YOU RUN, BEFORE ANY fw_setenv.  The U-Boot environment
# is ONE non-redundant 8 KB copy at offset 0 of /dev/mmcblk0boot0, and it holds
# the only surviving copy of ethaddr on the unit - there is no self-heal
# (check_env is dead code, patch 0031 replaces bootcmd with
# CONFIG_MENDER_BOOTCOMMAND, so it is never invoked).  Lose it and
# CONFIG_NET_RANDOM_ETHADDR hands out a new MAC every boot, forever.
#
# Order is the plan's order and it matters:
#   1. partition table   2. environment   3. boot0 + boot1   4. full eMMC
#   5. verify the full image against the device
#
set -euo pipefail

OMNI_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=omni-lib.sh
. "${OMNI_LIB:-$OMNI_DIR/omni-lib.sh}"

PROG=omni-backup.sh

usage() {
    cat <<'EOF'
omni-backup.sh - Phase 0 backup of an Avast Omni, over ssh, from the workstation

USAGE
  omni-backup.sh <ssh-target> [options]

  <ssh-target> is anything ssh understands: "root@omni", "omni", "root@10.0.0.5".
  It must accept a NON-INTERACTIVE login: this script always passes
  BatchMode=yes, so a password prompt is a hard failure, not a hang.  Set up a
  key first.

WHAT IT PRODUCES  (in <outdir>/omni-backup-<host>-<YYYYmmdd-HHMMSS>/)
  omni-ptable.sfdisk     sfdisk -d /dev/mmcblk0            - the partition table
  omni-env.txt           fw_printenv | sort                - ONLY copy of ethaddr
  omni-env-8k.bin        the first 8 KB of boot0           - what you restore at "=>"
  omni-boot0.img         ALL of /dev/mmcblk0boot0          - not just the env
  omni-boot1.img         ALL of /dev/mmcblk0boot1
  omni-emmc-full.img.gz  the whole eMMC user area, gzip -1
  omni-inventory.txt     lsblk, sizes, /proc/cmdline, mount, ls -la /boot
  SHA256SUMS             sha256 of every local artefact
  MD5-VERIFY.txt         the eMMC image md5 vs the device's own md5
  RESTORE-CHEATSHEET.txt the restore recipes, also printed at the end

ORDER
  Backup happens BEFORE any environment write.  Nothing in this script writes
  to the device - not one byte, not even force_ro.

OPTIONS
  --outdir DIR       parent directory (default ./omni-backups)
  --name NAME        use <outdir>/NAME instead of the generated dated name
  --ssh-opts "..."   extra ssh options (appended after the built-in ones)
  --no-remote-gzip   pipe the raw eMMC over ssh and compress locally.  Use this
                     when the box's CPU is the bottleneck and the link is fast.
  --skip-full        skip the full eMMC image (fast partial backup).  The md5
                     verification is skipped with it.  NOT sufficient for Phase 0.
  --allow-tight      accept a local filesystem with less free space than the
                     eMMC's full size (gzip -1 usually wins big on a mostly
                     empty eMMC, but "usually" is not a backup strategy)
  --quiesce          stop docker/containerd/syslog-ng on the device for the
                     duration, and start them again afterwards.  Reduces the
                     chance that the eMMC changes under you between the image
                     and the md5 (which would show up as a false mismatch).
  --dry-run          print every command that would run; create nothing
  -h, --help         this text

REFUSES TO OVERWRITE
  If the target directory already exists and is non-empty, the script stops.
  A backup you silently overwrote is not a backup.

EXIT STATUS
  0  complete and verified          1  refused / failed / md5 mismatch
EOF
}

TARGET_HOST=""
OUTDIR="./omni-backups"
NAME=""
EXTRA_SSH_OPTS=""
REMOTE_GZIP=1
SKIP_FULL=0
ALLOW_TIGHT=0
QUIESCE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --outdir)         [ $# -ge 2 ] || die "--outdir needs a value"; OUTDIR="$2"; shift 2 ;;
        --outdir=*)       OUTDIR="${1#*=}"; shift ;;
        --name)           [ $# -ge 2 ] || die "--name needs a value"; NAME="$2"; shift 2 ;;
        --name=*)         NAME="${1#*=}"; shift ;;
        --ssh-opts)       [ $# -ge 2 ] || die "--ssh-opts needs a value"; EXTRA_SSH_OPTS="$2"; shift 2 ;;
        --ssh-opts=*)     EXTRA_SSH_OPTS="${1#*=}"; shift ;;
        --no-remote-gzip) REMOTE_GZIP=0; shift ;;
        --skip-full)      SKIP_FULL=1; shift ;;
        --allow-tight)    ALLOW_TIGHT=1; shift ;;
        --quiesce)        QUIESCE=1; shift ;;
        --dry-run)        DRY_RUN=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        -*) err "unknown option: $1"; usage >&2; exit 1 ;;
        *)
            [ -z "$TARGET_HOST" ] || die "more than one ssh target given ('$TARGET_HOST' and '$1')"
            TARGET_HOST="$1"; shift
            ;;
    esac
done

[ -n "$TARGET_HOST" ] || { usage >&2; die "an ssh target is required (e.g. root@omni)"; }

banner "$PROG"
[ "$DRY_RUN" = "1" ] && log "DRY RUN - nothing will be created"

need_cmd ssh
need_cmd gzip
need_cmd sha256sum
need_cmd awk
need_cmd df

SSH_BASE="-o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=8"

rsh() {
    # rsh <remote command string>  - stdout is the remote stdout
    # shellcheck disable=SC2086
    ssh $SSH_BASE $EXTRA_SSH_OPTS "$TARGET_HOST" "$@"
}

rsh_q() {
    # quiet variant used for probes; never fails the script
    # shellcheck disable=SC2086
    ssh $SSH_BASE $EXTRA_SSH_OPTS "$TARGET_HOST" "$@" 2>/dev/null || true
}

# --- connectivity ----------------------------------------------------------
log "testing non-interactive ssh to $TARGET_HOST"
if [ "$DRY_RUN" = "1" ]; then
    log_dry "would run: ssh $SSH_BASE $EXTRA_SSH_OPTS $TARGET_HOST 'id -u; uname -a'"
    REMOTE_UID=0
    REMOTE_UNAME="(dry run)"
else
    REMOTE_ID=$(rsh 'id -u; uname -a' ) || die "ssh to $TARGET_HOST failed (BatchMode=yes: is your key installed?)"
    REMOTE_UID=$(printf '%s\n' "$REMOTE_ID" | head -n1)
    REMOTE_UNAME=$(printf '%s\n' "$REMOTE_ID" | sed -n '2p')
    [ "$REMOTE_UID" = "0" ] || die "remote uid is $REMOTE_UID; this backup needs root (raw block device reads)"
    ok "connected: $REMOTE_UNAME"
fi

# --- remote tool + geometry probe -----------------------------------------
log "probing the device"
if [ "$DRY_RUN" = "1" ]; then
    # Assume everything is present so the dry run shows the complete plan.
    REMOTE_TOOLS='sfdisk=yes fw_printenv=yes dd=yes gzip=yes md5sum=yes sha256sum=yes blockdev=yes lsblk=yes'
else
    REMOTE_TOOLS=$(rsh_q 'for t in sfdisk fw_printenv dd gzip md5sum sha256sum blockdev lsblk; do
                            if command -v $t >/dev/null 2>&1; then echo "$t=yes"; else echo "$t=no"; fi
                          done')
fi
if [ "$DRY_RUN" != "1" ]; then
    printf '%s\n' "$REMOTE_TOOLS" | sed 's/^/    /' >&2
    case "$REMOTE_TOOLS" in *"dd=no"*) die "the device has no dd - cannot image it" ;; esac
    case "$REMOTE_TOOLS" in *"sfdisk=no"*) warn "the device has no sfdisk - the partition table will not be captured" ;; esac
    case "$REMOTE_TOOLS" in *"fw_printenv=no"*) warn "the device has no fw_printenv - the env text dump will be empty (the raw boot0 image still captures it)" ;; esac
fi

REMOTE_HASH=md5sum
case "$REMOTE_TOOLS" in
    *"md5sum=no"*)
        case "$REMOTE_TOOLS" in
            *"sha256sum=yes"*) REMOTE_HASH=sha256sum; warn "no md5sum on the device; verifying with sha256sum instead" ;;
            *) REMOTE_HASH=""; warn "the device has neither md5sum nor sha256sum - the full-image verification will be SKIPPED" ;;
        esac
        ;;
esac
LOCAL_HASH="$REMOTE_HASH"
if [ -n "$LOCAL_HASH" ]; then
    have_cmd "$LOCAL_HASH" || { warn "$LOCAL_HASH not available locally - verification skipped"; REMOTE_HASH=""; }
fi

EMMC_SIZE=0
if [ "$DRY_RUN" != "1" ]; then
    EMMC_SIZE=$(rsh_q "blockdev --getsize64 $OMNI_EMMC" | tr -d '\r\n ' || printf '')
    case "$EMMC_SIZE" in
        ''|*[!0-9]*)
            EMMC_SIZE=$(rsh_q "awk '\$4 == \"mmcblk0\" {print \$3 * 1024}' /proc/partitions" | tr -d '\r\n ' || printf '0')
            ;;
    esac
    case "$EMMC_SIZE" in ''|*[!0-9]*) EMMC_SIZE=0 ;; esac
    if [ "$EMMC_SIZE" -gt 0 ]; then
        ok "eMMC user area: $(human_bytes "$EMMC_SIZE") ($EMMC_SIZE bytes)"
    else
        warn "could not determine the eMMC size; free-space checks will be advisory only"
    fi
fi

HAS_BOOT1=1
if [ "$DRY_RUN" != "1" ]; then
    rsh_q "test -b ${OMNI_EMMC}boot1 && echo yes" | grep -q yes || {
        HAS_BOOT1=0
        warn "${OMNI_EMMC}boot1 does not exist on the device - skipping that dump"
    }
fi

# --- destination directory -------------------------------------------------
HOSTTAG=$(printf '%s' "$TARGET_HOST" | tr -c 'A-Za-z0-9._-' '-' )
STAMP=$(date '+%Y%m%d-%H%M%S')
[ -n "$NAME" ] || NAME="omni-backup-$HOSTTAG-$STAMP"
DEST="$OUTDIR/$NAME"

if [ -e "$DEST" ]; then
    if [ -d "$DEST" ] && [ -z "$(ls -A "$DEST" 2>/dev/null)" ]; then
        log "$DEST exists but is empty - reusing it"
    else
        err "$DEST already exists and is not empty."
        err "  Refusing to overwrite an existing backup set.  Use --name or --outdir."
        die "destination not empty"
    fi
fi

if [ "$DRY_RUN" = "1" ]; then
    log_dry "would create $DEST"
else
    mkdir -p "$DEST" || die "cannot create $DEST"
    log_open "$DEST/backup.log"
    log "destination: $DEST"
fi

# --- free space ------------------------------------------------------------
if [ "$DRY_RUN" != "1" ] && [ "$EMMC_SIZE" -gt 0 ] && [ "$SKIP_FULL" = "0" ]; then
    AVAIL_KB=$(df -kP "$DEST" | awk 'NR==2 {print $4; exit}')
    AVAIL=$(( AVAIL_KB * 1024 ))
    log "local free space at $DEST: $(human_bytes "$AVAIL")"
    if [ "$AVAIL" -lt "$EMMC_SIZE" ]; then
        if [ "$ALLOW_TIGHT" = "1" ]; then
            MIN=$(( EMMC_SIZE / 4 ))
            [ "$AVAIL" -ge "$MIN" ] || die "only $(human_bytes "$AVAIL") free; even --allow-tight wants $(human_bytes "$MIN")"
            warn "--allow-tight: $(human_bytes "$AVAIL") free vs $(human_bytes "$EMMC_SIZE") of eMMC."
            warn "  gzip -1 usually shrinks a mostly-empty eMMC a lot, but if it does not,"
            warn "  this backup will fail part-way through."
        else
            err "only $(human_bytes "$AVAIL") free, but the eMMC is $(human_bytes "$EMMC_SIZE")."
            err "  gzip -1 will very probably shrink it, but the worst case is 1:1."
            err "  Free some space, choose another --outdir, or pass --allow-tight."
            die "not enough local free space"
        fi
    fi
fi

# --- quiesce (optional) ----------------------------------------------------
QUIESCED_UNITS=""
unquiesce() {
    [ -n "$QUIESCED_UNITS" ] || return 0
    local u rev=""
    for u in $QUIESCED_UNITS; do rev="$u $rev"; done
    log "restarting on the device: $rev"
    for u in $rev; do
        rsh_q "systemctl start $u" >/dev/null || warn "could not restart $u on the device"
    done
    QUIESCED_UNITS=""
}
backup_cleanup() {
    local rc=$?
    set +e
    unquiesce
    omni_rundir_cleanup
    if [ "$rc" -ne 0 ]; then
        err "backup did not complete cleanly (exit $rc)"
        err "Treat everything in $DEST as INCOMPLETE.  Do not make any"
        err "environment write on the device until you have a verified backup."
    fi
    return $rc
}
trap backup_cleanup EXIT

if [ "$QUIESCE" = "1" ]; then
    banner "quiesce the device"
    for u in docker.socket docker.service containerd.service syslog-ng.service; do
        if [ "$DRY_RUN" = "1" ]; then
            log_dry "would run (remote): systemctl is-active --quiet $u && systemctl stop $u"
            continue
        fi
        if rsh_q "systemctl is-active --quiet $u && echo active" | grep -q active; then
            log "stopping $u on the device"
            if rsh_q "systemctl stop $u" >/dev/null; then
                QUIESCED_UNITS="$QUIESCED_UNITS $u"
            else
                warn "could not stop $u"
            fi
        fi
    done
    if [ "$DRY_RUN" != "1" ]; then
        rsh_q 'sync' >/dev/null || true
        [ -n "$QUIESCED_UNITS" ] && ok "stopped:$QUIESCED_UNITS" || log "nothing needed stopping"
    fi
fi

# --- collection helpers ----------------------------------------------------
grab() {
    # grab <local-name> <description> <remote command>
    # Writes to <name>.part first and renames only on success, so a partial
    # transfer can never masquerade as a complete artefact.
    local name="$1" desc="$2" cmd="$3"
    local out="$DEST/$name"
    if [ "$DRY_RUN" = "1" ]; then
        log_dry "would run: ssh $TARGET_HOST '$cmd' > $out"
        return 0
    fi
    log "$desc  ->  $name"
    if rsh "$cmd" > "$out.part"; then
        mv -f -- "$out.part" "$out"
        ok "$name  $(human_bytes "$(wc -c < "$out")")"
        return 0
    fi
    rm -f -- "$out.part"
    return 1
}

# ===========================================================================
banner "1/5  partition table"
case "$REMOTE_TOOLS" in
    *"sfdisk=yes"*) grab omni-ptable.sfdisk "sfdisk -d $OMNI_EMMC" "sfdisk -d $OMNI_EMMC" \
                        || die "could not dump the partition table" ;;
    *) warn "skipping the partition table (no sfdisk on the device)" ;;
esac

banner "2/5  U-Boot environment (text)"
case "$REMOTE_TOOLS" in
    *"fw_printenv=yes"*)
        grab omni-env.txt "fw_printenv | sort" 'fw_printenv 2>/dev/null | sort' \
            || die "could not dump the environment"
        if [ "$DRY_RUN" != "1" ]; then
            if grep -q '^ethaddr=' "$DEST/omni-env.txt" 2>/dev/null; then
                ok "ethaddr captured: $(grep '^ethaddr=' "$DEST/omni-env.txt")"
            else
                warn "NO ethaddr in the stored environment.  There is no self-heal on this"
                warn "  build (check_env is dead code), so the MAC is already random per boot."
            fi
            for v in mender_kernel_name mender_dtb_name mender_ramdisk_name mender_boot_part; do
                grep "^$v=" "$DEST/omni-env.txt" >&2 || warn "$v is not in the stored env"
            done
        fi
        ;;
    *) warn "skipping the text env dump (no fw_printenv on the device)" ;;
esac

banner "3/5  eMMC boot partitions"
grab omni-boot0.img "dd if=${OMNI_EMMC}boot0 bs=1M (ALL of it, not just the 8 KB env)" \
     "dd if=${OMNI_EMMC}boot0 bs=1M 2>/dev/null" \
    || die "could not dump ${OMNI_EMMC}boot0 - this is the environment; do not proceed without it"

if [ "$DRY_RUN" != "1" ] && [ -s "$DEST/omni-boot0.img" ]; then
    # The exact 8 KB you would push back with "mmc write ... 0 0x10" at "=>".
    dd if="$DEST/omni-boot0.img" of="$DEST/omni-env-8k.bin" bs=8192 count=1 2>/dev/null \
        && ok "omni-env-8k.bin  (offset 0, 0x2000 bytes = 0x10 blocks of 512)" \
        || warn "could not slice omni-env-8k.bin out of omni-boot0.img"
fi

if [ "$HAS_BOOT1" = "1" ]; then
    grab omni-boot1.img "dd if=${OMNI_EMMC}boot1 bs=1M" \
         "dd if=${OMNI_EMMC}boot1 bs=1M 2>/dev/null" \
        || warn "could not dump ${OMNI_EMMC}boot1 (continuing)"
fi

banner "4/5  inventory"
grab omni-inventory.txt "lsblk / sizes / cmdline / mount / ls -la /boot" '
    echo "=== uname -a ==="; uname -a
    echo; echo "=== /proc/cmdline ==="; cat /proc/cmdline
    echo; echo "=== lsblk -b ==="; lsblk -b 2>/dev/null || echo "(no lsblk)"
    echo; echo "=== blockdev --getsize64 ==="
    for d in /dev/mmcblk0 /dev/mmcblk0boot0 /dev/mmcblk0boot1 /dev/mmcblk0p1 /dev/mmcblk0p2 \
             /dev/mmcblk0p3 /dev/mmcblk0p4 /dev/mmcblk0p5 /dev/mmcblk0p6 /dev/mmcblk0p7; do
        if [ -b "$d" ]; then printf "%-24s %s\n" "$d" "$(blockdev --getsize64 $d 2>/dev/null || echo ?)"; fi
    done
    echo; echo "=== /proc/partitions ==="; cat /proc/partitions
    echo; echo "=== mount ==="; mount
    echo; echo "=== df -kP ==="; df -kP
    echo; echo "=== ls -la /boot ==="; ls -la /boot
    echo; echo "=== /sys/kernel/debug/mmc0/ios ==="; cat /sys/kernel/debug/mmc0/ios 2>/dev/null || echo "(debugfs not mounted)"
' || warn "inventory collection failed (continuing)"

banner "5/5  full eMMC image"
VERIFIED=skipped
[ "$DRY_RUN" = "1" ] && VERIFIED="(dry run - not taken)"
if [ "$SKIP_FULL" = "1" ]; then
    warn "--skip-full: the full eMMC image was NOT taken.  This backup is NOT sufficient"
    warn "  for Phase 0 - phase 9's rollback of last resort is omni-emmc-full.img.gz."
else
    if [ "$DRY_RUN" = "1" ]; then
        if [ "$REMOTE_GZIP" = "1" ]; then
            log_dry "would run: ssh $TARGET_HOST 'dd if=$OMNI_EMMC bs=4M | gzip -1' > $DEST/omni-emmc-full.img.gz"
        else
            log_dry "would run: ssh $TARGET_HOST 'dd if=$OMNI_EMMC bs=4M' | gzip -1 > $DEST/omni-emmc-full.img.gz"
        fi
        log_dry "would verify: gzip -dc <local> | $LOCAL_HASH   ==   ssh $TARGET_HOST '$REMOTE_HASH $OMNI_EMMC'"
    else
        FULL="$DEST/omni-emmc-full.img.gz"
        rsh_q 'sync' >/dev/null || true
        log "imaging $OMNI_EMMC ($(human_bytes "$EMMC_SIZE")) - this takes a while"
        set +e
        if [ "$REMOTE_GZIP" = "1" ]; then
            case "$REMOTE_TOOLS" in
                *"gzip=no"*) err "the device has no gzip; re-run with --no-remote-gzip"; exit 1 ;;
            esac
            rsh "dd if=$OMNI_EMMC bs=4M 2>/dev/null | gzip -1" > "$FULL.part"
            RC="${PIPESTATUS[*]}"
        else
            rsh "dd if=$OMNI_EMMC bs=4M 2>/dev/null" | gzip -1 > "$FULL.part"
            RC="${PIPESTATUS[*]}"
        fi
        set -e
        case "$RC" in
            0|"0 0") ;;
            *) rm -f -- "$FULL.part"; die "full eMMC image failed (exit codes $RC)" ;;
        esac
        mv -f -- "$FULL.part" "$FULL"
        ok "omni-emmc-full.img.gz  $(human_bytes "$(wc -c < "$FULL")")"

        # --- verification -------------------------------------------------
        if [ -z "$REMOTE_HASH" ]; then
            warn "no usable hash tool on both ends - the full image was NOT verified"
            VERIFIED="NOT VERIFIED (no hash tool)"
        else
            banner "verify"
            log "hashing the local image (decompressed) with $LOCAL_HASH"
            set +e
            LOCAL_SUM=$(gzip -dc "$FULL" | "$LOCAL_HASH" | cut -d' ' -f1)
            VRC="${PIPESTATUS[*]}"
            set -e
            case "$VRC" in
                "0 0 0") ;;
                *) die "could not hash the local image (exit codes $VRC) - the archive may be truncated" ;;
            esac
            log "hashing $OMNI_EMMC on the device with $REMOTE_HASH"
            REMOTE_SUM=$(rsh "$REMOTE_HASH $OMNI_EMMC" | cut -d' ' -f1) \
                || die "remote $REMOTE_HASH failed"
            {
                printf 'algorithm: %s\n' "$REMOTE_HASH"
                printf 'local  (gzip -dc omni-emmc-full.img.gz): %s\n' "$LOCAL_SUM"
                printf 'remote (%s %s):                %s\n' "$REMOTE_HASH" "$OMNI_EMMC" "$REMOTE_SUM"
            } > "$DEST/MD5-VERIFY.txt"
            if [ "$LOCAL_SUM" = "$REMOTE_SUM" ]; then
                ok "image matches the device: $LOCAL_SUM"
                printf 'RESULT: MATCH\n' >> "$DEST/MD5-VERIFY.txt"
                VERIFIED="verified ($REMOTE_HASH $LOCAL_SUM)"
            else
                printf 'RESULT: MISMATCH\n' >> "$DEST/MD5-VERIFY.txt"
                err "HASH MISMATCH"
                err "  local : $LOCAL_SUM"
                err "  remote: $REMOTE_SUM"
                err ""
                err "  The device is live, so anything that wrote to the eMMC between the"
                err "  image and the hash produces exactly this.  Re-run with --quiesce,"
                err "  which stops docker/containerd/syslog-ng for the duration."
                err "  Do NOT treat this backup as good."
                die "full eMMC image did not verify"
            fi
        fi
    fi
fi

# --- checksums of everything we produced -----------------------------------
if [ "$DRY_RUN" != "1" ]; then
    log "writing SHA256SUMS"
    ( cd "$DEST" && sha256sum ./* 2>/dev/null | grep -v 'SHA256SUMS' > SHA256SUMS.tmp && mv SHA256SUMS.tmp SHA256SUMS ) \
        || warn "could not write SHA256SUMS"
fi

# ===========================================================================
# Restore cheat-sheet
# ===========================================================================
CHEAT_BODY=$(cat <<EOF
Avast Omni - restore cheat-sheet
generated $(_omni_stamp) by omni-backup.sh
backup set: $DEST
source:     $TARGET_HOST
eMMC size:  $EMMC_SIZE bytes
full image: $VERIFIED

-----------------------------------------------------------------------------
1. RESTORE THE ENVIRONMENT FROM THE "=>" PROMPT  (no working rootfs needed)
-----------------------------------------------------------------------------
   The environment is ONE non-redundant 8 KB copy at offset 0 of
   ${OMNI_EMMC}boot0.  0x2000 bytes = 0x10 blocks of 512 B.
   omni-env-8k.bin is exactly those bytes.

     => loady 0x08000000        # then send omni-env-8k.bin over ymodem
     (or)
     => tftp 0x08000000 omni-env-8k.bin

     => mmc dev 0 1             # 1 selects the boot0 hardware partition
     => mmc write 0x08000000 0 0x10
     => reset

   Sanity-check before you reset:
     => md.b 0x08000000 0x40    # should not be all 00 or all ff

   This is pre-flight check P7.  Rehearse it BEFORE arming anything.

-----------------------------------------------------------------------------
2. RESTORE THE ENVIRONMENT FROM A RUNNING LINUX
-----------------------------------------------------------------------------
     scp $DEST/omni-boot0.img $TARGET_HOST:/tmp/
     ssh $TARGET_HOST '
        echo 0 > /sys/block/mmcblk0boot0/force_ro
        dd if=/tmp/omni-boot0.img of=${OMNI_EMMC}boot0 bs=1M conv=fsync
        echo 1 > /sys/block/mmcblk0boot0/force_ro
        sync
        fw_printenv | sort'

   force_ro MUST go back to 1.  Compare the output against omni-env.txt.

   To put back only the individual values you care about (safer - one batched
   write instead of an 8 MB blast at the boot partition):

     printf 'ethaddr <mac>\nmender_boot_part 1\nmender_boot_part_hex 1\n' > /run/env.txt
     echo 0 > /sys/block/mmcblk0boot0/force_ro
     fw_setenv -s /run/env.txt
     echo 1 > /sys/block/mmcblk0boot0/force_ro
     fw_printenv ethaddr mender_boot_part mender_boot_part_hex   # assert

-----------------------------------------------------------------------------
3. RESTORE THE PARTITION TABLE
-----------------------------------------------------------------------------
     scp $DEST/omni-ptable.sfdisk $TARGET_HOST:/tmp/
     ssh $TARGET_HOST 'sfdisk --force ${OMNI_EMMC} < /tmp/omni-ptable.sfdisk; partprobe ${OMNI_EMMC} || true'

   The layout this backup captured:
     p1 rootfs A   p2 rootfs B   p3 /data
     p5 overlay upper for A      p6 overlay upper for B      p7 recovery
     (overlay upper = root partition number + 4)

-----------------------------------------------------------------------------
4. RESTORE ONE ROOTFS SLOT
-----------------------------------------------------------------------------
   From the full image, without unpacking all of it - find the slot's start
   offset and size in omni-ptable.sfdisk (units are 512-byte sectors):

     start=<start sectors>; count=<size sectors>
     gzip -dc $DEST/omni-emmc-full.img.gz \\
       | dd bs=512 skip=\$start count=\$count iflag=fullblock \\
       | ssh $TARGET_HOST 'dd of=/dev/mmcblk0pN bs=1M conv=fsync'

   Never write the slot you are currently running from.

-----------------------------------------------------------------------------
5. RESTORE THE WHOLE eMMC
-----------------------------------------------------------------------------
   You cannot rewrite the user area from a rootfs that lives inside it.  Boot
   the p7 recovery partition (reset button) or the serial "=>" prompt first,
   or use Amlogic USB boot:

     pyamlboot (USB id 1b8e:c003, board profile "s400")
     https://github.com/superna9999/pyamlboot

   From a recovery shell with the network up:

     ssh <workstation> 'cat omni-emmc-full.img.gz' | gzip -dc \\
       | dd of=${OMNI_EMMC} bs=4M iflag=fullblock conv=fsync

   Then restore boot0 (step 2), because the boot partitions are NOT part of the
   user area image.

-----------------------------------------------------------------------------
6. RECOVERY LADDER, most reliable first
-----------------------------------------------------------------------------
   1. serial "=>" prompt         needs bootdelay >= 0.  A FAILED load drops to
                                 "=>" regardless of bootdelay, so a slot that
                                 cannot load is always recoverable.
   2. reset button -> p7         needs p7 populated (pre-flight P6).  Overrides
                                 mender_boot_part.  Needs no tools.
   3. fw_setenv force_hard_recovery 1 -> p7    armed in advance from Linux
   4. bootcount/bootlimit auto-rollback        something must actually REBOOT
   5. Amlogic USB boot           needs a physically routed USB port (Phase 5)

-----------------------------------------------------------------------------
FILES IN THIS BACKUP SET
-----------------------------------------------------------------------------
EOF
)

if [ "$DRY_RUN" = "1" ]; then
    printf '%s\n' "$CHEAT_BODY"
    log_dry "dry run complete - nothing was created"
    exit 0
fi

{
    printf '%s\n' "$CHEAT_BODY"
    ls -la "$DEST" | sed 's/^/  /'
    printf '\n'
    printf 'Verify this set later with:  cd %s && sha256sum -c SHA256SUMS\n' "$DEST"
} > "$DEST/RESTORE-CHEATSHEET.txt"

banner "backup complete"
cat "$DEST/RESTORE-CHEATSHEET.txt"
ok "backup set: $DEST"
ok "full image: $VERIFIED"
log "Only now is it safe to make the first fw_setenv (e.g. bootdelay 3)."

exit 0

#!/usr/bin/env bash
#
# check-image-invariants.sh — assert the rootfs/image invariants that the
# Avast Omni Armbian migration depends on.
#
# Authority: docs/ARMBIAN-MIGRATION.md, section "Rootfs and initramfs"
# (plus risks 4, 5 and 7).
#
# Input: a built Debian rootfs as a DIRECTORY or a TARBALL (mmdebstrap
# --format=tar, optionally compressed), and/or the packed ext4 image
# (omni-slot.ext4[.gz]) for the filesystem-feature assertions.
#
# This script is READ-ONLY. It never mounts, never writes into the rootfs and
# never touches a block device. It exits non-zero when an invariant is
# violated, printing one precise line per failure plus a one-line rationale.
#
# Dependencies: bash 4+, coreutils, grep. Optional (probed, never assumed):
# tar (tarball input), gzip (compressed input), dumpe2fs (preferred for the
# ext4 features; a dependency-free superblock decoder is used otherwise).
#
set -euo pipefail

PROG=${0##*/}

TMP=""
cleanup() {
	if [ -n "$TMP" ] && [ -d "$TMP" ]; then rm -rf -- "$TMP"; fi
	return 0
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Defaults that an integrator may need to move in exactly one place
# ---------------------------------------------------------------------------

# The dpkg/initramfs hooks that cp -f (never ln) the real kernel, dtb and
# initrd onto the three fixed mender names. postinst.d fires when a
# linux-image/linux-dtb deb is installed, postrm.d when an old kernel is
# removed (otherwise dpkg can delete the file the flattened copy came from),
# post-update.d when update-initramfs regenerates the initrd.
DEFAULT_HOOKS=(
	/etc/kernel/postinst.d/zz-omni-flatten
	/etc/kernel/postrm.d/zz-omni-flatten
	/etc/initramfs/post-update.d/99-omni-flatten
)

# Compiled U-Boot defaults. ONLY used as a last resort with a loud warning:
# the plan requires these to come from Phase 0's `fw_printenv` via
# /etc/default/omni-boot, never from literals typed out of the patches.
FALLBACK_KERNEL_NAME=Image
FALLBACK_DTB_NAME=meson-axg-apollo.dtb
FALLBACK_RAMDISK_NAME=apollo-initramfs-image-meson-apollo.cpio.gz

# Minimum plausible sizes for the flattened /boot copies (catches a truncated
# or zero-length `cp -f`, which dd/e2fsck will happily call a success).
MIN_KERNEL_BYTES=$((1024 * 1024))
MIN_DTB_BYTES=1024
MIN_RAMDISK_BYTES=$((256 * 1024))

# ext4 features that must NOT be present in the packed slot image.
#   feature|severity|why
FORBIDDEN_EXT4_FEATURES=$(
	cat <<'EOF'
metadata_csum_seed|fail|Debian trixie e2fsprogs 1.47 enables it by default (Debian #1072566). It is an INCOMPAT bit: U-Boot 2018.09's ext4 driver and the 5.4 kernel in the rollback slot refuse the filesystem outright. Pack with -O ^metadata_csum_seed. Fails as an unbootable slot, not as a build error.
orphan_file|fail|Debian trixie e2fsprogs 1.47 enables it by default (Debian #1072566). The paired RO_COMPAT orphan_present bit blocks a read-write mount on anything older than 5.15. Pack with -O ^orphan_file.
orphan_present|fail|Set when an orphan_file has live content; blocks rw mount on the 5.4 kernel in the rollback slot. Pack with -O ^orphan_file and fsck the image before shipping it.
64bit|fail|The current slot (p1) does not have it; enabling it changes the group-descriptor size, which U-Boot 2018.09's ext4 reader does not handle. The plan pins -O ^64bit.
metadata_csum|warn|The plan's mke2fs line pins -O ^metadata_csum to clone p1's feature set exactly. Not fatal by itself on a 5.4+ kernel, but it is a deviation from the assertion "derived from the Phase 0 dumpe2fs -h /dev/mmcblk0p1 line".
casefold|warn|Not part of p1's feature set; nothing in the plan asks for it.
EOF
)

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
PASS=0
FAILED=0
WARNED=0
SKIPPED=0
QUIET=0
STRICT=0
ALLOW_NO_SSH_KEY=0
RECOVERY=0
USE_COLOR=auto
C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""

setup_color() {
	local want=$USE_COLOR
	if [ "$want" = auto ]; then
		if [ -t 1 ] && [ "${NO_COLOR-}" = "" ] && [ "${TERM-dumb}" != dumb ]; then
			want=yes
		else
			want=no
		fi
	fi
	if [ "$want" = yes ]; then
		C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[1m'; C_0=$'\033[0m'
	fi
}

say() { if [ "$QUIET" -eq 0 ]; then printf '%s\n' "$*"; fi; }
die() { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 2; }

ok() { PASS=$((PASS + 1)); say "${C_G}PASS${C_0}  $1"; return 0; }

bad() { # $1 headline, $2 why, $3 severity (fail|warn)
	if [ "${3:-fail}" = warn ] && [ "$STRICT" -eq 0 ]; then
		WARNED=$((WARNED + 1))
		printf '%sWARN%s  %s\n' "$C_Y" "$C_0" "$1"
	else
		FAILED=$((FAILED + 1))
		printf '%sFAIL%s  %s\n' "$C_R" "$C_0" "$1"
	fi
	if [ -n "${2-}" ]; then printf '      why: %s\n' "$2"; fi
	return 0
}

fail() { bad "$1" "${2-}" fail; }
warn() { bad "$1" "${2-}" warn; }

skip() { # $1 headline, $2 reason
	if [ "$STRICT" -eq 1 ]; then
		FAILED=$((FAILED + 1))
		printf '%sFAIL%s  %s (skipped, and --strict treats a skip as a failure)\n' "$C_R" "$C_0" "$1"
		if [ -n "${2-}" ]; then printf '      why: %s\n' "$2"; fi
	else
		SKIPPED=$((SKIPPED + 1))
		say "${C_Y}SKIP${C_0}  $1 — ${2-}"
	fi
	return 0
}

have() { command -v "$1" >/dev/null 2>&1; }

usage() {
	cat <<EOF
Usage: $PROG [OPTIONS] [PATH]...

Assert the rootfs/image invariants required by the Avast Omni Armbian
migration (docs/ARMBIAN-MIGRATION.md, "Rootfs and initramfs").
Read-only: nothing is mounted, written or modified, so there is no dry-run
mode to ask for — every run is a dry run.

PATH is auto-classified:
  a directory        -> the built Debian rootfs (fastest)
  a tar archive      -> the built rootfs, mmdebstrap --format=tar
                        (plain/gz/xz/zst; needs tar, and gzip for .gz)
  an ext4 image      -> the packed slot (omni-slot.ext4 or .ext4.gz);
                        only the filesystem-feature assertions run on it
Pass both (a rootfs and an image) to run every check in one invocation, or
use --rootfs/--image to be explicit.

'--rootfs /' self-checks a live slot over ssh on the device. One caveat:
systemd populates /etc/machine-id at runtime, so add '--skip machine-id'
there — that check is about what the IMAGE ships, not about what is running.

Options:
  -h, --help              this text
      --rootfs PATH       rootfs directory or tarball
      --image PATH        packed ext4 slot image (plain or .gz)
      --list              list the check IDs and exit
      --only ID           run only this check (repeatable)
      --skip ID           skip this check (repeatable)
      --hook PATH         expected flatten hook; repeating REPLACES the
                          default set (see below)
      --kernel-name N     override the flattened kernel name
      --dtb-name N        override the flattened dtb name
      --ramdisk-name N    override the flattened initrd name
      --strict            warnings and skips become failures
      --allow-no-ssh-key  an image with no authorised root key warns instead of
                          failing. Match this with build-rootfs.sh's flag of the
                          same name: it means "serial console only, deliberately".
      --recovery          check a RECOVERY (p7) image rather than an A/B slot.
                          U-Boot enters p7 with ramdisk_addr_r cleared and
                          init=/init, so the initrd, the overlay-root script and
                          the initramfs hooks are all correctly absent; instead
                          this asserts /init, the disarm unit, and that the A/B
                          commit/deadman units are NOT present.
  -q, --quiet             print only failures/warnings and the summary
      --no-color / --color

The three /boot names are read from the image's own
/etc/default/omni-boot (OMNI_KERNEL_NAME / OMNI_DTB_NAME / OMNI_INITRD_NAME,
with OMNI_RAMDISK_NAME and MENDER_* also accepted for the ramdisk), which the
plan requires to be populated from Phase 0's
\`fw_printenv\`, never from literals. The --*-name options and the compiled
defaults are a loud last resort.

Default flatten hooks (override with --hook, repeatable):
$(printf '  %s\n' "${DEFAULT_HOOKS[@]}")

Exit: 0 all invariants hold, 1 at least one failure, 2 usage/setup error.

Examples:
  $PROG build/omni-rootfs/                       # unpacked rootfs
  $PROG build/omni-rootfs.tar build/omni-slot.ext4.gz
  $PROG --image build/omni-slot.ext4 --strict
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
ROOTFS=""
IMAGE=""
ONLY=""
SKIPS=""
DO_LIST=0
HOOKS=()
KERNEL_NAME=""
DTB_NAME=""
RAMDISK_NAME=""
POSITIONAL=()

while [ $# -gt 0 ]; do
	case "$1" in
	-h | --help) usage; exit 0 ;;
	--list) DO_LIST=1 ;;
	--strict) STRICT=1 ;;
	--allow-no-ssh-key) ALLOW_NO_SSH_KEY=1 ;;
	--recovery) RECOVERY=1 ;;
	-q | --quiet) QUIET=1 ;;
	--no-color) USE_COLOR=no ;;
	--color) USE_COLOR=yes ;;
	--rootfs) [ $# -ge 2 ] || die "--rootfs needs an argument"; shift; ROOTFS=$1 ;;
	--rootfs=*) ROOTFS=${1#--rootfs=} ;;
	--image) [ $# -ge 2 ] || die "--image needs an argument"; shift; IMAGE=$1 ;;
	--image=*) IMAGE=${1#--image=} ;;
	--only) [ $# -ge 2 ] || die "--only needs an argument"; shift; ONLY="$ONLY $1" ;;
	--only=*) ONLY="$ONLY ${1#--only=}" ;;
	--skip) [ $# -ge 2 ] || die "--skip needs an argument"; shift; SKIPS="$SKIPS $1" ;;
	--skip=*) SKIPS="$SKIPS ${1#--skip=}" ;;
	--hook) [ $# -ge 2 ] || die "--hook needs an argument"; shift; HOOKS+=("$1") ;;
	--hook=*) HOOKS+=("${1#--hook=}") ;;
	--kernel-name) [ $# -ge 2 ] || die "--kernel-name needs an argument"; shift; KERNEL_NAME=$1 ;;
	--kernel-name=*) KERNEL_NAME=${1#--kernel-name=} ;;
	--dtb-name) [ $# -ge 2 ] || die "--dtb-name needs an argument"; shift; DTB_NAME=$1 ;;
	--dtb-name=*) DTB_NAME=${1#--dtb-name=} ;;
	--ramdisk-name) [ $# -ge 2 ] || die "--ramdisk-name needs an argument"; shift; RAMDISK_NAME=$1 ;;
	--ramdisk-name=*) RAMDISK_NAME=${1#--ramdisk-name=} ;;
	--) shift; while [ $# -gt 0 ]; do POSITIONAL+=("$1"); shift; done; break ;;
	-*) die "unknown option '$1' (try --help)" ;;
	*) POSITIONAL+=("$1") ;;
	esac
	shift
done

setup_color

if [ ${#HOOKS[@]} -eq 0 ]; then
	if [ -n "${OMNI_FLATTEN_HOOKS-}" ]; then
		IFS=: read -r -a HOOKS <<<"$OMNI_FLATTEN_HOOKS"
	else
		HOOKS=("${DEFAULT_HOOKS[@]}")
	fi
fi

CHECK_IDS="armbian-install armbian-packages serial-autologin fstab-cgroup \
omni-boot-defaults boot-real-files flatten-hooks machine-id initramfs \
network-naming sshd modprobe-blacklist data-symlinks ext4-features"

if [ "$DO_LIST" -eq 1 ]; then
	printf '%s\n' $CHECK_IDS
	exit 0
fi

wanted() { # $1 = check id
	case " $SKIPS " in *" $1 "*) return 1 ;; esac
	if [ -n "$ONLY" ]; then
		case " $ONLY " in *" $1 "*) return 0 ;; *) return 1 ;; esac
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Classify the positional arguments
# ---------------------------------------------------------------------------
mktmp() {
	if [ -z "$TMP" ]; then
		TMP=$(mktemp -d "${TMPDIR:-/tmp}/omni-image-check.XXXXXX")
	fi
	return 0
}

is_gzip() { # $1 = file
	local h
	h=$(od -An -tx1 -N 2 -v -- "$1" 2>/dev/null | tr -d ' \n') || return 1
	[ "$h" = "1f8b" ]
}

head_bytes() { # $1 = file, $2 = count -> stdout
	if is_gzip "$1"; then
		have gzip || die "'$1' is gzip-compressed but gzip is not installed"
		{ gzip -dc -- "$1" 2>/dev/null || true; } | head -c "$2"
	else
		head -c "$2" -- "$1"
	fi
}

hdr_hex() { # $1 = header file, $2 = offset, $3 = length
	od -An -tx1 -j "$2" -N "$3" -v -- "$1" 2>/dev/null | tr -d ' \n'
}

hdr_str() { # $1 = header file, $2 = offset, $3 = length
	dd if="$1" bs=1 skip="$2" count="$3" 2>/dev/null | tr -d '\000'
}

classify() { # $1 = path -> prints dir|tar|ext4|unknown
	if [ -d "$1" ]; then printf 'dir\n'; return 0; fi
	mktmp
	local h=$TMP/hdr.$$.bin
	head_bytes "$1" 4096 >"$h" 2>/dev/null || true
	if [ "$(hdr_str "$h" 257 5)" = "ustar" ]; then printf 'tar\n'; return 0; fi
	if [ "$(hdr_hex "$h" 1080 2)" = "53ef" ]; then printf 'ext4\n'; return 0; fi
	# uncompressed tars from some producers use the v7 format (no magic);
	# fall back to the file name in that case.
	case "$1" in
	*.tar | *.tar.* | *.tgz | *.txz | *.tzst) printf 'tar\n'; return 0 ;;
	*.ext4 | *.ext4.gz | *.img | *.img.gz) printf 'ext4\n'; return 0 ;;
	esac
	printf 'unknown\n'
}

for p in ${POSITIONAL[@]+"${POSITIONAL[@]}"}; do
	[ -e "$p" ] || die "no such path: '$p'"
	kind=$(classify "$p")
	case "$kind" in
	dir | tar)
		[ -z "$ROOTFS" ] || die "two rootfs arguments given ('$ROOTFS' and '$p')"
		ROOTFS=$p
		;;
	ext4)
		[ -z "$IMAGE" ] || die "two image arguments given ('$IMAGE' and '$p')"
		IMAGE=$p
		;;
	*)
		die "cannot classify '$p': not a directory, not a tar archive, no ext4 superblock. Use --rootfs/--image."
		;;
	esac
done

if [ -z "$ROOTFS" ] && [ -z "$IMAGE" ]; then
	usage >&2
	die "nothing to check: give a rootfs directory/tarball and/or an ext4 image"
fi
[ -z "$ROOTFS" ] || [ -e "$ROOTFS" ] || die "no such rootfs: '$ROOTFS'"
[ -z "$IMAGE" ] || [ -e "$IMAGE" ] || die "no such image: '$IMAGE'"

# ---------------------------------------------------------------------------
# Rootfs access layer: r_type / r_exec / r_size / r_link / r_cat / r_children
# ---------------------------------------------------------------------------
RKIND=""
RPREFIX=""       # path prefix for the dir backend ("" when ROOTFS is "/")
declare -A T_TYPE=()   # normalised path -> file|symlink|dir|other
declare -A T_MODE=()   # normalised path -> mode string
declare -A T_RAW=()    # normalised path -> raw archive member name
declare -A T_LINK=()   # normalised path -> symlink target
XDIR=""                # where the small files were extracted (tar backend)

norm_path() { # -> /a/b (no trailing slash, no ./ prefix)
	local p=$1
	p=${p#./}
	p=${p%/}
	case "$p" in /*) ;; *) p="/$p" ;; esac
	printf '%s' "$p"
}

init_rootfs_dir() {
	RKIND=dir
	# "/" (an on-device self-check) must join to "/etc", not "//etc"; every
	# other directory loses its trailing slash. ROOTFS itself stays intact so
	# the reported path is the one the caller typed.
	case "$ROOTFS" in
	/) RPREFIX="" ;;
	*) RPREFIX=${ROOTFS%/} ;;
	esac
	[ -d "$RPREFIX/etc" ] ||
		die "'$ROOTFS' has no etc/ — that is not a built rootfs. Refusing to report invented PASSes."
}

init_rootfs_tar() {
	RKIND=tar
	have tar || die "'$ROOTFS' is a tar archive but tar is not installed"
	mktmp
	tar -tf "$ROOTFS" >"$TMP/names" 2>"$TMP/tar.err" ||
		die "tar could not list '$ROOTFS': $(head -n 3 "$TMP/tar.err" | tr '\n' ' ')"
	tar -tvf "$ROOTFS" >"$TMP/verbose" 2>/dev/null ||
		die "tar could not list '$ROOTFS' verbosely"
	local n v
	n=$(wc -l <"$TMP/names")
	v=$(wc -l <"$TMP/verbose")
	[ "$n" = "$v" ] ||
		die "tar listing mismatch ($n names vs $v verbose lines) — unpack the tarball and pass the directory instead"

	local raw vline mode target p
	exec 8<"$TMP/names" 9<"$TMP/verbose"
	while IFS= read -r raw <&8 && IFS= read -r vline <&9; do
		mode=${vline%% *}
		target=""
		case "$vline" in *" -> "*) target=${vline##* -> } ;; esac
		p=$(norm_path "$raw")
		[ -n "$p" ] || continue
		T_RAW[$p]=$raw
		T_MODE[$p]=$mode
		T_LINK[$p]=$target
		case "${mode:0:1}" in
		-) T_TYPE[$p]=file ;;
		h) T_TYPE[$p]=file ;;
		l) T_TYPE[$p]=symlink ;;
		d) T_TYPE[$p]=dir ;;
		*) T_TYPE[$p]=other ;;
		esac
	done
	exec 8<&- 9<&-

	local looks_like_rootfs=0
	for p in /etc /etc/fstab /etc/os-release /usr/lib/os-release; do
		if [ -n "${T_TYPE[$p]-}" ]; then looks_like_rootfs=1; fi
	done
	[ "$looks_like_rootfs" -eq 1 ] ||
		die "'$ROOTFS' contains no /etc — that is not a built rootfs. Refusing to report invented PASSes."

	# One extraction pass for the small text files the checks need to read.
	XDIR=$TMP/x
	mkdir -p "$XDIR"
	: >"$TMP/members"
	local k
	for k in "${!T_TYPE[@]}"; do
		[ "${T_TYPE[$k]}" = file ] || continue
		case "$k" in
		/etc/* | /var/lib/dpkg/status | /usr/lib/systemd/system/* | /lib/systemd/system/*)
			printf '%s\n' "${T_RAW[$k]}" >>"$TMP/members"
			;;
		esac
	done
	if [ -s "$TMP/members" ]; then
		tar -xf "$ROOTFS" -C "$XDIR" --no-same-owner -T "$TMP/members" 2>"$TMP/x.err" ||
			die "could not extract the configuration files from '$ROOTFS': $(head -n 3 "$TMP/x.err" | tr '\n' ' ')"
	fi
}

r_type() { # $1 = absolute path inside the rootfs
	local p
	p=$(norm_path "$1")
	if [ "$RKIND" = dir ]; then
		if [ -L "$RPREFIX$p" ]; then printf 'symlink\n'
		elif [ -d "$RPREFIX$p" ]; then printf 'dir\n'
		elif [ -f "$RPREFIX$p" ]; then printf 'file\n'
		elif [ -e "$RPREFIX$p" ]; then printf 'other\n'
		else printf 'missing\n'; fi
	else
		printf '%s\n' "${T_TYPE[$p]-missing}"
	fi
}

r_exists() { [ "$(r_type "$1")" != missing ]; }

r_exec() { # 0 if the path exists and has an execute bit
	local p m
	p=$(norm_path "$1")
	if [ "$RKIND" = dir ]; then
		[ -x "$RPREFIX$p" ] && [ ! -d "$ROOTFS$p" ]
	else
		m=${T_MODE[$p]-}
		[ -n "$m" ] || return 1
		case "${m:3:1}${m:6:1}${m:9:1}" in *[xsSt]*) return 0 ;; esac
		return 1
	fi
}

r_mode() { # prints a mode string like -rwxr-xr-x, or "?"
	local p m
	p=$(norm_path "$1")
	if [ "$RKIND" = dir ]; then
		m=$(ls -ld -- "$RPREFIX$p" 2>/dev/null || true)
		m=${m%% *}
		printf '%s' "${m:-?}"
	else
		printf '%s' "${T_MODE[$p]-?}"
	fi
}

r_size() { # prints a byte count, or 0
	local p
	p=$(norm_path "$1")
	if [ "$RKIND" = dir ]; then
		if [ -f "$RPREFIX$p" ] && [ ! -L "$ROOTFS$p" ]; then
			wc -c <"$RPREFIX$p" | tr -d ' '
		else
			printf '0\n'
		fi
	else
		local raw=${T_RAW[$p]-} v="" line nm
		if [ -z "$raw" ]; then printf '0\n'; return 0; fi
		# find the verbose line whose member name is exactly $raw
		while IFS= read -r line; do
			nm=$line
			case "$nm" in *" -> "*) nm=${nm% -> *} ;; esac
			case "$nm" in *" $raw") v=$line; break ;; esac
		done < <(grep -F -- "$raw" "$TMP/verbose" 2>/dev/null || true)
		# size is the field before the date; recover it robustly by taking the
		# last purely numeric field that precedes a YYYY-MM-DD or a month name.
		# set -f: a member name may legitimately contain glob characters.
		local f prev=0 had_f=0 out=0
		case $- in *f*) had_f=1 ;; esac
		set -f
		for f in $v; do
			case "$f" in
			[0-9]*-[0-9]*-[0-9]* | Jan | Feb | Mar | Apr | May | Jun | Jul | Aug | Sep | Oct | Nov | Dec)
				out=$prev
				break
				;;
			esac
			case "$f" in *[!0-9]*) ;; *) prev=$f ;; esac
		done
		[ "$had_f" -eq 1 ] || set +f
		printf '%s\n' "$out"
	fi
}

r_link() { # prints a symlink target
	local p
	p=$(norm_path "$1")
	if [ "$RKIND" = dir ]; then
		readlink -- "$RPREFIX$p" 2>/dev/null || true
	else
		printf '%s\n' "${T_LINK[$p]-}"
	fi
}

r_cat() { # prints file content; returns 1 if unreadable
	local p
	p=$(norm_path "$1")
	if [ "$RKIND" = dir ]; then
		[ -f "$RPREFIX$p" ] || return 1
		cat -- "$RPREFIX$p"
	else
		[ "${T_TYPE[$p]-}" = file ] || return 1
		if [ -f "$XDIR$p" ]; then
			cat -- "$XDIR$p"
		else
			tar -xOf "$ROOTFS" -- "${T_RAW[$p]}"
		fi
	fi
}

r_children() { # $1 = directory -> prints absolute paths of immediate children
	local d p
	d=$(norm_path "$1")
	if [ "$RKIND" = dir ]; then
		[ -d "$RPREFIX$d" ] || return 0
		local f
		for f in "$RPREFIX$d"/*; do
			[ -e "$f" ] || [ -L "$f" ] || continue
			printf '%s\n' "${f#"$RPREFIX"}"
		done
	else
		for p in "${!T_TYPE[@]}"; do
			case "$p" in
			"$d"/*)
				case "${p#"$d"/}" in */*) ;; *) printf '%s\n' "$p" ;; esac
				;;
			esac
		done | sort
	fi
	return 0
}

if [ -n "$ROOTFS" ]; then
	case "$(classify "$ROOTFS")" in
	dir) init_rootfs_dir ;;
	tar) init_rootfs_tar ;;
	*) die "'$ROOTFS' is neither a directory nor a tar archive" ;;
	esac
fi

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

check_armbian_install() {
	local p found=0
	for p in /usr/bin/armbian-install /usr/sbin/armbian-install \
		/usr/bin/armbian-installer /usr/sbin/armbian-installer; do
		if r_exists "$p"; then
			found=1
			fail "$p EXISTS" \
				"armbian-install repartitions the eMMC and rewrites bootloaders. On this device that destroys the A/B table (p1/p2 slots, p3 /data, p5/p6 overlay uppers, p7 recovery) and the U-Boot env that is the only copy of ethaddr. The plan builds with mmdebstrap precisely so armbian-bsp-cli — and therefore this file — never lands."
		fi
	done
	[ "$found" -eq 1 ] || ok "no armbian-install in the image"
}

check_armbian_packages() {
	local status=/var/lib/dpkg/status hits
	if ! r_exists "$status"; then
		skip "armbian-packages" "no $status in the rootfs"
		return 0
	fi
	hits=$(r_cat "$status" | grep -E '^Package: armbian-(bsp-cli|bsp-desktop|config|firmware)' || true)
	if [ -n "$hits" ]; then
		fail "armbian packages present in dpkg status: $(printf '%s' "$hits" | tr '\n' ' ')" \
			"armbian-bsp-cli owns /usr/bin/armbian-install, ships its own /boot handling and its own initramfs hooks, all of which fight the mender flatten hooks. The plan eliminates it structurally by not using Armbian's image pipeline at all."
	else
		ok "no armbian-bsp-cli / armbian-config in dpkg status"
	fi
}

check_serial_autologin() {
	local d f found="" content
	for d in /etc/systemd/system /usr/lib/systemd/system /lib/systemd/system; do
		f="$d/serial-getty@ttyAML0.service.d/autologin.conf"
		if [ "$(r_type "$f")" = file ]; then found=$f; break; fi
	done
	if [ -z "$found" ]; then
		fail "serial-getty@ttyAML0.service.d/autologin.conf is MISSING" \
			"Today the console is passwordless root (systemd-serialgetty access.conf ACCESS=-aroot). Debian locks root and the NIC renames to end0, so without this drop-in a bad network config means no SSH, no login and — with bootdelay<0 — no bootloader prompt either. Harden SSH, never the console."
		return 0
	fi
	content=$(r_cat "$found" || true)
	ok "$found present"

	if printf '%s' "$content" | grep -qE '^[[:space:]]*ExecStart=.*--autologin[[:space:]]+root'; then
		ok "$found sets --autologin root"
	else
		fail "$found does not contain 'ExecStart=... --autologin root'" \
			"A drop-in without --autologin root leaves the serial console at a login prompt for a locked root account: the box is then unrecoverable without opening the case and using U-Boot."
	fi

	if printf '%s' "$content" | grep -qE '^[[:space:]]*ExecStart=[[:space:]]*$'; then
		ok "$found clears ExecStart before overriding it"
	else
		fail "$found has no empty 'ExecStart=' reset line" \
			"serial-getty@.service is Type=idle with a single ExecStart; adding a second one without an empty 'ExecStart=' first makes systemd refuse to load the unit, so you get NO getty at all — a strictly worse failure than no autologin."
	fi

	if printf '%s' "$content" | grep -q '^\[Service\]'; then
		ok "$found has a [Service] section"
	else
		fail "$found has no [Service] section" \
			"systemd ignores directives that precede a section header; the drop-in would be silently inert."
	fi
}

check_fstab_cgroup() {
	local content line a b c rest bad_lines=""
	if [ "$(r_type /etc/fstab)" != file ]; then
		fail "/etc/fstab is missing or is not a regular file" \
			"/etc/fstab stays per-slot (it is in the plan's per-slot state table); an image without one will not mount /data (p3) or the overlay upper."
		return 0
	fi
	content=$(r_cat /etc/fstab || true)
	while IFS= read -r line; do
		line=${line#"${line%%[![:space:]]*}"}
		case "$line" in '' | '#'*) continue ;; esac
		read -r a b c rest <<<"$line" || true
		[ -n "${b-}" ] || continue
		case "$b" in
		/sys/fs/cgroup | /sys/fs/cgroup/*) bad_lines="$bad_lines$line"$'\n' ;;
		esac
		case "${c-}" in
		cgroup | cgroup2) bad_lines="$bad_lines$line"$'\n' ;;
		esac
	done <<<"$content"
	if [ -n "$bad_lines" ]; then
		fail "/etc/fstab still mounts /sys/fs/cgroup: $(printf '%s' "$bad_lines" | tr '\n' ';')" \
			"The Yocto image carried 'none /sys/fs/cgroup tmpfs ...' (base-files fstab-logs:8) to fake cgroup v1. systemd PID1 mounts cgroup2 itself before fstab is processed; leaving the line in fights it, and systemd >=256 refuses to boot on v1 at all. The plan says DELETE the line, not edit it. Phase 8 gate: stat -fc %T /sys/fs/cgroup = cgroup2fs."
	else
		ok "/etc/fstab has no cgroup v1 line"
	fi
}

# Resolve the three flattened /boot names.
BOOT_NAME_SOURCE=""
KN=""; DN=""; RN=""

read_omni_boot_var() { # $1 = content, $2.. = accepted var names, first match wins by last-set
	local c=$1 v="" line key val
	while IFS= read -r line; do
		case "${line## }" in '' | '#'*) continue ;; esac
		case "$line" in *=*) ;; *) continue ;; esac
		key=${line%%=*}
		key=${key##*[[:space:]]}
		key=${key#export}
		val=${line#*=}
		val=${val%$'\r'}
		case "$val" in
		\"*\") val=${val#\"}; val=${val%\"} ;;
		\'*\') val=${val#\'}; val=${val%\'} ;;
		esac
		for want in "${@:2}"; do
			if [ "$key" = "$want" ]; then v=$val; fi
		done
	done <<<"$c"
	printf '%s' "$v"
}

check_omni_boot_defaults() {
	local c=""
	if [ "$(r_type /etc/default/omni-boot)" = file ]; then
		c=$(r_cat /etc/default/omni-boot || true)
		KN=$(read_omni_boot_var "$c" OMNI_KERNEL_NAME MENDER_KERNEL_NAME)
		DN=$(read_omni_boot_var "$c" OMNI_DTB_NAME MENDER_DTB_NAME)
		# OMNI_INITRD_NAME first: that is the name /usr/lib/omni/omni-flatten
		# actually reads and the one /etc/default/omni-boot ships, so a checker
		# that knew only OMNI_RAMDISK_NAME reported a correct file as
		# "incomplete (ramdisk='')". build-rootfs.sh accepts the same three
		# spellings in this order -- keep them in step.
		RN=$(read_omni_boot_var "$c" OMNI_INITRD_NAME OMNI_RAMDISK_NAME MENDER_RAMDISK_NAME)
		if [ -n "$KN" ] && [ -n "$DN" ] && [ -n "$RN" ]; then
			BOOT_NAME_SOURCE=/etc/default/omni-boot
			ok "/etc/default/omni-boot defines all three names ($KN, $DN, $RN)"
		else
			fail "/etc/default/omni-boot is incomplete (kernel='$KN' dtb='$DN' ramdisk='$RN')" \
				"The flatten hooks read these; an empty one makes the hook copy onto an empty name and U-Boot's ext4load then fails on a name that no longer exists. Populate it from Phase 0's 'fw_printenv mender_kernel_name mender_dtb_name mender_ramdisk_name' — verbatim, never typed from the patches (a field binary may predate 0050/0051)."
		fi
	else
		fail "/etc/default/omni-boot is missing" \
			"It is the single place where the captured mender_kernel_name / mender_dtb_name / mender_ramdisk_name live. These names are GLOBAL, not per-slot: if they drift, rolling back into the Yocto slot stops working."
	fi
	# Command-line overrides win; compiled defaults are the loud last resort.
	[ -z "$KERNEL_NAME" ] || { KN=$KERNEL_NAME; BOOT_NAME_SOURCE="--kernel-name"; }
	[ -z "$DTB_NAME" ] || { DN=$DTB_NAME; BOOT_NAME_SOURCE="--dtb-name"; }
	[ -z "$RAMDISK_NAME" ] || { RN=$RAMDISK_NAME; BOOT_NAME_SOURCE="--ramdisk-name"; }
	if [ -z "$KN" ] || [ -z "$DN" ] || [ -z "$RN" ]; then
		KN=${KN:-$FALLBACK_KERNEL_NAME}
		DN=${DN:-$FALLBACK_DTB_NAME}
		RN=${RN:-$FALLBACK_RAMDISK_NAME}
		BOOT_NAME_SOURCE="COMPILED DEFAULTS"
		warn "falling back to the compiled U-Boot names ($KN, $DN, $RN)" \
			"These are the values from the patches, not from the device. If this unit predates patch 0050/0051 the real names differ and the /boot check below is meaningless."
	fi
}

check_boot_real_files() {
	local spec name minsz t sz
	if [ "$(r_type /boot)" != dir ]; then
		fail "/boot is not a directory (type: $(r_type /boot))" \
			"U-Boot's ext4load reads /boot/<name> from inside the selected rootfs slot; if /boot is a symlink the load fails and you drop to the => prompt on every boot."
		return 0
	fi
	local specs="$KN|$MIN_KERNEL_BYTES|kernel $DN|$MIN_DTB_BYTES|dtb"
	if [ "$RECOVERY" = 1 ]; then
		# U-Boot clears ramdisk_addr_r before entering p7, so no initrd is
		# loaded on that path and shipping one would be dead weight.
		ok "recovery image: no initrd expected (U-Boot clears ramdisk_addr_r for p7)"
	else
		specs="$specs $RN|$MIN_RAMDISK_BYTES|initrd"
	fi
	for spec in $specs; do
		name=${spec%%|*}
		minsz=${spec#*|}; minsz=${minsz%%|*}
		t=$(r_type "/boot/$name")
		case "$t" in
		file)
			sz=$(r_size "/boot/$name")
			if [ "${sz:-0}" -ge "$minsz" ]; then
				ok "/boot/$name is a real file ($sz bytes)"
			else
				fail "/boot/$name is only ${sz:-0} bytes (expected >= $minsz)" \
					"A truncated or empty flattened copy still passes dd, sha256 and e2fsck of the slot; it fails at ext4load with the slot already armed. Check the cp -f in the flatten hook."
			fi
			;;
		symlink)
			fail "/boot/$name is a SYMLINK -> $(r_link "/boot/$name")" \
				"The plan requires real files (cp -f, never ln) at the three captured mender names, precisely so U-Boot 2018.09's ext4 symlink behaviour never matters. Cost is ~40 MB per slot and it is deliberate."
			;;
		missing)
			fail "/boot/$name is MISSING" \
				"U-Boot loads /boot/\${mender_kernel_name}, \${mender_dtb_name} and \${mender_ramdisk_name} from inside the selected slot. A missing one means the slot never boots — recoverable only from the => prompt (name source: $BOOT_NAME_SOURCE)."
			;;
		*)
			fail "/boot/$name is a $t, not a regular file" ""
			;;
		esac
	done
	# The flatten sources must exist, otherwise the hooks had nothing to copy.
	local have_vmlinuz=0 c
	while IFS= read -r c; do
		case "${c##*/}" in vmlinuz-*) have_vmlinuz=1 ;; esac
	done < <(r_children /boot)
	if [ "$have_vmlinuz" -eq 1 ]; then
		ok "/boot has a dpkg-installed vmlinuz-* to flatten from"
	else
		warn "/boot has no vmlinuz-* (the flatten source)" \
			"The flatten hooks copy the real vmlinuz-<ver>/dtb-<ver>/initrd.img-<ver>. With no source present, the fixed names are stale relics that no kernel upgrade will ever refresh."
	fi
}

check_flatten_hooks() {
	local h t
	for h in "${HOOKS[@]}"; do
		if [ "$RECOVERY" = 1 ]; then
			case "$h" in
			*/initramfs/post-update.d/*)
				ok "recovery image: $h correctly absent (no initrd is built)"
				continue ;;
			esac
		fi
		t=$(r_type "$h")
		if [ "$t" != file ]; then
			fail "flatten hook $h is $t (expected a regular file)" \
				"Without it, installing a kernel or regenerating the initrd updates vmlinuz-<ver>/initrd.img-<ver> but NOT the three fixed mender names, so the slot silently keeps booting the previous kernel — or a kernel whose modules were removed."
			continue
		fi
		if r_exec "$h"; then
			ok "flatten hook $h present and executable"
		else
			fail "flatten hook $h is NOT executable (mode: $(r_mode "$h"))" \
				"run-parts skips non-executable files without any error, so the hook is inert and the failure only shows up as a slot that boots the wrong kernel."
		fi
	done
}

check_machine_id() {
	local t sz
	t=$(r_type /etc/machine-id)
	case "$t" in
	missing) ok "/etc/machine-id absent (initramfs will seed it)" ;;
	file)
		sz=$(r_size /etc/machine-id)
		if [ "${sz:-0}" -eq 0 ]; then
			ok "/etc/machine-id present and empty (correct first-boot marker)"
		elif [ "$(r_cat /etc/machine-id | tr -d ' \n')" = uninitialized ]; then
			warn "/etc/machine-id contains 'uninitialized'" \
				"Acceptable to systemd, but the plan says the machine-id is an initramfs seed only; prefer a zero-length file."
		else
			fail "/etc/machine-id is BAKED INTO THE IMAGE ($sz bytes)" \
				"systemd PID1 overmounts /etc/machine-id before any unit runs and systemd-networkd derives its DHCP DUID from it. A baked id means both A/B slots (and every unit built from this image) claim the same DUID, so the DHCP server hands them the same lease. It must be empty or absent."
		fi
		;;
	symlink)
		fail "/etc/machine-id is a symlink -> $(r_link /etc/machine-id)" \
			"systemd needs a regular file it can bind-mount over; a symlink (e.g. into /data) also breaks the per-slot/per-unit identity the plan requires."
		;;
	*) fail "/etc/machine-id is a $t" "" ;;
	esac

	t=$(r_type /var/lib/dbus/machine-id)
	case "$t" in
	missing | symlink) ok "/var/lib/dbus/machine-id is not a baked copy ($t)" ;;
	file)
		if [ "$(r_size /var/lib/dbus/machine-id)" -eq 0 ]; then
			ok "/var/lib/dbus/machine-id is empty"
		else
			fail "/var/lib/dbus/machine-id is a baked copy of the machine id" \
				"It shadows the seeded /etc/machine-id for D-Bus and re-introduces exactly the duplicate-identity problem the empty /etc/machine-id avoids. Make it a symlink to /etc/machine-id or delete it."
		fi
		;;
	*) warn "/var/lib/dbus/machine-id is a $t" "" ;;
	esac
}

check_initramfs() {
	local conf="/etc/initramfs-tools/initramfs.conf" content="" extra
	if [ "$(r_type $conf)" != file ]; then
		fail "$conf is missing" \
			"The initramfs is what mounts the overlay root; without initramfs-tools configuration the generated initrd is built from build-host assumptions."
	else
		content=$(r_cat "$conf" || true)
		while IFS= read -r extra; do
			[ -n "$extra" ] || continue
			if [ "$(r_type "$extra")" = file ]; then
				content="$content"$'\n'"$(r_cat "$extra" || true)"
			fi
		done < <(r_children /etc/initramfs-tools/conf.d)

		kv_assert() { # $1 key, $2 expected, $3 severity, $4 why
			local got
			got=$(printf '%s\n' "$content" | grep -E "^[[:space:]]*$1=" | tail -n 1 || true)
			got=${got#*=}
			got=${got%\"}; got=${got#\"}
			if [ "$got" = "$2" ]; then
				ok "initramfs.conf $1=$2"
			else
				bad "initramfs.conf $1 is '${got:-<unset>}', expected '$2'" "$4" "$3"
			fi
		}
		kv_assert MODULES list fail \
			"MODULES=dep infers the module list from the BUILD HOST, not from the target: on an x86 builder the initrd ends up without meson_gx_mmc and the slot never finds its root. The plan says never dep."
		kv_assert ROOTFSTYPE ext4 fail \
			"Without it initramfs-tools probes every filesystem type and pulls in modules the 512 MB box does not need; with it the ext4 module is guaranteed present."
		kv_assert RESUME none warn \
			"There is no swap and no hibernation; leaving RESUME auto costs a resume-device timeout on every boot."
		kv_assert COMPRESS gzip warn \
			"The plan pins gzip so the initrd stays loadable by the same tooling as the checked-in Yocto rescue cpio.gz."
	fi

	local ov=/etc/initramfs-tools/scripts/local-bottom/omni-overlay
	case "$(r_type "$ov")" in
	file)
		if r_exec "$ov"; then
			ok "$ov present and executable"
		else
			fail "$ov is not executable" \
				"initramfs-tools only copies and runs executable scripts; a non-executable local-bottom script is silently ignored and the box boots the LOWER filesystem read-write, dirtying the slot on every boot."
		fi
		if r_cat "$ov" | grep -q 'remount,ro'; then
			ok "$ov remounts the lower read-only"
		else
			warn "$ov does not mention 'remount,ro'" \
				"The cmdline is 'rootwait rw' with no 'ro', so initramfs-tools mounts the lower read-write; without the remount the slot is dirtied every boot and the A/B images stop being byte-identical."
		fi
		if r_cat "$ov" | grep -q 'panic'; then
			ok "$ov panics on failure"
		else
			warn "$ov never calls panic" \
				"The plan requires panic \"...\" on every failure so a fault lands you in the initramfs shell on serial instead of a silent hang in a closet."
		fi
		;;
	missing)
		fail "$ov is MISSING" \
			"This is the port of the Yocto initrd-apollo init: it mounts the overlay (upper = root partition + 4) and switch_roots into it. Without it the box boots the bare lower filesystem, which is not the running system anyone tested."
		;;
	*) fail "$ov is a $(r_type "$ov"), not a regular file" "" ;;
	esac
}

check_network_naming() {
	local d=/etc/systemd/network f n found_net=0 patterns="" link_forces=0 c
	if [ "$(r_type $d)" = missing ]; then
		fail "$d does not exist" \
			"The bootable minimum — an address on the interface and a running sshd — must live in the IMAGE. Nothing in /data is A/B-protected, and the plan explicitly forbids replicating the old 00-eth0.network -> /data symlink."
		return 0
	fi
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		case "$(r_type "$f")" in
		symlink)
			fail "$f is a symlink -> $(r_link "$f")" \
				"Network configuration must not be a symlink into /data: /data is shared and not A/B-protected, so a bad config there survives a rollback and strands the box."
			;;
		esac
		case "$f" in
		*.network)
			found_net=1
			c=$(r_cat "$f" 2>/dev/null || true)
			while IFS= read -r n; do
				n=${n#*=}
				patterns="$patterns $n"
			done < <(printf '%s\n' "$c" | grep -E '^[[:space:]]*Name=' || true)
			;;
		*.link)
			c=$(r_cat "$f" 2>/dev/null || true)
			if printf '%s\n' "$c" | grep -qE '^[[:space:]]*(NamePolicy|Name)='; then link_forces=1; fi
			;;
		esac
	done < <(r_children "$d")

	if [ "$found_net" -eq 1 ]; then
		ok "$d contains at least one .network"
	else
		fail "$d contains no .network file" \
			"With no address on the interface there is no SSH, and with bootdelay<0 no bootloader prompt either — the box in the closet is then serial-only."
	fi

	if [ "$link_forces" -eq 1 ]; then
		ok "a .link file forces the interface name"
		return 0
	fi
	if [ "$found_net" -eq 0 ]; then return 0; fi

	# The Name= values are systemd globs: split them on whitespace but NEVER
	# let the shell pathname-expand them against the current directory.
	local p matched=0 had_f=0
	case $- in *f*) had_f=1 ;; esac
	set -f
	for p in $patterns; do
		# shellcheck disable=SC2254  -- $p is deliberately a glob pattern
		case end0 in $p) matched=1 ;; esac
	done
	[ "$had_f" -eq 1 ] || set +f
	if [ "$matched" -eq 1 ]; then
		ok "a .network [Match] Name= pattern matches 'end0'"
	else
		fail "no [Match] Name= in $d matches 'end0' (patterns:$patterns)" \
			"The NIC will be named end0, not eth0: the aliases { ethernet0 = &ethmac; } you must keep for U-Boot's fdt_fixup_ethernet() is the same alias systemd-udev uses for DT-based naming (scheme v251+; kirkstone shipped systemd 250, trixie ships 257). Match on 'Name=e*' or ship a .link with NamePolicy= forcing eth0."
	fi
}

check_sshd() {
	local cfg=/etc/ssh/sshd_config content="" hostkeys="" f
	if [ "$(r_type $cfg)" != file ]; then
		fail "$cfg is missing (sshd is not installed in the image)" \
			"The plan's bootable minimum is an address on the interface AND a running sshd, in the image. Without sshd the only way in is the serial console with the case open."
		return 0
	fi
	content=$(r_cat "$cfg" || true)
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		case "$f" in *.conf)
			if [ "$(r_type "$f")" = file ]; then content="$content"$'\n'"$(r_cat "$f" || true)"; fi
			;;
		esac
	done < <(r_children /etc/ssh/sshd_config.d)

	hostkeys=$(printf '%s\n' "$content" | grep -E '^[[:space:]]*HostKey[[:space:]]' || true)
	if [ -z "$hostkeys" ]; then
		fail "no HostKey directive in $cfg (or sshd_config.d)" \
			"Per-slot host keys mean the fingerprint changes on every A/B flip and every reflash, which trains everyone to ignore the warning. The plan puts them in /data: HostKey /data/ssh/ssh_host_ed25519_key."
	elif printf '%s\n' "$hostkeys" | grep -q '/data/'; then
		ok "sshd host keys live on /data"
	else
		fail "sshd HostKey paths are not under /data: $(printf '%s' "$hostkeys" | tr '\n' ';')" \
			"/etc is per-slot (overlay upper p5/p6), so keys written there vanish on an A/B flip and reappear stale after a rollback. The plan relocates them to /data (p3)."
	fi

	local enabled=0
	for f in /etc/systemd/system/multi-user.target.wants/ssh.service \
		/etc/systemd/system/multi-user.target.wants/sshd.service \
		/etc/systemd/system/sockets.target.wants/ssh.socket; do
		if r_exists "$f"; then enabled=1; fi
	done
	if [ "$enabled" -eq 1 ]; then
		ok "sshd is enabled in the image"
	else
		fail "sshd is installed but not enabled (no multi-user.target.wants/ssh*.service)" \
			"mmdebstrap in --variant=important does not run enable presets the way a full install does. An installed-but-disabled sshd is indistinguishable from a dead network until you open the case."
	fi
}

check_modprobe_blacklist() {
	local f hit=0
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		case "$f" in *.conf) ;; *) continue ;; esac
		[ "$(r_type "$f")" = file ] || continue
		if r_cat "$f" | grep -qE '^[[:space:]]*blacklist[[:space:]]+meson[-_]nand'; then hit=1; fi
	done < <(r_children /etc/modprobe.d)
	if [ "$hit" -eq 1 ]; then
		ok "meson_nand is blacklisted in /etc/modprobe.d"
	else
		warn "no 'blacklist meson_nand' in /etc/modprobe.d" \
			"Belt and braces for CONFIG_MTD_NAND_MESON=n: mainline's nand-controller@7800 'emmc' reg region IS sd_emmc_c's window. If a stray config ever ships the module, it binds and takes the eMMC with it."
	fi
}

check_tailscale() {
	# Tailscale is optional (--no-tailscale), so absence is fine. What is NOT
	# fine is shipping it with its state on the per-slot overlay: the node
	# identity would be lost on the first A/B flip and the box would drop off
	# the tailnet after every update, on a headless unit.
	if [ "$(r_type /usr/sbin/tailscaled)" != file ]; then
		ok "tailscaled absent (image built without Tailscale)"
		return
	fi
	ok "tailscaled present"

	local d=/etc/systemd/system/tailscaled.service.d/10-omni.conf
	if [ "$(r_type "$d")" = file ] && r_cat "$d" | grep -q -- '--state=/data/tailscale/'; then
		ok "tailscaled state is pinned to /data (survives an A/B flip)"
	else
		fail "tailscaled ships without the /data state override" \
			"Default state is /var/lib/tailscale/tailscaled.state, which is inside the per-slot overlay upper (p5/p6). The node identity would then belong to one slot, and the first rollback or update would boot a slot that has never authenticated -- the device silently leaves the tailnet with no console attached."
	fi

	if [ "$(r_type /var/lib/tailscale)" = absent ]; then
		ok "/var/lib/tailscale does not exist (nothing to tempt the per-slot path)"
	else
		warn "/var/lib/tailscale exists in the image" \
			"Harmless on its own, but it is the path tailscaled and anyone debugging will reach for by default, which is precisely the per-slot trap."
	fi

	# A baked-in auth key would let the image enrol anything it is written to.
	local k
	for k in /data/tailscale/authkey /etc/tailscale/authkey /var/lib/tailscale/authkey; do
		if [ "$(r_type "$k")" = file ]; then
			fail "an auth key is baked into the image at $k" \
				"A pre-auth key is a credential. An image carrying one can enrol any device it is ever written to, and this image is meant to be reproducible and shareable. Keys belong on /data at provisioning time, never in the build."
			return
		fi
	done
	ok "no Tailscale auth key baked into the image"
}

check_hostname() {
	# mmdebstrap inherits the build host's /etc/hostname unless the image ships
	# one. The first build announced itself as "old-laptop" -- the machine that
	# built it. On a fleet device that is wrong, it leaks the builder's machine
	# name, and omni-tailscale-auth would register THAT name on the tailnet.
	local h
	if [ "$(r_type /etc/hostname)" != file ]; then
		fail "no /etc/hostname in the image" \
			"Without one the image takes the build host's hostname, so every device built anywhere announces the builder's machine name."
		return
	fi
	h=$(r_cat /etc/hostname | head -1 | tr -d ' \t\r')
	case "$h" in
	omni|omni-*) ok "/etc/hostname is '$h'" ;;
	'') fail "/etc/hostname is empty" "systemd falls back to 'localhost'." ;;
	*)  warn "/etc/hostname is '$h', which is not omni/omni-*" \
			"Check this is deliberate and not the build host's name leaking in again." ;;
	esac
}

check_ssh_authorized_keys() {
	# The lockout check. sshd_config.d/10-omni.conf sets PasswordAuthentication
	# no and the build locks root's password to '*', so a key is the ONLY way in
	# over the network. An image with hardened SSH and no key is reachable solely
	# over the serial console -- which on a deployed unit in a closet means a site
	# visit. That combination must fail the build, not surprise someone later.
	local f=/root/.ssh/authorized_keys keys=0 bad=0 line
	if [ "$(r_type "$f")" = file ]; then
		while IFS= read -r line; do
			case "$line" in
			''|'#'*) continue ;;
			ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*|sk-ssh-ed25519*|sk-ecdsa-*)
				keys=$((keys + 1)) ;;
			*) bad=$((bad + 1)) ;;
			esac
		done <<<"$(r_cat "$f")"
	fi

	if [ "$keys" -gt 0 ]; then
		ok "$f has $keys usable public key(s)"
	elif [ "$ALLOW_NO_SSH_KEY" = 1 ]; then
		warn "no usable public key in $f (--allow-no-ssh-key given)" \
			"This image is reachable only over the serial console. That is a deliberate choice here, not an accident -- but on a deployed unit in a closet it means a site visit."
	else
		fail "no usable public key in $f, but password authentication is disabled" \
			"PasswordAuthentication is no and root's password is locked to '*', so a key is the only network login. With none baked in, this image is reachable ONLY over the serial console. The key is a BUILD INPUT, not a committed file -- rebuild with --ssh-pubkey / --ssh-pubkey-file (or OMNI_SSH_PUBKEY), or pass --allow-no-ssh-key here and to build-rootfs.sh to accept serial-only access deliberately."
	fi
	[ "$bad" -gt 0 ] && warn "$bad unrecognised non-comment line(s) in $f" \
		"sshd ignores lines it cannot parse; a mangled key silently is not a key."

	# A private key here would be a serious mistake in a shareable image.
	local priv
	for priv in /root/.ssh/id_rsa /root/.ssh/id_ed25519 /root/.ssh/id_ecdsa; do
		if [ "$(r_type "$priv")" = file ]; then
			fail "a PRIVATE key is baked into the image at $priv" \
				"Every device written from this image would share one identity, and the key is in whatever repo or artefact store the image lives in. Only public keys belong in an image."
		fi
	done
}

check_data_symlinks() {
	local p t
	# NOTE: /root/.ssh is deliberately NOT in this list any more. The plan's
	# original design symlinked it into /data so keys survived an A/B flip, but
	# sshd_config.d/10-omni.conf supersedes that with
	#     AuthorizedKeysFile .ssh/authorized_keys /data/ssh/authorized_keys
	# which is strictly better: it reads BOTH locations, so keys survive a flip
	# via /data AND still work when /data is missing. A symlink would instead
	# dangle when p3 fails to mount -- and /data is nofail precisely so a bad p3
	# cannot stop the boot, which would then silently cost the only network
	# login. check_ssh_authorized_keys covers the image side.
	for p in /etc/wireguard; do
		t=$(r_type "$p")
		case "$t" in
		symlink)
			case "$(r_link "$p")" in
			/data/*) ok "$p is a symlink into /data" ;;
			*)
				warn "$p is a symlink to $(r_link "$p") (expected /data/...)" \
					"The plan keeps these on /data so they survive an A/B flip; /etc is per-slot via the overlay upper."
				;;
			esac
			;;
		missing)
			warn "$p does not exist" \
				"The plan bakes /root/.ssh and /etc/wireguard into the image as symlinks into /data (p3). Without them, keys and tunnels revert to that slot's stale state on every A/B flip."
			;;
		*)
			warn "$p is a $t, not a symlink into /data" \
				"Anything written under /etc or /root lands in the per-slot overlay upper (p5 for slot A, p6 for slot B) and reverts on an A/B flip."
			;;
		esac
	done
}

# --- ext4 -------------------------------------------------------------------

SB=""          # 4 KiB header of the image
EXT4_FEATURES=""
EXT4_BLOCKSIZE=""
EXT4_LABEL=""
EXT4_METHOD=""

sb_u32() { # $1 = offset within the superblock (which starts at byte 1024)
	local off=$((1024 + $1)) b
	b=$(od -An -tu1 -j "$off" -N 4 -v -- "$SB" | tr -s ' ' ' ')
	set -- $b
	printf '%s' $(( $1 + $2 * 256 + $3 * 65536 + $4 * 16777216 ))
}

sb_u16() {
	local off=$((1024 + $1)) b
	b=$(od -An -tu1 -j "$off" -N 2 -v -- "$SB" | tr -s ' ' ' ')
	set -- $b
	printf '%s' $(( $1 + $2 * 256 ))
}

bits_to_names() { # $1 = value, $2.. = "mask:name" pairs
	local v=$1 pair mask name out=""
	shift
	for pair in "$@"; do
		mask=${pair%%:*}
		name=${pair#*:}
		if [ $(( v & mask )) -ne 0 ]; then out="$out $name"; fi
	done
	printf '%s' "${out# }"
}

decode_superblock() {
	local magic compat incompat ro
	magic=$(sb_u16 56)
	[ "$magic" = 61267 ] || return 1 # 0xEF53
	compat=$(sb_u32 92)
	incompat=$(sb_u32 96)
	ro=$(sb_u32 100)
	EXT4_BLOCKSIZE=$(( 1024 << $(sb_u32 24) ))
	EXT4_LABEL=$(dd if="$SB" bs=1 skip=$((1024 + 120)) count=16 2>/dev/null | tr -d '\000')
	EXT4_FEATURES="$(bits_to_names "$compat" \
		4:has_journal 8:ext_attr 16:resize_inode 32:dir_index \
		512:sparse_super2 1024:fast_commit 2048:stable_inodes 4096:orphan_file) \
$(bits_to_names "$incompat" \
		2:filetype 4:recover 16:meta_bg 64:extent 128:64bit 256:mmp 512:flex_bg \
		1024:ea_inode 8192:metadata_csum_seed 16384:largedir 32768:inline_data \
		65536:encrypt 131072:casefold) \
$(bits_to_names "$ro" \
		1:sparse_super 2:large_file 4:btree_dir 8:huge_file 16:uninit_bg 32:dir_nlink \
		64:extra_isize 256:quota 512:bigalloc 1024:metadata_csum 4096:read-only \
		8192:project 32768:verity 65536:orphan_present)"
	# squeeze whitespace
	EXT4_FEATURES=$(printf '%s' "$EXT4_FEATURES" | tr -s ' \n' '  ')
	EXT4_METHOD="superblock decoder (dependency-free)"
	return 0
}

load_ext4_metadata() {
	mktmp
	SB=$TMP/sb.bin
	head_bytes "$IMAGE" 4096 >"$SB"
	if [ "$(hdr_hex "$SB" 1080 2)" != "53ef" ]; then
		return 1
	fi
	if have dumpe2fs && ! is_gzip "$IMAGE"; then
		local out
		out=$(dumpe2fs -h -- "$IMAGE" 2>/dev/null || true)
		if [ -n "$out" ]; then
			EXT4_FEATURES=$(printf '%s\n' "$out" | grep -E '^Filesystem features:' | head -n 1 || true)
			EXT4_FEATURES=${EXT4_FEATURES#*:}
			EXT4_BLOCKSIZE=$(printf '%s\n' "$out" | grep -E '^Block size:' | head -n 1 || true)
			EXT4_BLOCKSIZE=${EXT4_BLOCKSIZE#*:}
			EXT4_LABEL=$(printf '%s\n' "$out" | grep -E '^Filesystem volume name:' | head -n 1 || true)
			EXT4_LABEL=${EXT4_LABEL#*:}
			EXT4_FEATURES=$(printf '%s' "$EXT4_FEATURES" | tr -s ' ' ' ')
			EXT4_BLOCKSIZE=$(printf '%s' "$EXT4_BLOCKSIZE" | tr -d ' ')
			EXT4_LABEL=$(printf '%s' "$EXT4_LABEL" | tr -d ' ')
			EXT4_METHOD="dumpe2fs"
			return 0
		fi
	fi
	decode_superblock
}

has_feature() { # $1 = feature name
	case " $EXT4_FEATURES " in *" $1 "*) return 0 ;; esac
	return 1
}

check_ext4_features() {
	if [ -z "$IMAGE" ]; then
		skip "ext4-features" "no image given (pass omni-slot.ext4[.gz] or --image)"
		return 0
	fi
	if ! load_ext4_metadata; then
		fail "'$IMAGE' has no ext4 superblock at byte 1024" \
			"Either the file is not the packed slot image, or mke2fs never ran. U-Boot's ext4load and the kernel both key off this superblock."
		return 0
	fi
	say "${C_B}image:${C_0} $IMAGE  (${EXT4_METHOD})"
	say "${C_B}features:${C_0}$EXT4_FEATURES"

	local line feat sev why
	while IFS='|' read -r feat sev why; do
		case "${feat-}" in '' | '#'*) continue ;; esac
		if has_feature "$feat"; then
			bad "ext4 feature '$feat' is ENABLED on $IMAGE" "$why" "$sev"
		else
			ok "ext4 feature '$feat' is off"
		fi
	done <<<"$FORBIDDEN_EXT4_FEATURES"

	if [ "${EXT4_BLOCKSIZE:-0}" = 4096 ]; then
		ok "ext4 block size is 4096"
	else
		fail "ext4 block size is ${EXT4_BLOCKSIZE:-unknown}, expected 4096" \
			"The plan packs with mke2fs -b 4096 to match p1. A different block size changes the block count for a fixed partition size and can overrun the slot."
	fi

	if has_feature has_journal; then
		ok "ext4 has a journal"
	else
		warn "ext4 has no journal" \
			"p1 is a journalled ext4; an unjournalled slot turns any unclean power cut into an fsck the box cannot run headless."
	fi

	if [ "$EXT4_LABEL" = omni_root ]; then
		ok "ext4 label is omni_root"
	else
		warn "ext4 label is '${EXT4_LABEL:-<none>}', expected 'omni_root'" \
			"Cosmetic today (U-Boot addresses the slot by partition number, not label), but the plan pins -L omni_root and a surprise here usually means the mke2fs line drifted from the plan's."
	fi
}

check_ip_forwarding() {
	# If the image can advertise Tailscale subnet routes or an exit node, it
	# must also be able to forward. Those advertisements live in
	# /data/tailscale/tailscaled.state, which is SHARED by both A/B slots and
	# the recovery slot -- so any slot that boots re-advertises them, using the
	# same node identity, already approved in the control plane.
	#
	# An image that advertises but cannot forward fails silently: the tailnet
	# routes LAN traffic to this node and it drops every packet, with nothing in
	# any log. This check exists because the recovery image shipped exactly that
	# way once -- the sysctl was added to the A/B overlay and not to the
	# recovery one.
	local f=/etc/sysctl.d/99-omni-forwarding.conf c
	if [ "$(r_type "$f")" != file ]; then
		fail "$f is missing" \
			"Tailscale advertisements live on the SHARED /data, so this slot will advertise routes it cannot serve. The tailnet then blackholes LAN traffic through it, silently."
		return 0
	fi
	c=$(r_cat "$f" 2>/dev/null || printf '')
	case "$c" in
	*"net.ipv4.ip_forward = 1"*|*"net.ipv4.ip_forward=1"*)
		ok "$f enables net.ipv4.ip_forward" ;;
	*)
		fail "$f exists but does not set net.ipv4.ip_forward = 1" \
			"Forwarding off means every packet routed to this node is dropped, with no error anywhere." ;;
	esac
}

check_recovery() {
	# What p7 must have, and must NOT have. U-Boot boots it with init=/init and
	# no initrd, so /init is load-bearing: without it the slot does not start at
	# all, and it is the one file nothing else would notice missing.
	local t
	t=$(r_type /init)
	if [ "$t" = file ]; then
		if r_exec /init; then
			ok "/init is a real executable file"
		else
			fail "/init exists but is NOT executable (mode: $(r_mode /init))" \
				"U-Boot prepends init=/init to bootargs for every recovery path. A non-executable /init means PID 1 cannot start and the slot panics instead of booting."
		fi
	else
		fail "/init is $t (expected a regular executable file)" \
			"Every recovery path -- reset button, watchdog latch, force_hard_recovery -- boots p7 with init=/init. Without it the recovery slot does not boot at all, which is precisely when you need it."
	fi

	# The anti-loop guard. force_hard_recovery is a STORED variable that nothing
	# in U-Boot clears; without something clearing it, one remote recovery entry
	# becomes permanent and the only way out is a serial console.
	if [ "$(r_type /usr/lib/omni/omni-recovery-disarm)" = file ]; then
		ok "omni-recovery-disarm present"
	else
		fail "/usr/lib/omni/omni-recovery-disarm is missing" \
			"force_hard_recovery=1 is the only way into recovery without physical access, and nothing in U-Boot ever clears it. With no disarm, every later boot lands in recovery forever."
	fi
	if [ "$(r_type /etc/systemd/system/sysinit.target.wants/omni-recovery-disarm.service)" = symlink ] ||
	   [ "$(r_type /etc/systemd/system/sysinit.target.wants/omni-recovery-disarm.service)" = file ]; then
		ok "omni-recovery-disarm.service is enabled"
	else
		fail "omni-recovery-disarm.service is not enabled in sysinit.target.wants" \
			"An installed-but-not-enabled disarm is the same as no disarm."
	fi

	# A/B semantics must NOT leak into recovery.
	local u
	for u in omni-commit.service omni-deadman.service omni-deadman.timer; do
		# r_type says "missing", not "absent" -- getting this wrong inverts the
		# test and reports a correct image as broken.
		if [ "$(r_type "/etc/systemd/system/$u")" = missing ]; then
			ok "$u correctly absent from the recovery image"
		else
			fail "$u is present in the recovery image" \
				"Committing is an A/B notion and p7 is never armed; the deadman would reboot the very slot you booted to repair the box, on a 15 minute timer."
		fi
	done
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
say "${C_B}rootfs:${C_0} ${ROOTFS:-<none>}${RKIND:+ ($RKIND)}"
say ""

if [ -n "$ROOTFS" ]; then
	wanted armbian-install && check_armbian_install
	wanted armbian-packages && check_armbian_packages
	wanted serial-autologin && check_serial_autologin
	wanted fstab-cgroup && check_fstab_cgroup
	# omni-boot-defaults must run before boot-real-files: it resolves the names.
	if wanted omni-boot-defaults || wanted boot-real-files; then
		check_omni_boot_defaults
	fi
	wanted boot-real-files && check_boot_real_files
	wanted flatten-hooks && check_flatten_hooks
	wanted machine-id && check_machine_id
	if [ "$RECOVERY" = 1 ]; then
		wanted recovery && check_recovery
	else
		wanted initramfs && check_initramfs
	fi
	wanted network-naming && check_network_naming
	wanted sshd && check_sshd
	wanted modprobe-blacklist && check_modprobe_blacklist
	wanted hostname && check_hostname
	wanted ssh-authorized-keys && check_ssh_authorized_keys
	wanted tailscale && check_tailscale
	wanted data-symlinks && check_data_symlinks
	wanted ip-forwarding && check_ip_forwarding
else
	skip "rootfs checks" "no rootfs directory or tarball given"
fi

wanted ext4-features && check_ext4_features

say ""
if [ "$SKIPPED" -gt 0 ]; then printf 'skipped: %d\n' "$SKIPPED"; fi
if [ "$WARNED" -gt 0 ]; then printf 'warnings: %d (not fatal; re-run with --strict to enforce)\n' "$WARNED"; fi
printf '%d passed, %d failed\n' "$PASS" "$FAILED"

if [ "$FAILED" -gt 0 ]; then
	printf '%sFAILED%s: %d image invariant(s) from docs/ARMBIAN-MIGRATION.md are violated\n' \
		"$C_R" "$C_0" "$FAILED"
	exit 1
fi
exit 0

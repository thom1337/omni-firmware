#!/bin/bash
#
# build-rootfs.sh — build the Avast Omni Debian trixie A/B slot image.
#
# Produces <name>.ext4.gz + .sha256 + .size, which tools/omni-flash.sh consumes:
#   curl -fL "$URL" | gzip -dc | dd of=/dev/mmcblk0pN bs=1M iflag=fullblock conv=fsync
#   [ "$(head -c "$IMG_SIZE" /dev/mmcblk0pN | sha256sum | cut -d' ' -f1)" = "$IMG_SHA" ]
# so .sha256 and .size describe the UNCOMPRESSED image, not the .gz.
#
# This runs on a build host (normally inside rootfs/Dockerfile via build-in-docker.sh),
# never on the device. It needs no root on the host: mmdebstrap runs --mode=unshare and
# the ext4 packing step runs under container root, sudo, or a user namespace.
#
set -euo pipefail

PROG=${0##*/}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)

# --------------------------------------------------------------------------- defaults
SUITE=trixie
ARCH=arm64
MMDEBSTRAP_MODE=unshare
VARIANT=important
MIRROR=http://deb.debian.org/debian
SECURITY_MIRROR=http://security.debian.org/debian-security
COMPONENTS=main
WITH_SECURITY=1
WITH_RECOMMENDS=0
WITH_HEADERS=0
SLIM=1

NAME=omni-slot
LABEL=omni_root
# Fixed UUID: both slots are clones and are selected by device path (root=/dev/mmcblk0pN),
# never by UUID, so a shared UUID is intentional and keeps the image byte-reproducible.
FS_UUID=9f8e7d6c-5b4a-4392-8180-a1b2c3d4e5f6
BLOCK_SIZE=4096
# MEASURED ON THE DEVICE 2026-08-02, not a placeholder any more:
#   /dev/mmcblk0p1 and p2 are 891,289,600 bytes each (lsblk -b), and
#   891289600 / 4096 = 217600 exactly.
# The previous default of 262144 blocks (1024 MiB) was LARGER than the slot, so it
# would have produced an image that cannot be written -- caught only at flash time.
# SLOT_BYTES below is the hard ceiling asserted before mke2fs runs.
BLOCKS=217600            # 217600 * 4096 = 850 MiB = exactly one A/B slot
SLOT_BYTES=891289600     # measured size of p1/p2; see docs/HARDWARE.md
BLOCKS_EXPLICIT=0
BLOCKS_FROM=""

OUT_DIR="${SCRIPT_DIR}/out"
OVERLAY_DIR="${SCRIPT_DIR}/overlay"
USE_OVERLAY=1
PKG_FILE="${SCRIPT_DIR}/packages.list"
KERNEL_DEB_DIR=""
WORK_DIR=""
PACK_METHOD=auto

CONSOLE=ttyAML0
CONSOLE_BAUD=115200
IMAGE_HOSTNAME=omni
ROOT_PW_HASH=""

# Names U-Boot loads from inside the slot. GLOBAL, not per-slot. Overridden at runtime by
# /etc/default/omni-boot (populated in Phase 0 from fw_printenv, never from literals);
# these are only the fallback used when the overlay does not ship that file.
KERNEL_NAME=Image
DTB_NAME=meson-axg-apollo.dtb
RAMDISK_NAME=apollo-initramfs-image-meson-apollo.cpio.gz
ASSERT_BOOT=1
ALLOW_UNVERIFIED=0

KEEP_IMAGE=0
KEEP_WORK=0
DRY_RUN=0
VERBOSE=0

declare -a EXTRA_INCLUDE=() EXTRA_EXCLUDE=() EXTRA_UNITS=() MASK_UNITS=()

# ext4 feature policy. e2fsprogs 1.47 (trixie) defaults metadata_csum_seed and orphan_file
# ON; U-Boot 2018.09's ext4 reader predates both, and 64bit/metadata_csum too. Getting this
# wrong fails as an unbootable slot, not as a build error — hence the post-mke2fs assertion.
DISABLE_FEATURES=(64bit metadata_csum metadata_csum_seed orphan_file)
REQUIRE_FEATURES=(has_journal ext_attr filetype extent dir_index sparse_super)

# Packages that must never end up installed. flash-kernel and u-boot-menu write to the boot
# device; the armbian-* set drags in armbian-install, which repartitions eMMC.
FORBIDDEN_PACKAGES=(flash-kernel u-boot-menu armbian-bsp-cli armbian-bsp-desktop
                    armbian-config armbian-firmware ifupdown isc-dhcp-client
                    network-manager resolvconf openresolv)

# --------------------------------------------------------------------------- helpers
log()  { printf '%s\n' "==> $*" >&2; }
info() { printf '%s\n' "    $*" >&2; }
warn() { printf '%s\n' "WARNING: $*" >&2; }
die()  { printf '%s\n' "ERROR: $*" >&2; exit 1; }

need() {
	local t
	for t in "$@"; do
		command -v "$t" >/dev/null 2>&1 || die "required tool not found: $t (are you running inside rootfs/Dockerfile? try build-in-docker.sh)"
	done
}

usage() {
	cat <<EOF
$PROG — build the Avast Omni Debian ${SUITE} A/B slot image.

USAGE
  $PROG [options]
  build-in-docker.sh [options]      # same options, run inside the builder container

Builds an ${ARCH} Debian ${SUITE} rootfs with mmdebstrap (--mode=${MMDEBSTRAP_MODE},
--variant=${VARIANT}) and packs it into an ext4 image with a feature set pinned to what
U-Boot 2018.09 can read. Emits:

  <out>/<name>.ext4.gz          the slot image
  <out>/<name>.ext4.sha256      sha256 of the UNCOMPRESSED image (what omni-flash.sh checks)
  <out>/<name>.ext4.size        size in bytes of the UNCOMPRESSED image
  <out>/<name>.ext4.gz.sha256   sha256 of the .gz (transport integrity)
  <out>/<name>.manifest         build provenance
  <out>/<name>.packages         dpkg -W of everything installed

INPUTS
  --kernel-debs DIR     Armbian linux-image/linux-dtb .debs. Default: first non-empty of
                        ${SCRIPT_DIR}/kernel-debs, ${REPO_ROOT}/armbian/output/debs.
                        Empty or missing is a hard error.
  --with-headers        also install linux-headers-*.deb (large; off by default)
  --overlay DIR         tree copied verbatim into the rootfs. Default ${OVERLAY_DIR}
  --no-overlay          build with no overlay. The result has no overlay-root initramfs
                        script and no kernel flatten hooks: NOT bootable. Testing only.
  --packages FILE       package list. Default ${PKG_FILE}
  --include PKG         extra package (repeatable)
  --exclude PKG         drop a package from the list (repeatable)
  --with-recommends     install Recommends (default: off)
  --no-slim             keep /usr/share/{doc,man,info} and locales (default: stripped)

DEBIAN
  --suite SUITE         default ${SUITE}
  --arch ARCH           default ${ARCH}
  --mirror URL          default ${MIRROR}
  --security-mirror URL default ${SECURITY_MIRROR}
  --no-security         omit the -security and -updates suites
  --components LIST     default ${COMPONENTS}
  --mode MODE           mmdebstrap mode, default ${MMDEBSTRAP_MODE}

FILESYSTEM
  --blocks N            ext4 block count in ${BLOCK_SIZE}-byte blocks. Default ${BLOCKS}
  --size-mib N          same, expressed in MiB
  --blocks-from FILE    read the block count out of a saved 'dumpe2fs -h /dev/mmcblk0p1'
                        capture from Phase 0. This is the correct way to set it.
  --uuid UUID           default ${FS_UUID}
  --label LABEL         default ${LABEL}
  --name NAME           output basename, default ${NAME}
  --pack-method M       auto|root|sudo|unshare (default auto)

IMAGE CONTENT
  --console TTY         serial console for the autologin getty, default ${CONSOLE}
  --console-baud N      default ${CONSOLE_BAUD}
  --hostname NAME       default ${IMAGE_HOSTNAME}
  --root-password-hash H  crypt(3) hash for root. Default: root password locked ('*').
                        Serial autologin still works (login -f skips authentication).
  --enable-unit U       extra systemd unit to enable (repeatable; prefix '?' = optional)
  --mask-unit U         systemd unit to mask (repeatable)
  --kernel-name N       default ${KERNEL_NAME}
  --dtb-name N          default ${DTB_NAME}
  --ramdisk-name N      default ${RAMDISK_NAME}
  --no-assert-boot      do not fail when /boot/<kernel|dtb|ramdisk> are missing
  --allow-unverified-boot-names
                        build even though the overlay's /etc/default/omni-boot still has
                        OMNI_BOOT_VERIFIED="no". By default the build FAILS CLOSED there:
                        the three names U-Boot loads are global and must be captured
                        verbatim from the device (pre-flight P4), never typed from the
                        U-Boot patches. Test images only.

MISC
  --out DIR             default ${OUT_DIR}
  --work DIR            scratch directory (default: mktemp under \$TMPDIR)
  --keep-image          keep the uncompressed .ext4 alongside the .gz
  --keep-work           do not delete the scratch directory
  -n, --dry-run         validate every precondition, print every command, write nothing
  -v, --verbose         pass --verbose to mmdebstrap
  -h, --help            this text

BLOCK COUNT
  The default (${BLOCKS} blocks = $((BLOCKS / 256)) MiB) is a PLACEHOLDER. The real value is
  p1's block count, captured in Phase 0:
      ssh root@omni 'dumpe2fs -h /dev/mmcblk0p1' > omni-p1-dumpe2fs.txt
      $PROG --blocks-from omni-p1-dumpe2fs.txt
  Too large and omni-flash.sh refuses the write (it checks blockdev --getsize64 first).
  Too small and mke2fs fails at build time. Both failures are loud; neither corrupts a slot.

EXIT
  0 on success, non-zero on any failed precondition or assertion.
EOF
}

# --------------------------------------------------------------------------- args
while [ $# -gt 0 ]; do
	case "$1" in
	--kernel-debs)      KERNEL_DEB_DIR=${2:?--kernel-debs needs a value}; shift 2;;
	--with-headers)     WITH_HEADERS=1; shift;;
	--overlay)          OVERLAY_DIR=${2:?--overlay needs a value}; shift 2;;
	--no-overlay)       USE_OVERLAY=0; shift;;
	--packages)         PKG_FILE=${2:?--packages needs a value}; shift 2;;
	--include)          EXTRA_INCLUDE+=("${2:?--include needs a value}"); shift 2;;
	--exclude)          EXTRA_EXCLUDE+=("${2:?--exclude needs a value}"); shift 2;;
	--with-recommends)  WITH_RECOMMENDS=1; shift;;
	--no-slim)          SLIM=0; shift;;
	--suite)            SUITE=${2:?--suite needs a value}; shift 2;;
	--arch)             ARCH=${2:?--arch needs a value}; shift 2;;
	--mirror)           MIRROR=${2:?--mirror needs a value}; shift 2;;
	--security-mirror)  SECURITY_MIRROR=${2:?--security-mirror needs a value}; shift 2;;
	--no-security)      WITH_SECURITY=0; shift;;
	--components)       COMPONENTS=${2:?--components needs a value}; shift 2;;
	--mode)             MMDEBSTRAP_MODE=${2:?--mode needs a value}; shift 2;;
	--blocks)           BLOCKS=${2:?--blocks needs a value}; BLOCKS_EXPLICIT=1; shift 2;;
	--size-mib)         BLOCKS=$(( ${2:?--size-mib needs a value} * 1048576 / BLOCK_SIZE )); BLOCKS_EXPLICIT=1; shift 2;;
	--blocks-from)      BLOCKS_FROM=${2:?--blocks-from needs a value}; BLOCKS_EXPLICIT=1; shift 2;;
	--uuid)             FS_UUID=${2:?--uuid needs a value}; shift 2;;
	--label)            LABEL=${2:?--label needs a value}; shift 2;;
	--name)             NAME=${2:?--name needs a value}; shift 2;;
	--pack-method)      PACK_METHOD=${2:?--pack-method needs a value}; shift 2;;
	--console)          CONSOLE=${2:?--console needs a value}; shift 2;;
	--console-baud)     CONSOLE_BAUD=${2:?--console-baud needs a value}; shift 2;;
	--hostname)         IMAGE_HOSTNAME=${2:?--hostname needs a value}; shift 2;;
	--root-password-hash) ROOT_PW_HASH=${2:?--root-password-hash needs a value}; shift 2;;
	--enable-unit)      EXTRA_UNITS+=("${2:?--enable-unit needs a value}"); shift 2;;
	--mask-unit)        MASK_UNITS+=("${2:?--mask-unit needs a value}"); shift 2;;
	--kernel-name)      KERNEL_NAME=${2:?--kernel-name needs a value}; shift 2;;
	--dtb-name)         DTB_NAME=${2:?--dtb-name needs a value}; shift 2;;
	--ramdisk-name)     RAMDISK_NAME=${2:?--ramdisk-name needs a value}; shift 2;;
	--no-assert-boot)   ASSERT_BOOT=0; shift;;
	--allow-unverified-boot-names) ALLOW_UNVERIFIED=1; shift;;
	--out)              OUT_DIR=${2:?--out needs a value}; shift 2;;
	--work)             WORK_DIR=${2:?--work needs a value}; shift 2;;
	--keep-image)       KEEP_IMAGE=1; shift;;
	--keep-work)        KEEP_WORK=1; shift;;
	-n|--dry-run)       DRY_RUN=1; shift;;
	-v|--verbose)       VERBOSE=1; shift;;
	-h|--help)          usage; exit 0;;
	*) printf 'ERROR: unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2;;
	esac
done

# --------------------------------------------------------------------------- validation
need mmdebstrap tar gzip sha256sum sed grep find awk sort mke2fs dumpe2fs e2fsck truncate

case "$PACK_METHOD" in auto|root|sudo|unshare) ;; *) die "--pack-method must be auto|root|sudo|unshare";; esac

[ "$(id -u)" -ne 0 ] || [ "$MMDEBSTRAP_MODE" != unshare ] || \
	warn "running as uid 0 with --mode=unshare; if mmdebstrap objects, re-run with --mode=root"

# Foreign-architecture execution. binfmt_misc is NOT namespaced, so this is the host's
# registration even when we are inside a container.
if [ "$ARCH" != "$(dpkg --print-architecture 2>/dev/null || echo unknown)" ]; then
	if command -v arch-test >/dev/null 2>&1; then
		arch-test "$ARCH" >/dev/null 2>&1 || die \
"cannot execute ${ARCH} binaries on this host (arch-test ${ARCH} failed).
binfmt_misc is a host-kernel property; installing qemu inside the container is not enough.
Fix on the HOST, then re-run:
    docker run --privileged --rm tonistiigi/binfmt --install arm64
  or
    sudo apt-get install qemu-user-static binfmt-support"
	else
		warn "arch-test not installed; cannot verify that ${ARCH} binaries are runnable"
	fi
fi

# If the host registration lacks the F (fix-binary) flag, the interpreter must be visible
# from inside the chroot, so copy it in with a setup-hook.
QEMU_STATIC=""
for reg in /proc/sys/fs/binfmt_misc/qemu-"${ARCH}"*; do
	[ -f "$reg" ] || continue
	grep -qx 'enabled' "$reg" || continue
	if ! grep -q '^flags:.*F' "$reg"; then
		QEMU_STATIC=$(sed -n 's/^interpreter //p' "$reg" | head -n1)
		[ -n "$QEMU_STATIC" ] && [ -x "$QEMU_STATIC" ] || die \
			"binfmt registration $reg has no F flag and its interpreter '$QEMU_STATIC' is not executable here"
		info "binfmt has no F flag; will copy $QEMU_STATIC into the chroot"
	fi
	break
done

# Kernel debs.
if [ -z "$KERNEL_DEB_DIR" ]; then
	for cand in "${SCRIPT_DIR}/kernel-debs" "${REPO_ROOT}/armbian/output/debs"; do
		if [ -d "$cand" ] && [ -n "$(find "$cand" -maxdepth 1 -name '*.deb' -print -quit)" ]; then
			KERNEL_DEB_DIR=$cand; break
		fi
	done
fi
[ -n "$KERNEL_DEB_DIR" ] || die \
"no kernel .deb directory found.
Looked in:
    ${SCRIPT_DIR}/kernel-debs
    ${REPO_ROOT}/armbian/output/debs
Build the kernel first (Phase 2/6):
    ./compile.sh kernel BOARD=avast-omni BRANCH=oldlts
then copy linux-image-*.deb and linux-dtb-*.deb into ${SCRIPT_DIR}/kernel-debs,
or pass --kernel-debs DIR."
[ -d "$KERNEL_DEB_DIR" ] || die "--kernel-debs: not a directory: $KERNEL_DEB_DIR"
KERNEL_DEB_DIR=$(cd -- "$KERNEL_DEB_DIR" && pwd)

mapfile -t KERNEL_DEBS < <(find "$KERNEL_DEB_DIR" -maxdepth 1 -type f -name 'linux-image-*.deb' | sort)
mapfile -t DTB_DEBS    < <(find "$KERNEL_DEB_DIR" -maxdepth 1 -type f -name 'linux-dtb-*.deb'   | sort)
[ ${#KERNEL_DEBS[@]} -gt 0 ] || die \
"no linux-image-*.deb in ${KERNEL_DEB_DIR} — refusing to build a rootfs with no kernel.
Directory contains: $(find "$KERNEL_DEB_DIR" -maxdepth 1 -type f -printf '%f ' 2>/dev/null || echo '(nothing)')"
[ ${#DTB_DEBS[@]} -gt 0 ] || die \
"no linux-dtb-*.deb in ${KERNEL_DEB_DIR}. Without it there is no ${DTB_NAME} to flatten into
/boot and U-Boot's ext4load of \${mender_dtb_name} fails. Copy the linux-dtb deb in, or pass
--no-assert-boot if you really mean to build a DTB-less image."

INSTALL_DEBS=("${KERNEL_DEBS[@]}" "${DTB_DEBS[@]}")
if [ "$WITH_HEADERS" = 1 ]; then
	mapfile -t HDR_DEBS < <(find "$KERNEL_DEB_DIR" -maxdepth 1 -type f -name 'linux-headers-*.deb' | sort)
	[ ${#HDR_DEBS[@]} -gt 0 ] || die "--with-headers given but no linux-headers-*.deb in $KERNEL_DEB_DIR"
	INSTALL_DEBS+=("${HDR_DEBS[@]}")
fi

# Overlay.
if [ "$USE_OVERLAY" = 1 ]; then
	[ -d "$OVERLAY_DIR" ] || die \
"overlay tree not found: ${OVERLAY_DIR}
It carries the overlay-root initramfs script, /etc/default/omni-boot, the kernel flatten
hooks, the network config, sshd config and the omni-* units. Without it the image cannot
boot. Pass --overlay DIR, or --no-overlay if you are deliberately building a test image."
	[ -n "$(find "$OVERLAY_DIR" -mindepth 1 -print -quit)" ] || die "overlay tree is empty: ${OVERLAY_DIR}"
	OVERLAY_DIR=$(cd -- "$OVERLAY_DIR" && pwd)

	# Check the fail-closed boot-name gate on the host, before spending 20 minutes on a
	# bootstrap that hook 50 would then reject. Same rule, enforced twice.
	OB="${OVERLAY_DIR}/etc/default/omni-boot"
	if [ -r "$OB" ]; then
		verified=$(sed -n 's/^[[:space:]]*OMNI_BOOT_VERIFIED=["'"'"']\?\([^"'"'"']*\)["'"'"']\?.*/\1/p' "$OB" | tail -n1)
		if [ "${verified:-no}" != yes ]; then
			if [ "$ALLOW_UNVERIFIED" = 1 ]; then
				warn "OMNI_BOOT_VERIFIED=\"${verified:-no}\" in ${OB#$REPO_ROOT/}; building anyway (--allow-unverified-boot-names)."
				warn "The resulting image must not be armed on a device."
			else
				die \
"${OB#$REPO_ROOT/} still has OMNI_BOOT_VERIFIED=\"${verified:-no}\".

The three names U-Boot loads out of /boot are GLOBAL (shared with the Yocto slot) and live in
the device's stored environment. A field U-Boot may predate patches 0050/0051, so the compiled
defaults in that file are not device truth. Capture them (pre-flight P4):

    ssh root@omni 'fw_printenv mender_kernel_name mender_dtb_name mender_ramdisk_name'

write the values into ${OB#$REPO_ROOT/}, set OMNI_BOOT_VERIFIED=\"yes\", and re-run.
For a throwaway test image: --allow-unverified-boot-names"
			fi
		else
			info "boot artefact names verified (OMNI_BOOT_VERIFIED=yes)"
		fi
	else
		warn "overlay has no etc/default/omni-boot; the flatten hooks will fall back to compiled-in names"
	fi
else
	warn "building with --no-overlay: the resulting image is NOT bootable on the device"
	OVERLAY_DIR=""
fi

# Package list.
[ -r "$PKG_FILE" ] || die "package list not readable: $PKG_FILE"
mapfile -t PKGS < <(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$PKG_FILE" | grep -v '^$' | sort -u)
[ ${#PKGS[@]} -gt 0 ] || die "package list ${PKG_FILE} contains no packages"
if [ ${#EXTRA_EXCLUDE[@]} -gt 0 ]; then
	for x in "${EXTRA_EXCLUDE[@]}"; do
		printf '%s\n' "${PKGS[@]}" | grep -qx "$x" || warn "--exclude $x: not in $PKG_FILE"
		mapfile -t PKGS < <(printf '%s\n' "${PKGS[@]}" | grep -vx "$x" || true)
	done
fi
[ ${#EXTRA_INCLUDE[@]} -gt 0 ] && PKGS+=("${EXTRA_INCLUDE[@]}")
mapfile -t PKGS < <(printf '%s\n' "${PKGS[@]}" | sort -u)
for f in "${FORBIDDEN_PACKAGES[@]}"; do
	printf '%s\n' "${PKGS[@]}" | grep -qx "$f" && die \
		"package list requests '$f', which is on the forbidden list (see packages.list). Refusing."
done
PKGS_CSV=$(IFS=,; printf '%s' "${PKGS[*]}")

# Block count.
if [ -n "$BLOCKS_FROM" ]; then
	[ -r "$BLOCKS_FROM" ] || die "--blocks-from: not readable: $BLOCKS_FROM"
	bc_count=$(sed -n 's/^Block count:[[:space:]]*\([0-9]\+\).*/\1/p' "$BLOCKS_FROM" | head -n1)
	bc_size=$(sed  -n 's/^Block size:[[:space:]]*\([0-9]\+\).*/\1/p'  "$BLOCKS_FROM" | head -n1)
	[ -n "$bc_count" ] && [ -n "$bc_size" ] || die \
		"--blocks-from: could not find 'Block count:' and 'Block size:' in $BLOCKS_FROM (expected dumpe2fs -h output)"
	bytes=$(( bc_count * bc_size ))
	[ $(( bytes % BLOCK_SIZE )) -eq 0 ] || die \
		"--blocks-from: source filesystem is ${bytes} bytes, not a multiple of ${BLOCK_SIZE}"
	BLOCKS=$(( bytes / BLOCK_SIZE ))
	info "--blocks-from ${BLOCKS_FROM}: ${bc_count} x ${bc_size} = ${bytes} bytes -> ${BLOCKS} blocks of ${BLOCK_SIZE}"
fi
[[ "$BLOCKS" =~ ^[0-9]+$ ]] || die "block count must be an integer: $BLOCKS"
[ "$BLOCKS" -ge 65536 ] || die "block count ${BLOCKS} ($((BLOCKS/256)) MiB) is implausibly small"
IMG_BYTES=$(( BLOCKS * BLOCK_SIZE ))
# Hard ceiling. An image larger than the slot is not a warning, it is an image that
# physically cannot be written -- and without this the only thing that notices is
# omni-flash.sh, on the device, after the download. SLOT_BYTES was measured on the
# unit (docs/HARDWARE.md); override it with --slot-bytes if a different unit differs.
if [ -n "${SLOT_BYTES:-}" ] && [ "$IMG_BYTES" -gt "$SLOT_BYTES" ]; then
	die "image would be ${IMG_BYTES} bytes ($((IMG_BYTES/1048576)) MiB) but an A/B slot is only ${SLOT_BYTES} bytes ($((SLOT_BYTES/1048576)) MiB). Lower --blocks (max $((SLOT_BYTES / BLOCK_SIZE)))."
fi
if [ "$BLOCKS_EXPLICIT" = 0 ]; then
	info "using the measured default block count ${BLOCKS} ($((BLOCKS/256)) MiB) = exactly one A/B slot."
	info "Override with --blocks-from once you have a dumpe2fs of p1 from another unit:"
	warn "    ssh root@omni 'dumpe2fs -h /dev/mmcblk0p1' > omni-p1-dumpe2fs.txt"
fi

case "$FS_UUID" in
	[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-*) ;;
	*) die "--uuid does not look like a UUID: $FS_UUID";;
esac
[ "${#LABEL}" -le 16 ] || die "ext4 volume label is limited to 16 bytes: '$LABEL'"

# --------------------------------------------------------------------------- work dir
if [ -z "$WORK_DIR" ]; then
	WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/omni-rootfs.XXXXXXXX")
	MADE_WORK=1
else
	MADE_WORK=0
fi
case "$WORK_DIR" in
	*[[:space:]]*) die "--work path must not contain whitespace (mmdebstrap hooks are shell-quoted): $WORK_DIR";;
esac
mkdir -p "$WORK_DIR"
WORK_DIR=$(cd -- "$WORK_DIR" && pwd)
# mmdebstrap --mode=unshare runs its customize-hooks inside a user namespace in
# which our uid is mapped to a subuid, so a scratch dir owned by the invoking
# user is NOT writable from a hook. Hook 60 writes packages.installed here, and
# without this it dies with "Permission denied" after the whole rootfs has been
# built -- i.e. at the most expensive possible moment. This is build scratch,
# never shipped, so widening it is safe.
chmod 0777 "$WORK_DIR" 2>/dev/null || true
HOOK_DIR="${WORK_DIR}/hooks"
ROOTDIR="${WORK_DIR}/rootdir"
TARBALL="${WORK_DIR}/${NAME}.tar"
IMG="${WORK_DIR}/${NAME}.ext4"

cleanup() {
	local rc=$?
	if [ "$KEEP_WORK" = 1 ]; then
		[ "$rc" = 0 ] || info "scratch kept at ${WORK_DIR}"
	elif [ "$DRY_RUN" = 0 ]; then
		rm -rf -- "${HOOK_DIR}" "${TARBALL}" "${WORK_DIR}/pack.sh" "${WORK_DIR}/pack.conf" 2>/dev/null || true
		[ "$MADE_WORK" = 1 ] && rmdir -- "$WORK_DIR" 2>/dev/null || true
	fi
	return $rc
}
trap cleanup EXIT

# --------------------------------------------------------------------------- ext4 features
# Only pass ^feature for features this e2fsprogs actually knows about: 1.46 does not know
# orphan_file and would abort with "Invalid filesystem option set". Probe with mke2fs -n,
# which validates the options without writing anything.
probe_file="${WORK_DIR}/.mke2fs-probe.img"
truncate -s 8M "$probe_file"
SUPPORTED_DISABLE=()
for feat in "${DISABLE_FEATURES[@]}"; do
	if mke2fs -n -q -F -t ext4 -b "$BLOCK_SIZE" -O "^${feat}" "$probe_file" 2048 >/dev/null 2>&1; then
		SUPPORTED_DISABLE+=("^${feat}")
	else
		warn "this e2fsprogs does not know feature '${feat}'; it cannot be enabled either, so skipping ^${feat}"
	fi
done
rm -f -- "$probe_file"
[ ${#SUPPORTED_DISABLE[@]} -gt 0 ] || die "mke2fs rejected every feature in the disable list; refusing to guess"
OFEAT=$(IFS=,; printf '%s' "${SUPPORTED_DISABLE[*]}")
EOPTS="root_owner=0:0,lazy_itable_init=0,lazy_journal_init=0"

# --------------------------------------------------------------------------- units to enable
declare -a ENABLE_UNITS=(
	systemd-networkd.service
	systemd-resolved.service
	'?systemd-timesyncd.service'
	ssh.service
	"serial-getty@${CONSOLE}.service"
	'?data.mount'
)
if [ -n "$OVERLAY_DIR" ]; then
	# Anything the overlay ships called omni-* gets enabled. A unit with no [Install]
	# section (e.g. one started only by its .timer) is reported and skipped; a unit that
	# HAS an [Install] section and still fails to enable is a hard error.
	for d in etc/systemd/system usr/lib/systemd/system lib/systemd/system; do
		[ -d "${OVERLAY_DIR}/${d}" ] || continue
		while IFS= read -r u; do
			[ -n "$u" ] && ENABLE_UNITS+=("$u")
		done < <(find "${OVERLAY_DIR}/${d}" -maxdepth 1 -type f \
			\( -name 'omni-*.service' -o -name 'omni-*.timer' -o -name 'omni-*.path' \
			   -o -name 'omni-*.mount' -o -name 'omni-*.target' \) -printf '%f\n' | sort -u)
	done
fi
[ ${#EXTRA_UNITS[@]} -gt 0 ] && ENABLE_UNITS+=("${EXTRA_UNITS[@]}")

# --------------------------------------------------------------------------- hook scripts
mkdir -p "$HOOK_DIR"

# 10 — overlay tree. Extracted here rather than with mmdebstrap's sync-in, whose semantics
# make the target match the source (it deletes); sync-in to / would empty the rootfs.
cat >"${HOOK_DIR}/10-overlay.sh" <<'HOOK10'
#!/bin/sh
set -eu
chroot_dir=$1
[ -n "${OMNI_OVERLAY_TAR:-}" ] || { echo "I: 10-overlay: no overlay, skipping"; exit 0; }
echo "I: 10-overlay: unpacking overlay tree"
tar -C "$chroot_dir" --numeric-owner -xpf "$OMNI_OVERLAY_TAR"

# Anything git checked out without the exec bit here is a hook that silently never runs.
# These directories are all "executable or it does nothing" by definition.
for d in /etc/kernel/postinst.d /etc/kernel/postrm.d /etc/kernel/preinst.d \
         /etc/initramfs/post-update.d \
         /etc/initramfs-tools/scripts/init-top /etc/initramfs-tools/scripts/init-bottom \
         /etc/initramfs-tools/scripts/local-top /etc/initramfs-tools/scripts/local-bottom \
         /etc/initramfs-tools/scripts/local-premount /etc/initramfs-tools/hooks \
         /etc/network/if-up.d /usr/local/bin /usr/local/sbin /usr/lib/omni /usr/libexec/omni; do
	[ -d "${chroot_dir}${d}" ] || continue
	find "${chroot_dir}${d}" -maxdepth 1 -type f -exec chmod 0755 {} +
	echo "I: 10-overlay: chmod 0755 ${d}/*"
done

# Modes that matter for correctness, not convenience.
[ -d "${chroot_dir}/root/.ssh" ]     && chmod 0700 "${chroot_dir}/root/.ssh"
[ -d "${chroot_dir}/etc/wireguard" ] && chmod 0700 "${chroot_dir}/etc/wireguard"
[ -d "${chroot_dir}/etc/ssh" ]       && chmod 0755 "${chroot_dir}/etc/ssh"
for k in "${chroot_dir}"/etc/ssh/ssh_host_*_key "${chroot_dir}"/etc/wireguard/*.key; do
	[ -f "$k" ] && chmod 0600 "$k"
done
exit 0
HOOK10

# 20 — Armbian kernel. Runs AFTER the overlay so the linux-image postinst can already see
# /etc/default/omni-boot, /etc/kernel/postinst.d/zz-omni-flatten, the initramfs-tools
# config and the overlay-root script when it regenerates the initrd.
cat >"${HOOK_DIR}/20-kernel.sh" <<'HOOK20'
#!/bin/sh
set -eu
chroot_dir=$1
: "${OMNI_KERNEL_DEB_LIST:?20-kernel: OMNI_KERNEL_DEB_LIST not set}"
stage=/tmp/omni-kernel-debs
mkdir -p "${chroot_dir}${stage}"
n=0
while IFS= read -r deb; do
	[ -n "$deb" ] || continue
	[ -f "$deb" ] || { echo "E: 20-kernel: missing $deb" >&2; exit 1; }
	cp -- "$deb" "${chroot_dir}${stage}/"
	n=$((n + 1))
done < "$OMNI_KERNEL_DEB_LIST"
[ "$n" -gt 0 ] || { echo "E: 20-kernel: no kernel debs to install" >&2; exit 1; }
echo "I: 20-kernel: installing ${n} kernel deb(s)"

# apt resolves the debs' dependencies from the archive; dpkg -i + apt -f is the fallback
# for the case where apt refuses a local .deb (e.g. an unsigned local path policy).
chroot "$chroot_dir" /bin/sh -eu -c "
	cd ${stage}
	if apt-get install -y --no-install-recommends ./*.deb; then
		:
	else
		echo 'W: apt-get install of local debs failed, falling back to dpkg -i' >&2
		dpkg -i ./*.deb || true
		apt-get -y -f install
	fi
	dpkg -l 'linux-image*' 'linux-dtb*' | grep '^ii' || true
"
rm -rf -- "${chroot_dir}${stage}"
exit 0
HOOK20

# 30 — systemd enablement.
cat >"${HOOK_DIR}/30-systemd.sh" <<'HOOK30'
#!/bin/sh
set -eu
chroot_dir=$1

unit_path() {
	# $1 = unit name; resolves templates (foo@bar.service -> foo@.service)
	_u=$1
	case "$_u" in *@*.*) _f=${_u%%@*}@.${_u##*.};; *) _f=$_u;; esac
	for _d in /etc/systemd/system /usr/lib/systemd/system /lib/systemd/system; do
		if [ -f "${chroot_dir}${_d}/${_f}" ]; then printf '%s\n' "${chroot_dir}${_d}/${_f}"; return 0; fi
	done
	return 1
}

for spec in ${OMNI_ENABLE_UNITS:-}; do
	optional=0
	case "$spec" in '?'*) optional=1; unit=${spec#?};; *) unit=$spec;; esac
	if ! path=$(unit_path "$unit"); then
		if [ "$optional" = 1 ]; then
			echo "I: 30-systemd: optional unit ${unit} not present, skipping"
			continue
		fi
		echo "E: 30-systemd: required unit ${unit} is not in the image" >&2
		exit 1
	fi
	if chroot "$chroot_dir" systemctl enable "$unit" >/dev/null 2>&1; then
		echo "I: 30-systemd: enabled ${unit}"
	elif grep -q '^\[Install\]' "$path"; then
		echo "E: 30-systemd: ${unit} has an [Install] section but could not be enabled" >&2
		chroot "$chroot_dir" systemctl enable "$unit" >&2 || true
		exit 1
	else
		echo "I: 30-systemd: ${unit} has no [Install] section (timer/socket activated), nothing to enable"
	fi
done

for unit in ${OMNI_MASK_UNITS:-}; do
	chroot "$chroot_dir" systemctl mask "$unit" >/dev/null 2>&1 \
		&& echo "I: 30-systemd: masked ${unit}" \
		|| { echo "E: 30-systemd: could not mask ${unit}" >&2; exit 1; }
done
exit 0
HOOK30

# 40 — serial autologin. Today's console is passwordless root; losing it means no network =
# no login at all, since there is no display and the bootloader prompt needs bootdelay >= 0.
cat >"${HOOK_DIR}/40-serial.sh" <<'HOOK40'
#!/bin/sh
set -eu
chroot_dir=$1
tty=${OMNI_CONSOLE:?40-serial: OMNI_CONSOLE not set}
baud=${OMNI_CONSOLE_BAUD:-115200}
dropin="${chroot_dir}/etc/systemd/system/serial-getty@${tty}.service.d"

if [ -f "${dropin}/autologin.conf" ]; then
	echo "I: 40-serial: overlay already ships ${dropin#$chroot_dir}/autologin.conf, keeping it"
else
	mkdir -p "$dropin"
	cat >"${dropin}/autologin.conf" <<EOF
# Serial console autologin for ${tty}.
# The Yocto firmware this replaces had a passwordless root console
# (systemd-serialgetty/access.conf: ACCESS=-aroot). Keep that property: harden SSH, never
# the console. agetty --autologin uses login -f, which skips authentication, so this works
# with root's password locked.
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -- \\\\u' --autologin root --keep-baud ${baud},57600,38400,9600 %I \$TERM
EOF
	echo "I: 40-serial: wrote autologin drop-in for serial-getty@${tty}.service"
fi

# agetty consults /etc/securetty on some configurations; make sure the console is listed if
# the file exists at all.
if [ -f "${chroot_dir}/etc/securetty" ] && ! grep -qx "$tty" "${chroot_dir}/etc/securetty"; then
	printf '%s\n' "$tty" >>"${chroot_dir}/etc/securetty"
	echo "I: 40-serial: added ${tty} to /etc/securetty"
fi
grep -q "$tty" "${dropin}/autologin.conf"
exit 0
HOOK40

# 50 — initramfs + /boot flattening. U-Boot loads exactly three fixed, GLOBAL names from
# inside the slot; they must be real files, never symlinks, because rollback into the Yocto
# slot has to stay symmetric and U-Boot's ext4 symlink handling must never matter.
cat >"${HOOK_DIR}/50-boot.sh" <<'HOOK50'
#!/bin/sh
set -eu
chroot_dir=$1
chroot "$chroot_dir" env \
	OMNI_KERNEL_NAME_DEFAULT="${OMNI_KERNEL_NAME_DEFAULT:?}" \
	OMNI_DTB_NAME_DEFAULT="${OMNI_DTB_NAME_DEFAULT:?}" \
	OMNI_RAMDISK_NAME_DEFAULT="${OMNI_RAMDISK_NAME_DEFAULT:?}" \
	OMNI_ASSERT_BOOT="${OMNI_ASSERT_BOOT:-1}" \
	OMNI_ALLOW_UNVERIFIED="${OMNI_ALLOW_UNVERIFIED:-0}" \
	/bin/sh -s <<'IN_CHROOT'
set -eu

kname=$OMNI_KERNEL_NAME_DEFAULT
dname=$OMNI_DTB_NAME_DEFAULT
rname=$OMNI_RAMDISK_NAME_DEFAULT
dtb_src=""

# The authoritative names come from Phase 0's fw_printenv, shipped in the overlay as
# /etc/default/omni-boot. Accept the overlay's spellings (OMNI_KERNEL_NAME / OMNI_DTB_NAME /
# OMNI_INITRD_NAME), the OMNI_RAMDISK_NAME alias, and the raw mender_* names.
if [ -r /etc/default/omni-boot ]; then
	. /etc/default/omni-boot
	kname=${OMNI_KERNEL_NAME:-${mender_kernel_name:-$kname}}
	dname=${OMNI_DTB_NAME:-${mender_dtb_name:-$dname}}
	rname=${OMNI_INITRD_NAME:-${OMNI_RAMDISK_NAME:-${mender_ramdisk_name:-$rname}}}
	dtb_src=${OMNI_DTB_SRC:-}
	echo "I: 50-boot: names from /etc/default/omni-boot"

	# Fail-closed gate declared by /etc/default/omni-boot itself: the three names must have
	# been captured verbatim off the device (pre-flight check P4). A field U-Boot binary may
	# predate patches 0050/0051 and carry different strings, in which case a wrong name here
	# silently boots the previous kernel against the new rootfs, or fails the load.
	if [ "${OMNI_BOOT_VERIFIED:-no}" != "yes" ]; then
		if [ "$OMNI_ALLOW_UNVERIFIED" = 1 ]; then
			echo "W: 50-boot: OMNI_BOOT_VERIFIED is '${OMNI_BOOT_VERIFIED:-no}' and --allow-unverified-boot-names was given." >&2
			echo "W: 50-boot: this image may load the WRONG kernel/dtb/initrd names. Do not arm a slot with it." >&2
		else
			echo "E: 50-boot: /etc/default/omni-boot has OMNI_BOOT_VERIFIED=\"${OMNI_BOOT_VERIFIED:-no}\"." >&2
			echo "E: 50-boot: the three U-Boot artefact names are unverified compiled-in defaults." >&2
			echo "E: 50-boot: capture them from the device first (pre-flight P4):" >&2
			echo "E: 50-boot:     ssh root@omni 'fw_printenv mender_kernel_name mender_dtb_name mender_ramdisk_name'" >&2
			echo "E: 50-boot: then set the values and OMNI_BOOT_VERIFIED=\"yes\" in rootfs/overlay/etc/default/omni-boot." >&2
			echo "E: 50-boot: to build anyway (test images only): --allow-unverified-boot-names" >&2
			exit 1
		fi
	else
		echo "I: 50-boot: boot names verified against ${OMNI_BOOT_CAPTURED_FROM:-?} at ${OMNI_BOOT_CAPTURED_AT:-?}"
	fi
else
	echo "W: 50-boot: no /etc/default/omni-boot in the image; using compiled-in defaults." >&2
	echo "W: 50-boot: these MUST match the device's stored env, captured with fw_printenv." >&2
fi
echo "I: 50-boot: kernel=${kname} dtb=${dname} ramdisk=${rname}"

ver=$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V | tail -n1 || true)
[ -n "$ver" ] || { echo "E: 50-boot: no /boot/vmlinuz-* — the kernel deb did not install" >&2; exit 1; }
echo "I: 50-boot: kernel version ${ver}"

if command -v update-initramfs >/dev/null 2>&1; then
	if [ -f "/boot/initrd.img-${ver}" ]; then
		update-initramfs -u -k "$ver"
	else
		update-initramfs -c -k "$ver"
	fi
else
	echo "E: 50-boot: update-initramfs missing (initramfs-tools not installed)" >&2
	exit 1
fi

find_dtb() {
	# OMNI_DTB_SRC is the path relative to the kernel package's DTB directory, e.g.
	# "amlogic/meson-axg-apollo.dtb" (Armbian linux-dtb-* -> /boot/dtb-<ver>/<that>).
	if [ -n "$dtb_src" ]; then
		for c in "/boot/dtb-${ver}/${dtb_src}" "/boot/dtb/${dtb_src}" "/usr/lib/linux-image-${ver}/${dtb_src}"; do
			[ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
		done
	fi
	for c in "/boot/dtb-${ver}/amlogic/$1" "/boot/dtb/amlogic/$1" "/boot/dtb-${ver}/$1" "/boot/dtb/$1"; do
		[ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
	done
	c=$(find /boot /usr/lib/linux-image-* -name "$1" -type f 2>/dev/null | head -n1 || true)
	[ -n "$c" ] && { printf '%s\n' "$c"; return 0; }
	return 1
}

place() { # $1 = source, $2 = final name under /boot
	src=$1; dst="/boot/$2"
	if [ "$src" = "$dst" ]; then return 0; fi
	if [ -L "$dst" ]; then
		echo "W: 50-boot: ${dst} is a SYMLINK; replacing with a real file (the flatten hooks must cp, never ln)" >&2
		rm -f "$dst"
	elif [ -f "$dst" ] && cmp -s "$src" "$dst"; then
		echo "I: 50-boot: ${dst} already correct (overlay flatten hook ran)"
		return 0
	elif [ -f "$dst" ]; then
		echo "W: 50-boot: ${dst} exists but differs from ${src}; refreshing" >&2
	else
		echo "W: 50-boot: ${dst} was not produced by the overlay's flatten hooks; creating it here." >&2
		echo "W: 50-boot: check /etc/kernel/postinst.d/zz-omni-flatten and /etc/initramfs/post-update.d/99-omni-flatten" >&2
	fi
	cp -f "$src" "$dst"
}

# The overlay owns the canonical implementation (/usr/lib/omni/omni-flatten, driven on the
# device by the dpkg kernel hooks). Use it if it is here, so the build exercises the same
# code path the device will run on every future kernel upgrade. The place() fallback below
# only covers an image built with --no-overlay or a broken overlay.
if [ -x /usr/lib/omni/omni-flatten ]; then
	echo "I: 50-boot: running /usr/lib/omni/omni-flatten all ${ver}"
	/usr/lib/omni/omni-flatten all "$ver"
fi

place "/boot/vmlinuz-${ver}" "$kname"
if dtb_found=$(find_dtb "$dname"); then
	place "$dtb_found" "$dname"
else
	echo "W: 50-boot: no ${dname} found anywhere under /boot or /usr/lib/linux-image-*" >&2
fi
place "/boot/initrd.img-${ver}" "$rname"

rc=0
for f in "$kname" "$dname" "$rname"; do
	if [ -f "/boot/$f" ] && [ -s "/boot/$f" ] && [ ! -L "/boot/$f" ]; then
		printf 'I: 50-boot: /boot/%-52s %10d bytes\n' "$f" "$(stat -c%s "/boot/$f")"
	else
		echo "E: 50-boot: /boot/${f} is missing, empty or a symlink" >&2
		rc=1
	fi
done
if [ "$rc" != 0 ] && [ "$OMNI_ASSERT_BOOT" = 1 ]; then
	echo "E: 50-boot: U-Boot ext4loads these three names from inside the slot; the image is unbootable." >&2
	echo "E: 50-boot: re-run with --no-assert-boot only if you know why." >&2
	exit 1
fi
exit 0
IN_CHROOT
HOOK50

# 60 — first-boot hygiene, per-device state removal, and the assertions that decide whether
# this image is allowed to exist at all.
cat >"${HOOK_DIR}/60-finalise.sh" <<'HOOK60'
#!/bin/sh
set -eu
chroot_dir=$1

# Provenance for the manifest, taken on the host side of the hook.
chroot "$chroot_dir" dpkg-query -W -f='${Package} ${Version} ${Architecture}\n' \
	> "${OMNI_WORK:?}/packages.installed"

chroot "$chroot_dir" env \
	OMNI_HOSTNAME="${OMNI_HOSTNAME:-omni}" \
	OMNI_ROOT_PW_HASH="${OMNI_ROOT_PW_HASH:-}" \
	OMNI_FORBIDDEN="${OMNI_FORBIDDEN:-}" \
	/bin/sh -s <<'IN_CHROOT'
set -eu

# --- machine-id: emptied, not deleted. An empty /etc/machine-id is systemd's uninitialised
# marker; PID 1 seeds it on first boot and overmounts it before any unit runs. It must not
# be baked in: systemd-networkd derives its DHCP DUID from it, so a shared machine-id means
# every Omni asks the DHCP server for the same lease.
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id
[ -d /var/lib/dbus ] && ln -sf /etc/machine-id /var/lib/dbus/machine-id

# --- per-device secrets must not ship in a slot image.
rm -f /etc/ssh/ssh_host_*
rm -f /var/lib/systemd/random-seed /var/lib/systemd/credential.secret
rm -f /etc/.pwd.lock

# --- root password. Locked by default; serial autologin uses login -f and is unaffected.
if [ -n "$OMNI_ROOT_PW_HASH" ]; then
	usermod -p "$OMNI_ROOT_PW_HASH" root
	echo "I: 60-finalise: root password hash set from --root-password-hash"
else
	usermod -p '*' root
	echo "I: 60-finalise: root password locked ('*'); console autologin still works"
fi

[ -s /etc/hostname ] || printf '%s\n' "$OMNI_HOSTNAME" > /etc/hostname
grep -q "$(cat /etc/hostname)" /etc/hosts 2>/dev/null || \
	printf '127.0.1.1\t%s\n' "$(cat /etc/hostname)" >> /etc/hosts

# --- fstab. / is assembled by the initramfs (lower ro + per-slot overlay upper), so there
# is nothing for fstab to do. What matters is what must NOT be here: the cgroup v1 tmpfs
# line the Yocto image carried. systemd >= 256 refuses to boot on cgroup v1 and mounts
# cgroup2 itself before fstab is processed.
if [ ! -e /etc/fstab ]; then
	cat > /etc/fstab <<'FSTAB'
# <file system> <mount point> <type> <options> <dump> <pass>
# Root is mounted by the initramfs: lower (this slot) read-only + overlay upper on p5/p6.
# /data (p3) is mounted by data.mount, not from here.
# Deliberately NO cgroup v1 line: systemd mounts cgroup2 itself, before fstab.
FSTAB
fi
# Strip comments before matching. The shipped fstab documents at length WHY the
# Yocto cgroup-v1 line is absent, and those comments contain the literal path --
# matching them would fail every build on a file that is in fact correct.
if sed 's/#.*//' /etc/fstab | grep -qE '(^|[[:space:]])/sys/fs/cgroup([[:space:]]|$)'; then
	echo "E: 60-finalise: /etc/fstab has a /sys/fs/cgroup entry. systemd >= 256 will not boot on cgroup v1." >&2
	exit 1
fi

# --- assertions -----------------------------------------------------------------
fail=0

# The whole reason this image is built with mmdebstrap: armbian-install repartitions eMMC.
for p in /usr/bin/armbian-install /usr/sbin/armbian-install /usr/lib/armbian/armbian-install; do
	[ -e "$p" ] && { echo "E: 60-finalise: ${p} exists. armbian-bsp leaked in; it REPARTITIONS eMMC." >&2; fail=1; }
done
# Purge first, then assert. Some forbidden packages arrive unavoidably: ifupdown is
# Priority:important, so --variant=important installs it, and deselecting it with
# "ifupdown-" fails because mmdebstrap marks the important set held ("Held packages were
# changed"). Purging here is the supported way out. The assertion below is still the
# safety net -- it fires if a purge did not take, or if a genuinely unexpected package
# appears.
for pkg in $OMNI_FORBIDDEN; do
	if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
		echo "I: 60-finalise: purging forbidden package: ${pkg}" >&2
		# dpkg, not apt-get: apt rewrites /var/lib/apt/lists, and mmdebstrap's own
		# cleanup step then fails trying to re-run apt-get update against a lists
		# directory it no longer owns ("List directory .../partial is missing").
		# These packages have no reverse-dependencies we keep, so dpkg is sufficient.
		DEBIAN_FRONTEND=noninteractive dpkg --purge --force-depends "$pkg" >/dev/null 2>&1 \
			|| echo "W: 60-finalise: purge of ${pkg} failed; the assertion below will catch it" >&2
	fi
done
for pkg in $OMNI_FORBIDDEN; do
	if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
		echo "E: 60-finalise: forbidden package still installed after purge: ${pkg}" >&2
		fail=1
	fi
done

# fw_printenv/fw_setenv are how a Debian slot arms, commits and rolls back. Without them
# the slot boots but can never participate in A/B.
if ! command -v fw_printenv >/dev/null 2>&1 || ! command -v fw_setenv >/dev/null 2>&1; then
	echo "E: 60-finalise: fw_printenv/fw_setenv missing — this slot could never arm, commit or" >&2
	echo "E: 60-finalise: roll back, i.e. it cannot take part in A/B at all." >&2
	echo "E: 60-finalise: Install libubootenv-tool. NOTE: trixie's u-boot-tools does NOT ship them;" >&2
	echo "E: 60-finalise: libubootenv-tool is their only provider in the archive." >&2
	fail=1
else
	echo "I: 60-finalise: fw_setenv   -> $(command -v fw_setenv)"
	echo "I: 60-finalise: fw_printenv -> $(command -v fw_printenv)"
	# Record which implementation landed. The two disagree on `fw_setenv -s <file>` script
	# syntax ("name value" vs "key=value"), which is why omni-uboot-env.sh writes one
	# variable per invocation instead of batching.
	prov=$(dpkg-query -S "$(readlink -f "$(command -v fw_setenv)")" 2>/dev/null | cut -d: -f1 | head -n1)
	echo "I: 60-finalise: provided by ${prov:-unknown}"
fi
# /etc/fw_env.config describes the single non-redundant 8 KB env copy at offset 0 of
# mmcblk0boot0. Without it fw_setenv writes to the wrong place, or nowhere.
if [ ! -r /etc/fw_env.config ]; then
	echo "E: 60-finalise: /etc/fw_env.config is missing; fw_setenv cannot find the environment." >&2
	fail=1
fi

[ -x /sbin/init ] || [ -L /sbin/init ] || { echo "E: 60-finalise: no /sbin/init (systemd-sysv missing)" >&2; fail=1; }
[ -d /data ] || mkdir -m 0755 /data
[ -d /boot ] || { echo "E: 60-finalise: no /boot" >&2; fail=1; }

[ "$fail" = 0 ] || exit 1

# Space reclamation, carefully scoped. Two things that look tidy here are NOT:
#
#   rm -rf /tmp/*                 mmdebstrap keeps its OWN control files inside
#                                 the chroot's /tmp (mmdebstrap.apt.conf.XXXX).
#                                 Deleting them breaks the "cleaning package
#                                 lists and apt cache" step it runs AFTER this
#                                 hook, which then dies with
#                                 "Unable to read .../mmdebstrap.apt.conf..."
#                                 followed by apt EPERM on /var/lib/apt/lists.
#   rm -rf /var/lib/apt/lists/*   removes the partial/ and auxfiles/ directories
#                                 apt expects to exist; apt then tries to
#                                 recreate and chown them to _apt and fails
#                                 inside the unshare namespace.
#
# mmdebstrap already empties the lists and the archive cache itself, immediately
# after this hook returns. Leave both to it and only drop the .deb archives,
# which it is happy for us to have removed early.
apt-get clean
rm -f /var/cache/apt/archives/*.deb 2>/dev/null || true
echo "I: 60-finalise: ok"
IN_CHROOT
HOOK60

chmod 0755 "${HOOK_DIR}"/*.sh

# --------------------------------------------------------------------------- mmdebstrap
DEB_LIST="${WORK_DIR}/kernel-debs.list"
OVERLAY_TAR=""
[ -n "$OVERLAY_DIR" ] && OVERLAY_TAR="${WORK_DIR}/overlay.tar"

declare -a MM=(mmdebstrap
	"--architectures=${ARCH}"
	"--mode=${MMDEBSTRAP_MODE}"
	"--variant=${VARIANT}"
	--format=tar
	"--components=${COMPONENTS}"
	"--include=${PKGS_CSV}"
	'--dpkgopt=force-unsafe-io'
)
[ "$WITH_RECOMMENDS" = 1 ] || MM+=('--aptopt=Apt::Install-Recommends "false"')
# Keep apt from dropping privileges to the _apt user. Under --mode=unshare our uid is
# mapped to a subuid inside the namespace, _apt is not, and apt's chown of
# /var/lib/apt/lists/partial then fails with EPERM -- which surfaces at the very end,
# in mmdebstrap's own "cleaning package lists" step, after the entire rootfs has been
# built. This is the documented workaround and affects only the build sandbox, never
# the produced image.
MM+=('--aptopt=APT::Sandbox::User "root"')
if [ "$SLIM" = 1 ]; then
	MM+=('--dpkgopt=path-exclude=/usr/share/doc/*'
	     '--dpkgopt=path-exclude=/usr/share/man/*'
	     '--dpkgopt=path-exclude=/usr/share/info/*'
	     '--dpkgopt=path-exclude=/usr/share/locale/*'
	     '--dpkgopt=path-include=/usr/share/locale/en*')
fi
[ "$VERBOSE" = 1 ] && MM+=(--verbose)
[ -n "$QEMU_STATIC" ] && MM+=("--setup-hook=mkdir -p \"\$1/usr/bin\" && cp ${QEMU_STATIC} \"\$1${QEMU_STATIC}\"")
MM+=("--customize-hook=${HOOK_DIR}/10-overlay.sh"
     "--customize-hook=${HOOK_DIR}/20-kernel.sh"
     "--customize-hook=${HOOK_DIR}/30-systemd.sh"
     "--customize-hook=${HOOK_DIR}/40-serial.sh"
     "--customize-hook=${HOOK_DIR}/50-boot.sh"
     "--customize-hook=${HOOK_DIR}/60-finalise.sh")
[ -n "$QEMU_STATIC" ] && MM+=("--customize-hook=rm -f \"\$1${QEMU_STATIC}\"")
MM+=("$SUITE" "$TARBALL" "deb ${MIRROR} ${SUITE} ${COMPONENTS}")
if [ "$WITH_SECURITY" = 1 ]; then
	MM+=("deb ${SECURITY_MIRROR} ${SUITE}-security ${COMPONENTS}"
	     "deb ${MIRROR} ${SUITE}-updates ${COMPONENTS}")
fi

export OMNI_WORK="$WORK_DIR"
export OMNI_OVERLAY_TAR="$OVERLAY_TAR"
export OMNI_KERNEL_DEB_LIST="$DEB_LIST"
export OMNI_ENABLE_UNITS="${ENABLE_UNITS[*]}"
export OMNI_MASK_UNITS="${MASK_UNITS[*]-}"
export OMNI_CONSOLE="$CONSOLE"
export OMNI_CONSOLE_BAUD="$CONSOLE_BAUD"
export OMNI_HOSTNAME="$IMAGE_HOSTNAME"
export OMNI_ROOT_PW_HASH="$ROOT_PW_HASH"
export OMNI_KERNEL_NAME_DEFAULT="$KERNEL_NAME"
export OMNI_DTB_NAME_DEFAULT="$DTB_NAME"
export OMNI_RAMDISK_NAME_DEFAULT="$RAMDISK_NAME"
export OMNI_ASSERT_BOOT="$ASSERT_BOOT"
export OMNI_ALLOW_UNVERIFIED="$ALLOW_UNVERIFIED"
export OMNI_FORBIDDEN="${FORBIDDEN_PACKAGES[*]}"

# --------------------------------------------------------------------------- pack method
detect_pack_method() {
	if [ "$(id -u)" -eq 0 ]; then printf 'root\n'; return 0; fi
	if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then printf 'sudo\n'; return 0; fi
	if command -v unshare >/dev/null 2>&1 && unshare --user --map-auto --map-root-user true 2>/dev/null; then
		printf 'unshare\n'; return 0
	fi
	return 1
}
if [ "$PACK_METHOD" = auto ]; then
	PACK_METHOD=$(detect_pack_method) || die \
"cannot obtain the privilege needed to unpack the rootfs tar and run mke2fs -d.
Tried: uid 0, passwordless sudo, and 'unshare --user --map-auto --map-root-user'.
Inside the builder container the 'builder' user has passwordless sudo, so this normally
just works — run via build-in-docker.sh. Otherwise pass --pack-method explicitly."
fi
case "$PACK_METHOD" in
	root)    [ "$(id -u)" -eq 0 ] || die "--pack-method root but euid is $(id -u)";;
	sudo)    command -v sudo >/dev/null 2>&1 || die "--pack-method sudo but sudo is not installed"
	         sudo -n true 2>/dev/null || die "--pack-method sudo but 'sudo -n true' failed (no passwordless sudo)";;
	unshare) unshare --user --map-auto --map-root-user true 2>/dev/null || die \
	         "--pack-method unshare but 'unshare --user --map-auto --map-root-user' failed.
Needs util-linux >= 2.38 and a /etc/subuid + /etc/subgid range for $(id -un).";;
esac
if [ "$PACK_METHOD" = unshare ]; then
	PACK_XATTRS=0; PACK_EXCLUDE_DEV=1; PACK_CHOWN=0:0
	warn "--pack-method unshare: file capabilities and static /dev nodes are dropped."
	warn "  Both are harmless here (root-only box, devtmpfs is auto-mounted and the initramfs"
	warn "  moves its /dev into the new root), but a v3 security.capability xattr written from"
	warn "  a user namespace would be invalid on the device, so it is not written at all."
else
	PACK_XATTRS=1; PACK_EXCLUDE_DEV=0; PACK_CHOWN="$(id -u):$(id -g)"
fi

# --------------------------------------------------------------------------- plan
log "build plan"
info "suite/arch      ${SUITE} / ${ARCH}  (mmdebstrap --mode=${MMDEBSTRAP_MODE} --variant=${VARIANT})"
info "packages        ${#PKGS[@]} from ${PKG_FILE}"
info "kernel debs     ${#INSTALL_DEBS[@]} from ${KERNEL_DEB_DIR}"
for d in "${INSTALL_DEBS[@]}"; do info "                  $(basename "$d")"; done
info "overlay         ${OVERLAY_DIR:-<none>}"
info "units enabled   ${ENABLE_UNITS[*]}"
info "console         ${CONSOLE} @ ${CONSOLE_BAUD} (autologin root)"
info "boot names      ${KERNEL_NAME} / ${DTB_NAME} / ${RAMDISK_NAME}"
info "filesystem      ${BLOCKS} x ${BLOCK_SIZE} = ${IMG_BYTES} bytes ($((IMG_BYTES/1048576)) MiB)"
info "                label=${LABEL} uuid=${FS_UUID} -O ${OFEAT}"
info "pack method     ${PACK_METHOD}"
info "output          ${OUT_DIR}/${NAME}.ext4.gz"
info "scratch         ${WORK_DIR}"
printf '\n' >&2
info "mmdebstrap command:"
printf '      %q\n' "${MM[@]}" >&2
printf '\n' >&2
info "mke2fs command:"
printf '      %s\n' "mke2fs -q -F -t ext4 -b ${BLOCK_SIZE} -m 0 -L ${LABEL} -U ${FS_UUID} -O ${OFEAT} -E ${EOPTS} -d ${ROOTDIR} ${IMG} ${BLOCKS}" >&2
printf '\n' >&2

if [ "$DRY_RUN" = 1 ]; then
	log "dry run: every precondition checked, nothing written"
	exit 0
fi

# --------------------------------------------------------------------------- build
mkdir -p "$OUT_DIR"
printf '%s\n' "${INSTALL_DEBS[@]}" > "$DEB_LIST"

if [ -n "$OVERLAY_TAR" ]; then
	log "packing overlay tree (installed root:root)"
	tar -C "$OVERLAY_DIR" --owner=0 --group=0 --numeric-owner --sort=name \
		--exclude-vcs --exclude='.gitkeep' --exclude='*~' \
		-cf "$OVERLAY_TAR" .
	info "$(tar -tf "$OVERLAY_TAR" | wc -l) entries"
fi

log "mmdebstrap: building ${SUITE}/${ARCH} rootfs"
rm -f -- "$TARBALL"
"${MM[@]}"
[ -s "$TARBALL" ] || die "mmdebstrap produced no tarball"
info "rootfs tar: $(stat -c%s "$TARBALL") bytes"

# --------------------------------------------------------------------------- pack
cat >"${WORK_DIR}/pack.sh" <<'PACKSH'
#!/bin/bash
# Unpack the mmdebstrap tar with real ownership and build the ext4 image from it.
# Runs as root (container root / sudo) or as the root of a user namespace.
set -euo pipefail
. "${1:?usage: pack.sh <pack.conf>}"

for t in tar mke2fs; do command -v "$t" >/dev/null 2>&1 || { echo "ERROR: pack: missing $t" >&2; exit 1; }; done

rm -rf -- "$PACK_ROOTDIR"
mkdir -p "$PACK_ROOTDIR"

tar_args=(-C "$PACK_ROOTDIR" --numeric-owner -xpf "$PACK_TARBALL")
[ "$PACK_XATTRS" = 1 ] && tar_args+=(--xattrs --xattrs-include='*')
# Device nodes cannot be created from inside a user namespace; devtmpfs provides them at
# runtime and the initramfs moves its own /dev into the new root.
[ "$PACK_EXCLUDE_DEV" = 1 ] && tar_args+=(--exclude='./dev/*')
tar "${tar_args[@]}"

for d in dev proc sys run mnt media data boot; do mkdir -p "${PACK_ROOTDIR}/${d}"; done
mkdir -p "${PACK_ROOTDIR}/tmp" && chmod 1777 "${PACK_ROOTDIR}/tmp"
[ -d "${PACK_ROOTDIR}/var/tmp" ] && chmod 1777 "${PACK_ROOTDIR}/var/tmp"

rm -f -- "$PACK_IMG"
# -F is mandatory: without it mke2fs prompts "not a block special device. Proceed anyway?"
# on a regular file and the build would block forever waiting for stdin.
mke2fs -q -F -t ext4 -b "$PACK_BLOCK_SIZE" -m 0 \
	-L "$PACK_LABEL" -U "$PACK_UUID" \
	-O "$PACK_FEATURES" -E "$PACK_EOPTS" \
	-d "$PACK_ROOTDIR" "$PACK_IMG" "$PACK_BLOCKS"

chown "$PACK_CHOWN" "$PACK_IMG"
chmod 0644 "$PACK_IMG"
[ "$PACK_KEEP_ROOTDIR" = 1 ] || rm -rf -- "$PACK_ROOTDIR"
PACKSH
chmod 0755 "${WORK_DIR}/pack.sh"

{
	printf 'PACK_TARBALL=%q\n'      "$TARBALL"
	printf 'PACK_ROOTDIR=%q\n'      "$ROOTDIR"
	printf 'PACK_IMG=%q\n'          "$IMG"
	printf 'PACK_BLOCKS=%q\n'       "$BLOCKS"
	printf 'PACK_BLOCK_SIZE=%q\n'   "$BLOCK_SIZE"
	printf 'PACK_LABEL=%q\n'        "$LABEL"
	printf 'PACK_UUID=%q\n'         "$FS_UUID"
	printf 'PACK_FEATURES=%q\n'     "$OFEAT"
	printf 'PACK_EOPTS=%q\n'        "$EOPTS"
	printf 'PACK_XATTRS=%q\n'       "$PACK_XATTRS"
	printf 'PACK_EXCLUDE_DEV=%q\n'  "$PACK_EXCLUDE_DEV"
	printf 'PACK_CHOWN=%q\n'        "$PACK_CHOWN"
	printf 'PACK_KEEP_ROOTDIR=%q\n' "$KEEP_WORK"
} > "${WORK_DIR}/pack.conf"

# The method was chosen before the bootstrap; a sudo timestamp can expire during it, and
# losing 20 minutes of work to that would be silly. Re-check and degrade rather than die.
if [ "$PACK_METHOD" = sudo ] && ! sudo -n true 2>/dev/null; then
	if unshare --user --map-auto --map-root-user true 2>/dev/null; then
		warn "the sudo credential expired during the bootstrap; falling back to --pack-method unshare"
		PACK_METHOD=unshare
		sed -i -e 's/^PACK_XATTRS=.*/PACK_XATTRS=0/' -e 's/^PACK_EXCLUDE_DEV=.*/PACK_EXCLUDE_DEV=1/' \
		       -e 's/^PACK_CHOWN=.*/PACK_CHOWN=0:0/' "${WORK_DIR}/pack.conf"
	else
		die "the sudo credential expired during the bootstrap and user namespaces are unavailable.
The rootfs tar is intact at ${TARBALL}; re-run with --work ${WORK_DIR} once sudo works."
	fi
fi

log "packing ext4 (${PACK_METHOD})"
case "$PACK_METHOD" in
	root)    bash "${WORK_DIR}/pack.sh" "${WORK_DIR}/pack.conf";;
	sudo)    sudo -n bash "${WORK_DIR}/pack.sh" "${WORK_DIR}/pack.conf";;
	unshare) unshare --user --map-auto --map-root-user -- bash "${WORK_DIR}/pack.sh" "${WORK_DIR}/pack.conf";;
esac
[ -f "$IMG" ] || die "packing produced no image at ${IMG}"
[ "$(stat -c%s "$IMG")" = "$IMG_BYTES" ] || die \
	"image is $(stat -c%s "$IMG") bytes, expected ${IMG_BYTES}"

# --------------------------------------------------------------------------- assertions
log "asserting ext4 feature set"
DUMP=$(dumpe2fs -h "$IMG" 2>/dev/null) || die "dumpe2fs failed on ${IMG}"
FEATURES=$(printf '%s\n' "$DUMP" | sed -n 's/^Filesystem features:[[:space:]]*//p')
[ -n "$FEATURES" ] || die "could not read 'Filesystem features' from dumpe2fs"
info "Filesystem features: ${FEATURES}"

fail=0
for feat in "${DISABLE_FEATURES[@]}"; do
	if printf ' %s ' "$FEATURES" | grep -q " ${feat} "; then
		printf 'ERROR: forbidden ext4 feature present: %s\n' "$feat" >&2
		fail=1
	fi
done
for feat in "${REQUIRE_FEATURES[@]}"; do
	if ! printf ' %s ' "$FEATURES" | grep -q " ${feat} "; then
		printf 'ERROR: required ext4 feature missing: %s\n' "$feat" >&2
		fail=1
	fi
done
[ "$fail" = 0 ] || die \
"the filesystem feature set is not what was asked for.
U-Boot 2018.09 cannot read 64bit/metadata_csum/metadata_csum_seed/orphan_file; e2fsprogs 1.47
enables the last two by default (Debian #1072566). This fails as an unbootable slot, not as a
build error, so it is checked here."

check_hdr() { # $1 = dumpe2fs field, $2 = expected
	local got
	got=$(printf '%s\n' "$DUMP" | sed -n "s/^$1:[[:space:]]*//p" | head -n1)
	[ "$got" = "$2" ] || die "dumpe2fs '$1' is '${got}', expected '${2}'"
	info "$1: ${got}"
}
check_hdr 'Block size'           "$BLOCK_SIZE"
check_hdr 'Block count'          "$BLOCKS"
check_hdr 'Reserved block count' '0'
check_hdr 'Filesystem volume name' "$LABEL"
check_hdr 'Filesystem UUID'      "$FS_UUID"

log "e2fsck -fn (the same check omni-flash.sh runs on the written slot)"
e2fsck -fn "$IMG" || die "e2fsck reported problems in the freshly built image"

# --------------------------------------------------------------------------- outputs
log "compressing and hashing"
IMG_SHA=$(sha256sum "$IMG" | cut -d' ' -f1)
GZ="${OUT_DIR}/${NAME}.ext4.gz"
if command -v pigz >/dev/null 2>&1; then
	pigz -9 -n -c "$IMG" > "$GZ"
else
	gzip -9 -n -c "$IMG" > "$GZ"
fi
GZ_SHA=$(sha256sum "$GZ" | cut -d' ' -f1)

# .sha256 and .size describe the UNCOMPRESSED image: omni-flash.sh gunzips into dd and then
# verifies `head -c $IMG_SIZE $target | sha256sum`.
printf '%s\n' "$IMG_SHA"   > "${OUT_DIR}/${NAME}.ext4.sha256"
printf '%s\n' "$IMG_BYTES" > "${OUT_DIR}/${NAME}.ext4.size"
printf '%s\n' "$GZ_SHA"    > "${OUT_DIR}/${NAME}.ext4.gz.sha256"
[ -f "${WORK_DIR}/packages.installed" ] && cp -f "${WORK_DIR}/packages.installed" "${OUT_DIR}/${NAME}.packages"

KVER=$(sed -n 's/^linux-image-\([^ ]*\) .*/\1/p' "${OUT_DIR}/${NAME}.packages" 2>/dev/null | head -n1 || true)
cat > "${OUT_DIR}/${NAME}.manifest" <<EOF
# Avast Omni slot image — built by ${PROG}
built-utc            $(date -u +%Y-%m-%dT%H:%M:%SZ)
builder-host         $(uname -srm)
suite                ${SUITE}
architecture         ${ARCH}
variant              ${VARIANT}
mmdebstrap-mode      ${MMDEBSTRAP_MODE}
mmdebstrap-version   $(mmdebstrap --version 2>/dev/null | head -n1)
e2fsprogs-version    $(mke2fs -V 2>&1 | head -n1)
mirror               ${MIRROR}
security-mirror      $([ "$WITH_SECURITY" = 1 ] && printf '%s' "$SECURITY_MIRROR" || printf '(none)')
components           ${COMPONENTS}
recommends           $([ "$WITH_RECOMMENDS" = 1 ] && echo yes || echo no)
slim                 $([ "$SLIM" = 1 ] && echo yes || echo no)
packages-requested   ${#PKGS[@]}
packages-installed   $(wc -l < "${OUT_DIR}/${NAME}.packages" 2>/dev/null || echo '?')
kernel-package       ${KVER:-unknown}
kernel-debs          $(printf '%s ' "${INSTALL_DEBS[@]##*/}")
overlay              ${OVERLAY_DIR:-(none)}
console              ${CONSOLE}@${CONSOLE_BAUD} autologin=root
boot-kernel-name     ${KERNEL_NAME}
boot-dtb-name        ${DTB_NAME}
boot-ramdisk-name    ${RAMDISK_NAME}
fs-label             ${LABEL}
fs-uuid              ${FS_UUID}
fs-block-size        ${BLOCK_SIZE}
fs-blocks            ${BLOCKS}
fs-bytes             ${IMG_BYTES}
fs-features          ${FEATURES}
fs-disabled          ${OFEAT}
pack-method          ${PACK_METHOD}
image-sha256         ${IMG_SHA}
gzip-sha256          ${GZ_SHA}
EOF

if [ "$KEEP_IMAGE" = 1 ]; then
	mv -f "$IMG" "${OUT_DIR}/${NAME}.ext4"
else
	rm -f "$IMG"
fi

log "done"
info "$(ls -la "$GZ" | awk '{print $5, $9}')"
info "uncompressed    ${IMG_BYTES} bytes  sha256 ${IMG_SHA}"
printf '\n' >&2
info "flash from the device with:"
info "    omni-flash.sh --image <URL-or-path>/${NAME}.ext4.gz \\"
info "        --sha256 ${IMG_SHA} \\"
info "        --size   ${IMG_BYTES}"
info "  (--sha256 is the DECOMPRESSED digest omni-flash.sh verifies off the partition;"
info "   both values are also in ${NAME}.ext4.sha256 and ${NAME}.ext4.size)"
if [ "$BLOCKS_EXPLICIT" = 0 ]; then
	printf '\n' >&2
	info "block count is the MEASURED default: ${BLOCKS} x ${BLOCK_SIZE} = ${IMG_BYTES} bytes,"
	info "which is exactly the size of p1/p2 on the unit measured on 2026-08-02"
	info "(docs/HARDWARE-MEASURED.md). Confirm it still holds for the target unit:"
	info "    blockdev --getsize64 /dev/mmcblk0p1     # expect ${IMG_BYTES}"
	info "A slot smaller than this is refused before mke2fs runs; a larger one just"
	info "leaves the tail unused, which is harmless."
fi

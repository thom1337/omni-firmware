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

# --- Tailscale --------------------------------------------------------------
# Static tarball, NOT pkgs.tailscale.com's apt repo. Same reasoning this file
# already applies to docker-ce: an appliance that sits in a closet for years
# should not carry a third-party apt source and signing key that can change
# under it. Tailscale is not in Debian trixie, so a pinned tarball plus a
# checksum is the auditable alternative. Bump the version and the digest
# together -- the build refuses to proceed if they disagree.
TAILSCALE=1
TAILSCALE_VERSION="1.98.10"
TAILSCALE_SHA256="d74a84e07cb1948d9f09a23ae161417c6127e562949773705c95d0762be2809d"
TAILSCALE_URL_BASE="https://pkgs.tailscale.com/stable"

# --- zsh + Oh My Zsh --------------------------------------------------------
# The interactive shell for root, on the serial console and over SSH. zsh comes
# from Debian; Oh My Zsh is not packaged anywhere, so it is pinned to a COMMIT
# and fetched as GitHub's tarball for that commit, in the same shape as the
# Tailscale pin above and for the same reason.
#
# WHAT IS VERIFIED, AND WHY IT IS NOT THE TARBALL'S DIGEST. codeload.github.com
# generates these archives on demand; the bytes are not contractually stable and
# GitHub has changed its gzip settings before, invalidating every pinned digest
# in the world overnight. So the pin is over the EXTRACTED TREE -- every path,
# type, symlink target and file content -- which is stable no matter how the
# archive was compressed on the day. Recompute after a bump with:
#
#   rootfs/build-rootfs.sh --omz-repin <commit>
#
# NOT VERIFIED BY THIS: that the commit itself is trustworthy. A tree digest
# proves you got the same thing twice, not that the thing is good. Read the
# upstream diff when you bump the pin; it is a shell that runs as root at every
# login on every device.
ZSH_SHELL=1
OMZ_COMMIT="ad586ffecaaeb695cc73ced4d643c6727d47f535"
OMZ_TREE_SHA256="73ebf670f169ccea4b278c80633060aa6eb1de716c897b0a47df7949195b2d42"
OMZ_URL_BASE="https://codeload.github.com/ohmyzsh/ohmyzsh/tar.gz"
OMZ_TGZ_IN=""            # --omz-tar: use a local archive, never touch the network

# Oh My Zsh ships ~300 plugins and sources only the ones named in .zshrc.
# Shipping all of them costs 11 MB in an image with 84 MiB of headroom on p7,
# to use three. The build keeps exactly this list and deletes the rest, then
# asserts that nothing left behind references a path it just removed.
#
# MUST MATCH the plugins=(...) line in rootfs/zsh/zshrc. A name there and not
# here produces "[oh-my-zsh] plugin 'x' not found" on every login.
OMZ_PLUGINS="systemd history-substring-search extract"
OMZ_ALL_PLUGINS=0
OMZ_REPIN=""             # --omz-repin: print a commit's tree digest and exit

BLOCKS_EXPLICIT=0
BLOCKS_FROM=""

OUT_DIR="${SCRIPT_DIR}/out"
# /root/.zshrc and the prompt theme. ONE copy for both images, appended to the
# overlay tar at build time in the same way the operator tools are -- a second
# copy under overlay-recovery/ would drift, and the one that drifts is the one
# you are looking at while the box is down.
ZSH_DIR="${SCRIPT_DIR}/zsh"
OVERLAY_DIR="${SCRIPT_DIR}/overlay"
USE_OVERLAY=1
PKG_FILE="${SCRIPT_DIR}/packages.list"
KERNEL_DEB_DIR=""
WORK_DIR=""
PACK_METHOD=auto

# The root authorized_keys is a BUILD INPUT, not a committed file. sshd here has
# PasswordAuthentication no and root's password locked to '*', so whatever lands
# in /root/.ssh/authorized_keys is the only way into the box over the network.
# Committing a key would mean every image built from this repository trusts one
# particular person and nobody else -- fine for the person who committed it, a
# backdoor for everyone else, and unusable for anyone who just wants to build
# the firmware. So the key comes from the environment or the command line, and a
# build with neither fails unless serial-only access is chosen deliberately.
SSH_PUBKEY="${OMNI_SSH_PUBKEY:-}"
SSH_PUBKEY_FILE="${OMNI_SSH_PUBKEY_FILE:-}"
ALLOW_NO_SSH_KEY=0

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
# The recovery slot (p7) is booted with ramdisk_addr_r cleared and init=/init,
# so no initrd is loaded on that path at all. Building one wastes ~30 MiB in a
# 450 MiB partition, and asserting one exists fails a perfectly good image.
NO_INITRAMFS=0
KEEP_MODULES=""
# Operator tools that run ON the device, installed into the image from tools/
# rather than copied into overlay/ -- two copies in one repository drift, and
# the one that drifts is always the one you need at 2 a.m.
TOOLS_DIR="${SCRIPT_DIR}/../tools"
DEVICE_TOOLS="omni-lib.sh omni-flash.sh omni-arm.sh omni-commit.sh omni-rollback.sh omni-preflight.sh"
WITH_DEVICE_TOOLS=1
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
  --ssh-pubkey KEY      SSH public key to authorise for root, as a literal
                        'ssh-ed25519 AAAA... comment' string. Repeatable input is
                        supported by passing a multi-line value. Env: OMNI_SSH_PUBKEY
  --ssh-pubkey-file F   read the key(s) from F instead ('-' for stdin).
                        Env: OMNI_SSH_PUBKEY_FILE
  --allow-no-ssh-key    build with NO authorised key. The image is then reachable
                        only over the serial console -- on a deployed unit that
                        means a site visit. Deliberate choice, never a default.
  --enable-unit U       extra systemd unit to enable (repeatable; prefix '?' = optional)
  --mask-unit U         systemd unit to mask (repeatable)
  --kernel-name N       default ${KERNEL_NAME}
  --dtb-name N          default ${DTB_NAME}
  --ramdisk-name N      default ${RAMDISK_NAME}
  --no-initramfs        build no initrd and do not require one under /boot. For
                        the recovery slot, whose U-Boot path clears
                        ramdisk_addr_r and boots init=/init directly.
  --keep-modules FILE   prune /usr/lib/modules to the modules named in FILE plus
                        their dependencies (resolved via modules.dep), then
                        re-run depmod. For the 450 MiB recovery slot, where the
                        stock 212 MiB module tree does not fit.
  --tools-dir DIR       where the device-side operator tools come from.
                        Default ${TOOLS_DIR}
  --no-device-tools     do not install omni-flash.sh and friends into /usr/sbin.
                        The image can then only be updated by copying them in
                        first, which is how this used to work and how a flash
                        silently did nothing when the copy was forgotten.
  --no-assert-boot      do not fail when /boot/<kernel|dtb|ramdisk> are missing
  --allow-unverified-boot-names
                        build even though the overlay's /etc/default/omni-boot still has
                        OMNI_BOOT_VERIFIED="no". By default the build FAILS CLOSED there:
                        the three names U-Boot loads are global and must be captured
                        verbatim from the device (pre-flight P4), never typed from the
                        U-Boot patches. Test images only.

SHELL
  --no-zsh              do not install zsh or Oh My Zsh, and leave root's login
                        shell at the Debian default (/bin/bash). /bin/sh is dash
                        either way -- see the note below.
  --omz-commit SHA      Oh My Zsh commit to pin. Default ${OMZ_COMMIT}
  --omz-tree-sha256 H   expected digest of the EXTRACTED tree for that commit.
                        Bump both together; the build refuses if they disagree.
  --omz-tar FILE        install from a local ohmyzsh tarball instead of fetching.
                        Still tree-verified. For builds with no network.
  --omz-plugins "A B"   plugins to keep; everything else is deleted from the
                        image. Default "${OMZ_PLUGINS}". Must match the
                        plugins=(...) line in rootfs/zsh/zshrc.
  --omz-all-plugins     keep all ~300 upstream plugins (+11 MB). On the 450 MiB
                        recovery image that is an eighth of the free space.
  --omz-repin SHA       fetch that commit, print the tree digest, exit. Use it to
                        produce the value for --omz-tree-sha256. Builds nothing.

  /bin/sh IS NOT TOUCHED, by any of these. It stays dash. The Yocto image this
  replaces had /bin/sh symlinked to zsh, and zsh's sh emulation has no
  PIPESTATUS -- which is precisely how omni-backup.sh came to report every
  backup as truncated for as long as it did. Everything on the device with a
  '#!/bin/sh' shebang is written against POSIX and must keep getting POSIX.
  The build asserts this.

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
	--no-tailscale)     TAILSCALE=0; shift;;
	--tailscale-version) TAILSCALE_VERSION=${2:?--tailscale-version needs a value}; shift 2;;
	--tailscale-sha256) TAILSCALE_SHA256=${2:?--tailscale-sha256 needs a value}; shift 2;;
	--no-zsh)           ZSH_SHELL=0; shift;;
	--omz-commit)       OMZ_COMMIT=${2:?--omz-commit needs a value}; shift 2;;
	--omz-tree-sha256)  OMZ_TREE_SHA256=${2:?--omz-tree-sha256 needs a value}; shift 2;;
	--omz-tar)          OMZ_TGZ_IN=${2:?--omz-tar needs a value}; shift 2;;
	--omz-plugins)      OMZ_PLUGINS=${2:?--omz-plugins needs a value}; shift 2;;
	--omz-all-plugins)  OMZ_ALL_PLUGINS=1; shift;;
	--omz-repin)        OMZ_REPIN=${2:?--omz-repin needs a commit sha}; shift 2;;
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
	--ssh-pubkey)       SSH_PUBKEY=${2:?--ssh-pubkey needs a value}; shift 2;;
	--ssh-pubkey-file)  SSH_PUBKEY_FILE=${2:?--ssh-pubkey-file needs a value}; shift 2;;
	--allow-no-ssh-key) ALLOW_NO_SSH_KEY=1; shift;;
	--enable-unit)      EXTRA_UNITS+=("${2:?--enable-unit needs a value}"); shift 2;;
	--mask-unit)        MASK_UNITS+=("${2:?--mask-unit needs a value}"); shift 2;;
	--kernel-name)      KERNEL_NAME=${2:?--kernel-name needs a value}; shift 2;;
	--dtb-name)         DTB_NAME=${2:?--dtb-name needs a value}; shift 2;;
	--ramdisk-name)     RAMDISK_NAME=${2:?--ramdisk-name needs a value}; shift 2;;
	--no-assert-boot)   ASSERT_BOOT=0; shift;;
	--no-initramfs)     NO_INITRAMFS=1; shift;;
	--keep-modules)     KEEP_MODULES=${2:?--keep-modules needs a value}; shift 2;;
	--tools-dir)        TOOLS_DIR=${2:?--tools-dir needs a value}; shift 2;;
	--no-device-tools)  WITH_DEVICE_TOOLS=0; shift;;
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

# ------------------------------------------------------------------- Oh My Zsh helpers
# Digest of an EXTRACTED tree: every path with its type and symlink target, plus
# the sha256 of every regular file's contents. NOT the tarball's own digest --
# codeload.github.com regenerates these archives on demand and their bytes are
# not stable across GitHub's own compression changes, whereas the tree is.
#
# Modes are deliberately excluded. GNU tar applies the umask when extracting as
# a non-root user, so a mode-sensitive digest would depend on the umask of
# whoever ran the build. Nothing in Oh My Zsh needs a mode we do not set
# ourselves in the install hook.
omz_tree_digest() {
	local d=$1
	( cd -- "$d" && {
		find . -mindepth 1 -printf '%y %P %l\n'
		find . -type f -exec sha256sum {} +
	  } | LC_ALL=C sort | sha256sum | cut -d' ' -f1 )
}

# Fetch (or copy) the archive for a commit and extract it. Prints the path of
# the extracted top-level directory on stdout; everything else goes to stderr so
# this is safe to capture.
omz_extract() {
	local commit=$1 dest=$2 tgz top
	tgz="${dest}/ohmyzsh-${commit}.tar.gz"
	mkdir -p -- "$dest"
	if [ -n "$OMZ_TGZ_IN" ]; then
		[ -s "$OMZ_TGZ_IN" ] || die "--omz-tar: not readable or empty: $OMZ_TGZ_IN"
		info "using local Oh My Zsh archive ${OMZ_TGZ_IN}"
		cp -- "$OMZ_TGZ_IN" "$tgz"
	else
		info "fetching Oh My Zsh ${commit} from ${OMZ_URL_BASE}/${commit}"
		curl -fL --retry 3 --retry-delay 5 --connect-timeout 20 \
			-o "$tgz" "${OMZ_URL_BASE}/${commit}" \
			|| die "could not download Oh My Zsh ${commit}"
	fi
	mkdir -p -- "${dest}/x"
	tar -C "${dest}/x" -xzf "$tgz" || die "Oh My Zsh archive did not extract"
	# One directory, named after the commit. Anything else means the archive is
	# not what it claims to be, and we are about to hash it and call it verified.
	top=$(find "${dest}/x" -mindepth 1 -maxdepth 1 -print)
	[ "$(printf '%s\n' "$top" | grep -c .)" = 1 ] || \
		die "Oh My Zsh archive has an unexpected layout (expected exactly one top-level directory)"
	[ -d "$top" ] || die "Oh My Zsh archive top-level entry is not a directory: $top"
	printf '%s\n' "$top"
}

# --omz-repin: fetch, hash, print, stop. Builds nothing, writes nothing outside
# a temp directory. This is the only supported way to produce the value for
# --omz-tree-sha256, because eyeballing a digest out of a build log invites
# pinning whatever you happened to download rather than what you reviewed.
if [ -n "$OMZ_REPIN" ]; then
	need curl tar sha256sum find sort
	repin_tmp=$(mktemp -d "${TMPDIR:-/tmp}/omni-omz-repin.XXXXXX") || die "mktemp failed"
	trap 'rm -rf -- "$repin_tmp"' EXIT
	repin_top=$(omz_extract "$OMZ_REPIN" "$repin_tmp")
	printf '\n'
	printf 'OMZ_COMMIT="%s"\n' "$OMZ_REPIN"
	printf 'OMZ_TREE_SHA256="%s"\n' "$(omz_tree_digest "$repin_top")"
	printf '\n'
	printf 'Paste both lines into rootfs/build-rootfs.sh. Read the upstream diff\n' >&2
	printf 'first: this is a shell that runs as root at every login on every device.\n' >&2
	exit 0
fi

# --------------------------------------------------------------------------- validation
need mmdebstrap tar gzip sha256sum sed grep find awk sort mke2fs dumpe2fs e2fsck truncate
# Only required when Tailscale is being fetched; checked here so the build stops
# in its precondition phase rather than after mmdebstrap has done its work.
if [ "$TAILSCALE" = 1 ]; then need curl; fi
# Same, for Oh My Zsh. --omz-tar skips the download, so curl is only required
# when there is actually something to fetch.
if [ "$ZSH_SHELL" = 1 ] && [ -z "$OMZ_TGZ_IN" ]; then need curl; fi
if [ "$ZSH_SHELL" = 1 ]; then
	[ -r "${ZSH_DIR}/zshrc" ] || die "zsh requested but ${ZSH_DIR}/zshrc is missing"
	[ -r "${ZSH_DIR}/omni.zsh-theme" ] || die "zsh requested but ${ZSH_DIR}/omni.zsh-theme is missing"
	# The plugin list is deleted down to this set, so a name that does not exist
	# upstream becomes "[oh-my-zsh] plugin 'x' not found" on every login of every
	# device -- a per-login error message shipped in firmware. Cheap to catch the
	# obvious form of it here; the real existence check is in the prune step,
	# which has the tree in front of it.
	case "$OMZ_PLUGINS" in
	*[!A-Za-z0-9_.\ -]*) die "--omz-plugins: names must be plugin directory names separated by spaces: $OMZ_PLUGINS";;
	esac
fi

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

# SSH authorised keys. Resolved here so a bad key fails in the first second of
# the build rather than after the ~9 minutes it takes to reach the overlay hook.
if [ -n "$SSH_PUBKEY_FILE" ]; then
	if [ "$SSH_PUBKEY_FILE" = "-" ]; then
		SSH_PUBKEY="${SSH_PUBKEY}${SSH_PUBKEY:+$'\n'}$(cat)"
	else
		[ -r "$SSH_PUBKEY_FILE" ] || die "--ssh-pubkey-file: not readable: $SSH_PUBKEY_FILE"
		SSH_PUBKEY="${SSH_PUBKEY}${SSH_PUBKEY:+$'\n'}$(cat -- "$SSH_PUBKEY_FILE")"
	fi
fi

SSH_KEYS_RESOLVED=""
_ssh_key_count=0
while IFS= read -r _line; do
	case "$_line" in
	''|'#'*) continue ;;
	# A private key in an image is a far worse outcome than no key at all, and
	# the mistake is easy to make with `--ssh-pubkey-file ~/.ssh/id_ed25519`.
	*"PRIVATE KEY"*)
		die "--ssh-pubkey/--ssh-pubkey-file was given a PRIVATE key.
Only public keys belong in an image. You probably meant the .pub file." ;;
	ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*|sk-ssh-ed25519*|sk-ecdsa-*)
		SSH_KEYS_RESOLVED="${SSH_KEYS_RESOLVED}${SSH_KEYS_RESOLVED:+$'\n'}${_line}"
		_ssh_key_count=$((_ssh_key_count + 1)) ;;
	*)
		die "unrecognised SSH public key line: ${_line%% *}...
Expected one of ssh-ed25519, ssh-rsa, ecdsa-sha2-*, sk-ssh-ed25519, sk-ecdsa-*.
sshd silently ignores lines it cannot parse, so this fails the build instead." ;;
	esac
done <<<"$SSH_PUBKEY"

if [ "$_ssh_key_count" -eq 0 ] && [ "$ALLOW_NO_SSH_KEY" != 1 ]; then
	die "no SSH public key given, and password authentication is disabled in this image.
sshd_config.d/10-omni.conf sets PasswordAuthentication no and root's password is
locked to '*', so an image with no authorised key is reachable ONLY over the
serial console -- on a deployed unit, that means a site visit.

Supply one of:
    --ssh-pubkey 'ssh-ed25519 AAAA... you@host'
    --ssh-pubkey-file ~/.ssh/id_ed25519.pub
    OMNI_SSH_PUBKEY='ssh-ed25519 AAAA... you@host'   (env)

or pass --allow-no-ssh-key if serial-only access is what you actually want.

The key is deliberately NOT committed to this repository: it would make every
image built from it trust one person and nobody else."
fi
# NOT `[ ... ] && info ...`: under `set -e` the false branch would abort the
# build, so --allow-no-ssh-key would fail exactly when it is meant to succeed.
if [ "$_ssh_key_count" -gt 0 ]; then
	info "authorising ${_ssh_key_count} SSH public key(s) for root"
else
	warn "building with NO authorised SSH key (--allow-no-ssh-key): serial console only"
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
	'?omni-tailscale-auth.service'
	'?tailscaled.service'
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
# The authorised key(s) come from the build environment, never from a committed
# file -- see the --ssh-pubkey handling in build-rootfs.sh. The overlay ships
# only the documentation header; the keys are appended here.
if [ -n "${OMNI_SSH_KEYS:-}" ]; then
	mkdir -p "${chroot_dir}/root/.ssh"
	printf '%s\n' "$OMNI_SSH_KEYS" >> "${chroot_dir}/root/.ssh/authorized_keys"
	echo "I: 10-overlay: authorised $(printf '%s\n' "$OMNI_SSH_KEYS" | grep -c .) SSH key(s) for root"
fi
# root must own these, not the build user's uid: sshd's StrictModes silently
# refuses an authorized_keys owned by anyone else, and with password auth off
# that refusal means no network login at all.
if [ -d "${chroot_dir}/root/.ssh" ]; then
	chown -R 0:0 "${chroot_dir}/root/.ssh"
	chmod 0700 "${chroot_dir}/root/.ssh"
fi
# sshd also refuses an authorized_keys that is writable by group or other.
# An `if`, not `[ ... ] && ...`: under `set -e` the false branch aborts the hook,
# and with the key no longer committed the file can legitimately be absent.
if [ -f "${chroot_dir}/root/.ssh/authorized_keys" ]; then
	chmod 0600 "${chroot_dir}/root/.ssh/authorized_keys"
fi
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
cat >"${HOOK_DIR}/25-tailscale.sh" <<'HOOK25'
#!/bin/sh
# Install the verified Tailscale tarball. The archive was downloaded and its
# sha256 checked on the build host before this hook ran, so nothing unverified
# reaches the image.
set -eu
chroot_dir=$1
[ -n "${OMNI_TS_TGZ:-}" ] || { echo "I: 25-tailscale: not requested, skipping" >&2; exit 0; }
[ -s "$OMNI_TS_TGZ" ] || { echo "E: 25-tailscale: ${OMNI_TS_TGZ} missing" >&2; exit 1; }

tmp=$(mktemp -d)
tar xzf "$OMNI_TS_TGZ" -C "$tmp"
src=$(find "$tmp" -maxdepth 1 -type d -name 'tailscale_*_arm64' | head -1)
[ -n "$src" ] || { echo "E: 25-tailscale: unexpected tarball layout" >&2; exit 1; }

install -D -m 0755 "$src/tailscaled" "$chroot_dir/usr/sbin/tailscaled"
install -D -m 0755 "$src/tailscale"  "$chroot_dir/usr/bin/tailscale"
# Upstream's unit. Our drop-in in the overlay repoints the state at /data; this
# is installed UNDER it so the drop-in still applies.
install -D -m 0644 "$src/systemd/tailscaled.service" \
	"$chroot_dir/usr/lib/systemd/system/tailscaled.service"
install -D -m 0644 "$src/systemd/tailscaled.defaults" \
	"$chroot_dir/etc/default/tailscaled"
rm -rf "$tmp"

# /var/lib/tailscale must NOT exist: its presence is what tempts tailscaled and
# anyone debugging into using the per-slot path instead of /data.
rm -rf "$chroot_dir/var/lib/tailscale"

chroot "$chroot_dir" /bin/sh -eu <<'IN_CHROOT'
[ -x /usr/sbin/tailscaled ] || { echo "E: tailscaled not installed" >&2; exit 1; }
[ -x /usr/bin/tailscale ]   || { echo "E: tailscale not installed" >&2; exit 1; }
echo "I: 25-tailscale: $(/usr/bin/tailscale --version 2>/dev/null | head -1 || echo 'version unavailable (cross-arch)')"
IN_CHROOT
echo "I: 25-tailscale: ok"
HOOK25
chmod +x "${HOOK_DIR}/25-tailscale.sh"

# 27 — zsh + Oh My Zsh, and root's login shell.
#
# Runs after 10-overlay so it can sit on top of whatever the overlay shipped,
# and after 20-kernel so the zsh package (which came from the package list, not
# from here) is definitely unpacked and its postinst has run.
#
# THE FAILURE MODE THIS HOOK EXISTS TO PREVENT: `login -f root` execs the shell
# named in /etc/passwd. If that path does not exist, login fails, agetty
# respawns, and the serial console is a loop instead of a prompt -- on a
# headless box, in a closet, where the console is the last way in. Every step
# below is therefore checked, and the shell is only switched once the binary is
# confirmed present.
cat >"${HOOK_DIR}/27-zsh.sh" <<'HOOK27'
#!/bin/sh
set -eu
chroot_dir=$1

# --no-zsh, or a dry run: leave root on the Debian default and say so.
if [ -z "${OMNI_OMZ_TAR:-}" ] && [ "${OMNI_ZSH:-0}" != 1 ]; then
	echo "I: 27-zsh: not requested, skipping"
	exit 0
fi

# The binary comes from the package list (zsh -> zsh-common), never from here.
# If it is missing, the list was edited without this hook being turned off, and
# switching root's shell now would produce exactly the unbootable console
# described above.
if [ ! -x "${chroot_dir}/bin/zsh" ] && [ ! -x "${chroot_dir}/usr/bin/zsh" ]; then
	echo "E: 27-zsh: no zsh in the image. Add 'zsh' to the package list, or build with --no-zsh." >&2
	echo "E: 27-zsh: refusing to point root's login shell at a binary that is not there." >&2
	exit 1
fi

# Oh My Zsh, already fetched, tree-verified and pruned on the build host.
if [ -n "${OMNI_OMZ_TAR:-}" ]; then
	[ -s "$OMNI_OMZ_TAR" ] || { echo "E: 27-zsh: ${OMNI_OMZ_TAR} missing" >&2; exit 1; }
	rm -rf "${chroot_dir}/usr/share/oh-my-zsh"
	mkdir -p "${chroot_dir}/usr/share/oh-my-zsh"
	tar -C "${chroot_dir}/usr/share/oh-my-zsh" --numeric-owner -xf "$OMNI_OMZ_TAR"
	# Uniform and root-owned. compinit's compaudit refuses to load completions
	# from a directory that is group- or world-writable, and its complaint is a
	# wall of text on every login rather than a clean failure.
	find "${chroot_dir}/usr/share/oh-my-zsh" -type d -exec chmod 0755 {} +
	find "${chroot_dir}/usr/share/oh-my-zsh" -type f -exec chmod 0644 {} +
	[ -r "${chroot_dir}/usr/share/oh-my-zsh/oh-my-zsh.sh" ] || \
		{ echo "E: 27-zsh: oh-my-zsh.sh not present after unpack" >&2; exit 1; }
	echo "I: 27-zsh: oh-my-zsh installed ($(find "${chroot_dir}/usr/share/oh-my-zsh" -type f | wc -l) files)"
fi

# Ours: the prompt theme, outside the oh-my-zsh tree so a pin bump cannot
# delete it. ZSH_CUSTOM in .zshrc points here.
#
# The directory modes are set EXPLICITLY, not left to `install -D`. install
# creates missing parents at 0755 masked by the caller's umask, so a builder
# running umask 002 would produce group-writable directories -- and $ZSH_CUSTOM
# is on compinit's fpath, so compaudit would then refuse to load completions
# and print fifteen lines about it on every login, on a 115200 baud console.
# That failure depends on the umask of whoever ran the build, which is the worst
# kind of thing to leave to chance.
if [ -n "${OMNI_ZSH_THEME_SRC:-}" ]; then
	mkdir -p "${chroot_dir}/usr/share/omni/zsh/themes"
	chmod 0755 "${chroot_dir}/usr/share/omni" \
	           "${chroot_dir}/usr/share/omni/zsh" \
	           "${chroot_dir}/usr/share/omni/zsh/themes"
	install -m 0644 "$OMNI_ZSH_THEME_SRC" \
		"${chroot_dir}/usr/share/omni/zsh/themes/omni.zsh-theme"
	echo "I: 27-zsh: installed /usr/share/omni/zsh/themes/omni.zsh-theme"
fi

# /root/.zshrc. Overwrites whatever was there: this file is image content, and
# the one in rootfs/zsh/ is the only copy that gets reviewed.
if [ -n "${OMNI_ZSHRC_SRC:-}" ]; then
	install -D -m 0644 "$OMNI_ZSHRC_SRC" "${chroot_dir}/root/.zshrc"
	echo "I: 27-zsh: installed /root/.zshrc"
fi

# compinit's dump lands here. Created now so the first login does not have to,
# and so it is a real directory in the image rather than something .zshrc makes
# on a filesystem that might be read-only at the time.
mkdir -p "${chroot_dir}/var/cache/oh-my-zsh/completions"
chmod 0755 "${chroot_dir}/var/cache/oh-my-zsh" "${chroot_dir}/var/cache/oh-my-zsh/completions"

chroot "$chroot_dir" /bin/sh -eu <<'IN_CHROOT'
zsh_path=$(command -v zsh || true)
[ -n "$zsh_path" ] || { echo "E: 27-zsh: zsh not on PATH inside the chroot" >&2; exit 1; }

# usermod, not chsh: chsh validates against /etc/shells and its behaviour when
# the entry is absent differs between shadow versions. usermod just writes the
# field, and the assertion below is what actually guarantees the result.
usermod -s "$zsh_path" root
echo "I: 27-zsh: root login shell -> ${zsh_path}"

# /etc/shells for completeness -- sshd does not consult it, but `chsh` and some
# FTP/PAM paths do, and an absent entry is the kind of thing that bites once.
if [ -f /etc/shells ] && ! grep -qx "$zsh_path" /etc/shells; then
	printf '%s\n' "$zsh_path" >> /etc/shells
fi

# --- assertions ---------------------------------------------------------
fail=0

# The console-killer. root's shell field must name something executable.
shell=$(getent passwd root | cut -d: -f7)
if [ -z "$shell" ] || [ ! -x "$shell" ]; then
	echo "E: 27-zsh: root's login shell is '${shell:-<empty>}', which is not executable." >&2
	echo "E: 27-zsh: login -f root would fail and the serial getty would respawn forever." >&2
	fail=1
else
	echo "I: 27-zsh: root shell ${shell} ok"
fi

# Nothing on compinit's fpath may be group- or other-writable. When it is,
# compaudit refuses to load completions and prints fifteen lines saying so --
# on every login, on a serial console, in an image that is otherwise fine.
# It depends on the build host's umask, so it must be checked, not assumed.
for d in /usr/share/oh-my-zsh /usr/share/omni/zsh; do
	[ -d "$d" ] || continue
	bad=$(find "$d" -type d -perm /022 -print 2>/dev/null | head -n5)
	if [ -n "$bad" ]; then
		echo "E: 27-zsh: group- or other-writable directories under ${d}:" >&2
		printf 'E: 27-zsh:   %s\n' $bad >&2
		echo "E: 27-zsh: compaudit will disable completions and say so at every login." >&2
		fail=1
	fi
done

# NOTE: the "/bin/sh must not be zsh" invariant is asserted in 60-finalise,
# not here. It has to hold whether or not this hook ran -- including under
# --no-zsh -- so it belongs with the rest of the image contract.

[ "$fail" = 0 ] || exit 1
IN_CHROOT
echo "I: 27-zsh: ok"
HOOK27
chmod +x "${HOOK_DIR}/27-zsh.sh"

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
	OMNI_NO_INITRD="${OMNI_NO_INITRD:-0}" \
	OMNI_KEEP_MODULES="${OMNI_KEEP_MODULES:-}" \
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

if [ "${OMNI_NO_INITRD:-0}" = 1 ]; then
	echo "I: 50-boot: --no-initramfs: not building an initrd (recovery boot path clears ramdisk_addr_r)"
elif command -v update-initramfs >/dev/null 2>&1; then
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
if [ "${OMNI_NO_INITRD:-0}" = 1 ]; then
	echo "I: 50-boot: --no-initramfs: skipping ${rname}"
	CHECK_NAMES="$kname $dname"
	# initramfs-tools arrives as a linux-image dependency whether or not it is
	# wanted, and its postinst builds an initrd regardless. On a 450 MiB slot
	# that is 22 MiB for the initrd plus another 22 MiB once the flatten hook
	# copies it to the mender name -- 44 MiB of a file this boot path never
	# loads, because U-Boot clears ramdisk_addr_r before entering p7.
	for stale in "/boot/initrd.img-${ver}" "/boot/${rname}"; do
		if [ -f "$stale" ]; then
			echo "I: 50-boot: --no-initramfs: removing unused $stale ($(stat -c%s "$stale") bytes)"
			rm -f "$stale"
		fi
	done
else
	place "/boot/initrd.img-${ver}" "$rname"
	CHECK_NAMES="$kname $dname $rname"
fi

# --- module pruning ---------------------------------------------------------
# Keep only the named modules and their dependencies. The full tree is 212 MiB
# against a 450 MiB partition; the rest of a usable recovery system does not fit
# beside it. Dependencies are resolved through modules.dep rather than by name
# matching, because deleting a dependency of a module you kept produces a module
# that silently fails to load at the worst possible moment.
if [ -n "${OMNI_KEEP_MODULES:-}" ]; then
	KDIR="/usr/lib/modules/${ver}"
	if [ ! -f "$KDIR/modules.dep" ]; then
		echo "E: 50-boot: --keep-modules given but $KDIR/modules.dep is missing" >&2
		exit 1
	fi
	before=$(du -sk "$KDIR" | awk '{print $1}')

	# Seed: requested names -> their paths in modules.dep.
	: > /tmp/omni-keep-paths
	printf '%s\n' "$OMNI_KEEP_MODULES" | while IFS= read -r m; do
		[ -n "$m" ] || continue
		# Module names use _ and - interchangeably; modules.dep uses the filename.
		alt=$(printf '%s' "$m" | tr '_' '-')
		awk -v a="/${m}.ko" -v b="/${alt}.ko" -F: '
			{ p=$1 }
			index(p, a) || index(p, b) { print p }' "$KDIR/modules.dep"
	done | sort -u > /tmp/omni-keep-paths

	# Transitive closure: a line "path: dep1 dep2" means path needs dep1 dep2.
	rounds=0
	while [ "$rounds" -lt 12 ]; do
		n_before=$(wc -l < /tmp/omni-keep-paths)
		awk -F: 'NR==FNR { want[$1]=1; next }
		         ($1 in want) { for (i=2; i<=NF; i++) { gsub(/^ +/, "", $i); split($i, a, " ");
		                          for (j in a) if (a[j] != "") print a[j] } }' \
			/tmp/omni-keep-paths "$KDIR/modules.dep" >> /tmp/omni-keep-paths 2>/dev/null || true
		sort -u -o /tmp/omni-keep-paths /tmp/omni-keep-paths
		n_after=$(wc -l < /tmp/omni-keep-paths)
		[ "$n_before" = "$n_after" ] && break
		rounds=$((rounds + 1))
	done
	echo "I: 50-boot: keeping $(wc -l < /tmp/omni-keep-paths) modules (after $rounds dependency passes)"

	# Delete every .ko not in the keep set.
	#
	# One awk pass and one xargs, NOT a shell loop with a grep and a sed per
	# file. This hook runs inside an arm64 chroot under qemu-user on an x86
	# host, where every fork is emulated: the obvious per-file loop is ~13,000
	# emulated process spawns for a 4,400-module tree and takes longer than the
	# rest of the build put together.
	( cd "$KDIR" && find . -name '*.ko*' -type f | sed 's|^\./||' ) > /tmp/omni-all-mods
	awk 'NR==FNR { keep[$0]=1; next }
	     { b=$0; sub(/\.(zst|xz|gz)$/, "", b); if (!(b in keep)) print }' \
		/tmp/omni-keep-paths /tmp/omni-all-mods > /tmp/omni-del-mods
	deleted=$(wc -l < /tmp/omni-del-mods)
	( cd "$KDIR" && xargs -r rm -f < /tmp/omni-del-mods )
	find "$KDIR" -type d -empty -delete 2>/dev/null || true

	if command -v depmod >/dev/null 2>&1; then
		depmod -a "$ver" || echo "W: 50-boot: depmod failed after pruning" >&2
	fi
	after=$(du -sk "$KDIR" | awk '{print $1}')
	echo "I: 50-boot: pruned $deleted modules; $KDIR ${before} KiB -> ${after} KiB"
	rm -f /tmp/omni-keep-paths /tmp/omni-all-mods /tmp/omni-del-mods
fi

rc=0
for f in $CHECK_NAMES; do
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

# --- shells. Both of these are unconditional: they must hold with or without
# --no-zsh, which is why they are here rather than in the 27-zsh hook.
#
# 1. /bin/sh MUST NOT BE ZSH. The Yocto image this replaces had /bin/sh
#    symlinked to zsh, and zsh's sh emulation provides no PIPESTATUS -- which is
#    exactly how omni-backup.sh came to report every backup as truncated for as
#    long as it did. Every script that runs on the device has a '#!/bin/sh'
#    shebang and is written against POSIX. Installing zsh as an interactive
#    login shell does not change this and must never be allowed to.
sh_target=$(readlink -f /bin/sh 2>/dev/null || echo /bin/sh)
case "$sh_target" in
*zsh*)
	echo "E: 60-finalise: /bin/sh resolves to ${sh_target}." >&2
	echo "E: 60-finalise: the device tools are POSIX sh and use PIPESTATUS, which zsh's sh" >&2
	echo "E: 60-finalise: emulation does not provide. /bin/sh must stay dash." >&2
	fail=1 ;;
esac

# 2. root's login shell must exist and be executable. `login -f root` -- which
#    is what the serial autologin getty runs -- execs whatever is in this field.
#    A path that is not there means login fails, agetty respawns, and the
#    console of a headless box is a loop instead of a prompt.
root_shell=$(getent passwd root | cut -d: -f7)
if [ -n "$root_shell" ] && [ ! -x "$root_shell" ]; then
	echo "E: 60-finalise: root's login shell '${root_shell}' is not executable in this image." >&2
	echo "E: 60-finalise: the serial console would respawn forever instead of giving a prompt." >&2
	fail=1
fi

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
# Debian's /etc/update-motd.d/10-uname reprints `uname -a` immediately after our
# banner, which already reports the kernel -- it visually breaks the banner for
# no information. chmod -x rather than rm: the file belongs to a package, so a
# deletion would be restored on upgrade and look like a regression, whereas
# run-parts simply skips a non-executable file and dpkg leaves the mode alone.
[ -f /etc/update-motd.d/10-uname ] && chmod -x /etc/update-motd.d/10-uname

apt-get clean
rm -f /var/cache/apt/archives/*.deb 2>/dev/null || true
echo "I: 60-finalise: ok"
IN_CHROOT
HOOK60

chmod 0755 "${HOOK_DIR}"/*.sh

# --------------------------------------------------------------------------- mmdebstrap
# Fetch and verify Tailscale on the BUILD HOST. Deliberately not inside the
# chroot: the chroot would need network access, and an unverified binary would
# already be in the image by the time anything checked it. Here a bad checksum
# fails the build before a single byte is installed.
TS_TGZ=""
if [ "$TAILSCALE" = 1 ]; then
	TS_TGZ="${WORK_DIR}/tailscale_${TAILSCALE_VERSION}_arm64.tgz"
	TS_URL="${TAILSCALE_URL_BASE}/tailscale_${TAILSCALE_VERSION}_arm64.tgz"
	if [ "$DRY_RUN" = 1 ]; then
		# Do not pull 32 MiB on a dry run; the point of --dry-run is to validate
		# preconditions cheaply. The real run still verifies the digest.
		info "DRY RUN: would fetch and sha256-verify ${TS_URL}"
		info "DRY RUN:   expecting ${TAILSCALE_SHA256}"
		TS_TGZ=""
		TAILSCALE=0
	else
	info "fetching Tailscale ${TAILSCALE_VERSION} (arm64) from ${TS_URL}"
	curl -fL --retry 3 --retry-delay 5 --connect-timeout 20 -o "$TS_TGZ" "$TS_URL" \
		|| die "could not download Tailscale ${TAILSCALE_VERSION}"
	got=$(sha256sum "$TS_TGZ" | cut -d' ' -f1)
	if [ "$got" != "$TAILSCALE_SHA256" ]; then
		die "Tailscale checksum MISMATCH
  url      ${TS_URL}
  expected ${TAILSCALE_SHA256}
  got      ${got}
Either the pin is stale (bump TAILSCALE_VERSION and TAILSCALE_SHA256 together)
or the download is not what it claims to be. Refusing to build."
	fi
	info "Tailscale ${TAILSCALE_VERSION} verified: ${got}"
	fi
fi

# Fetch, verify and PRUNE Oh My Zsh, all on the build host. Same rule as
# Tailscale above: nothing unverified is ever inside the chroot, so a bad
# digest fails the build before a byte is installed. The pruning happens here
# too, so what goes into the image is exactly what the hook untars -- the hook
# does not get to make decisions about content.
OMZ_TAR=""
if [ "$ZSH_SHELL" = 1 ]; then
	if [ "$DRY_RUN" = 1 ]; then
		info "DRY RUN: would fetch Oh My Zsh ${OMZ_COMMIT} and verify tree digest"
		info "DRY RUN:   expecting ${OMZ_TREE_SHA256}"
		# Be honest about what a dry run does NOT cover. Whether every name in
		# --omz-plugins is a real plugin can only be answered against the
		# extracted tree, and pulling 3 MB is exactly what --dry-run avoids.
		# The real build checks it, before mmdebstrap starts.
		[ "$OMZ_ALL_PLUGINS" = 1 ] || \
			info "DRY RUN:   plugin names NOT checked here (needs the tree): ${OMZ_PLUGINS}"
	else
		omz_work="${WORK_DIR}/omz"
		omz_top=$(omz_extract "$OMZ_COMMIT" "$omz_work")

		# VERIFY BEFORE PRUNE. The pin covers the upstream tree, so hashing after
		# deleting 300 plugins would make the digest a function of --omz-plugins
		# and every plugin-list change would look like a supply-chain failure.
		omz_got=$(omz_tree_digest "$omz_top")
		if [ "$omz_got" != "$OMZ_TREE_SHA256" ]; then
			die "Oh My Zsh tree digest MISMATCH
  commit   ${OMZ_COMMIT}
  expected ${OMZ_TREE_SHA256}
  got      ${omz_got}
This is the digest of the extracted tree, not of the archive, so GitHub
recompressing the tarball is NOT a possible cause. Either the pin is stale
(re-run with --omz-repin ${OMZ_COMMIT} and read the upstream diff) or what
arrived is not the commit it claims to be. Refusing to build."
		fi
		info "Oh My Zsh ${OMZ_COMMIT} verified: ${omz_got}"

		# --- prune -------------------------------------------------------------
		# Removed: the ~300 unused plugins (11 MB), the repo's own CI and editor
		# config, the documentation, and tools/ EXCEPT check_for_upgrade.sh --
		# oh-my-zsh.sh sources that one unconditionally, and a missing file there
		# is an error printed on every login of every device. The rest of tools/
		# is install.sh / uninstall.sh / upgrade.sh, i.e. scripts whose entire job
		# is to rewrite $ZSH from the network. They have no business in firmware.
		if [ "$OMZ_ALL_PLUGINS" = 1 ]; then
			info "Oh My Zsh: keeping ALL plugins (--omz-all-plugins)"
		else
			for p in $OMZ_PLUGINS; do
				[ -d "${omz_top}/plugins/${p}" ] || die \
"--omz-plugins names '${p}', which is not a plugin in Oh My Zsh ${OMZ_COMMIT}.
Left alone this ships an image that prints \"[oh-my-zsh] plugin '${p}' not found\"
on every login. Check the spelling against plugins/ in the upstream tree."
			done
			find "${omz_top}/plugins" -mindepth 1 -maxdepth 1 -type d \
				| while IFS= read -r d; do
					case " $OMZ_PLUGINS " in
					*" ${d##*/} "*) ;;
					*) rm -rf -- "$d";;
					esac
				done
		fi
		rm -rf -- "${omz_top}/.github" "${omz_top}/.devcontainer" \
		          "${omz_top}/templates" "${omz_top}/cache" "${omz_top}/log"
		find "${omz_top}/tools" -mindepth 1 -maxdepth 1 \
			! -name check_for_upgrade.sh -exec rm -rf -- {} + 2>/dev/null || true
		rm -f -- "${omz_top}/.editorconfig" "${omz_top}/.prettierrc" \
		         "${omz_top}/.gitignore" "${omz_top}/README.md" \
		         "${omz_top}/CONTRIBUTING.md" "${omz_top}/CODE_OF_CONDUCT.md" \
		         "${omz_top}/SECURITY.md"
		# LICENSE.txt stays. It is MIT-licensed code being redistributed in a
		# firmware image; the licence text is a condition of doing that, not
		# 1 KB of dead weight.
		[ -f "${omz_top}/LICENSE.txt" ] || die "Oh My Zsh LICENSE.txt vanished during prune; refusing to ship it unlicensed"

		# Did the prune remove something the surviving code SOURCES? That is the
		# general form of the tools/check_for_upgrade.sh trap above: oh-my-zsh.sh
		# sources that file unconditionally, so deleting it would print "no such
		# file or directory" on every login of every device. This makes the next
		# pin bump that moves a sourced file fail the BUILD instead.
		#
		# Deliberately scoped to `source X` / `. X` and nothing wider. Matching
		# every "$ZSH/..." string instead also hits the bodies of `omz update`,
		# `omz changelog` and `omz uninstall`, which name tools/upgrade.sh and
		# friends -- files this prune removes ON PURPOSE. Those commands are
		# meant to be broken here: a shell that rewrites the firmware from the
		# network is not something an appliance should carry.
		omz_missing=""
		while IFS= read -r ref; do
			[ -n "$ref" ] || continue
			case "$ref" in *'$'*|*'{'*|*'*'*) continue;; esac  # computed at runtime, skip
			[ -e "${omz_top}/${ref}" ] || omz_missing="${omz_missing} ${ref}"
		done <<-EOF
			$(grep -rhoE '(^|[;&|[:space:]])(source|\.)[[:space:]]+"?\$ZSH/[A-Za-z0-9_./-]+' "$omz_top" 2>/dev/null \
			  | sed -E 's|.*\$ZSH/||' | sort -u)
		EOF
		[ -z "$omz_missing" ] || die \
"the Oh My Zsh prune removed files that the remaining code still sources:${omz_missing}
Add them to the keep-list in this block, or the image prints an error on every
login. (This is exactly why tools/check_for_upgrade.sh is kept.)"

		OMZ_TAR="${WORK_DIR}/ohmyzsh.tar"
		tar -C "$omz_top" --owner=0 --group=0 --numeric-owner --sort=name \
			-cf "$OMZ_TAR" .
		info "Oh My Zsh pruned to $(find "$omz_top" -type f | wc -l) files, $(du -sk "$omz_top" | cut -f1) KiB"
	fi
fi

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
export OMNI_TS_TGZ="${TS_TGZ}"
export OMNI_ZSH="${ZSH_SHELL}"
export OMNI_OMZ_TAR="${OMZ_TAR}"
if [ "$ZSH_SHELL" = 1 ]; then
	export OMNI_ZSHRC_SRC="${ZSH_DIR}/zshrc"
	export OMNI_ZSH_THEME_SRC="${ZSH_DIR}/omni.zsh-theme"
else
	export OMNI_ZSHRC_SRC="" OMNI_ZSH_THEME_SRC=""
fi
MM+=("--customize-hook=${HOOK_DIR}/10-overlay.sh"
     "--customize-hook=${HOOK_DIR}/20-kernel.sh"
     "--customize-hook=${HOOK_DIR}/25-tailscale.sh"
     "--customize-hook=${HOOK_DIR}/27-zsh.sh"
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
export OMNI_NO_INITRD="$NO_INITRAMFS"
# Passed as the LIST, not the path: the hook runs inside the chroot, where the
# file on the build host does not exist.
if [ -n "$KEEP_MODULES" ]; then
	[ -r "$KEEP_MODULES" ] || die "--keep-modules: not readable: $KEEP_MODULES"
	OMNI_KEEP_MODULES=$(grep -vE '^\s*#|^\s*$' "$KEEP_MODULES" || true)
	[ -n "$OMNI_KEEP_MODULES" ] || die "--keep-modules: $KEEP_MODULES lists no modules"
	export OMNI_KEEP_MODULES
	info "pruning modules to $(printf '%s\n' "$OMNI_KEEP_MODULES" | wc -l) named + dependencies"
fi
export OMNI_ALLOW_UNVERIFIED="$ALLOW_UNVERIFIED"
export OMNI_FORBIDDEN="${FORBIDDEN_PACKAGES[*]}"
export OMNI_SSH_KEYS="$SSH_KEYS_RESOLVED"

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
if [ "$ZSH_SHELL" = 1 ]; then
	if [ "$OMZ_ALL_PLUGINS" = 1 ]; then
		info "root shell      zsh + oh-my-zsh ${OMZ_COMMIT} (all plugins)"
	else
		info "root shell      zsh + oh-my-zsh ${OMZ_COMMIT} [${OMZ_PLUGINS}]"
	fi
else
	info "root shell      Debian default (--no-zsh)"
fi
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

	# Device-side operator tools, APPENDED to the same tar rather than kept as a
	# second copy under overlay/. Two copies of omni-flash.sh in one repository
	# drift, and the one that drifts is the one you need at 2 a.m.
	#
	# They go in /usr/sbin, not /usr/local/sbin, for a specific reason: on Debian
	# root's PATH has /usr/local/sbin FIRST, so a hand-copied newer script there
	# still wins. Shipping into /usr/local/sbin would have the image fight the
	# override instead of yielding to it.
	#
	# WHY THIS EXISTS AT ALL: these used to be copied in by hand per slot, and
	# /usr/local/sbin is per-slot. Boot the other half of an A/B pair and they
	# are simply gone -- which is how a flash of p7 silently did nothing, because
	# omni-flash.sh was on the slot we had just booted away from. An appliance
	# that cannot update itself without a laptop first copying scripts in is not
	# finished.
	if [ "$WITH_DEVICE_TOOLS" = 1 ]; then
		[ -d "$TOOLS_DIR" ] || die "--tools-dir: not a directory: $TOOLS_DIR"
		missing=""
		for t in $DEVICE_TOOLS; do
			[ -r "${TOOLS_DIR}/${t}" ] || missing="${missing} ${t}"
		done
		[ -z "$missing" ] || die "device tools missing from ${TOOLS_DIR}:${missing}"
		# --mode=0755 rather than trusting the checkout: git records only the
		# exec bit, and a tool that arrives non-executable is inert in exactly
		# the same silent way a missing one is.
		# shellcheck disable=SC2086
		tar -rf "$OVERLAY_TAR" -C "$TOOLS_DIR" \
			--owner=0 --group=0 --numeric-owner --mode=0755 \
			--transform='s,^,./usr/sbin/,' $DEVICE_TOOLS
		log "installed device tools into /usr/sbin: $DEVICE_TOOLS"
	else
		warn "--no-device-tools: the image cannot flash or roll back itself"
	fi
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
root-shell           $([ "$ZSH_SHELL" = 1 ] && echo zsh || echo "debian-default")
omz-commit           $([ "$ZSH_SHELL" = 1 ] && echo "${OMZ_COMMIT}" || echo "(none)")
omz-tree-sha256      $([ "$ZSH_SHELL" = 1 ] && echo "${OMZ_TREE_SHA256}" || echo "(none)")
omz-plugins          $([ "$ZSH_SHELL" = 1 ] && { [ "$OMZ_ALL_PLUGINS" = 1 ] && echo "(all)" || echo "${OMZ_PLUGINS}"; } || echo "(none)")
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

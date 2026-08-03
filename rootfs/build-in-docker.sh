#!/bin/bash
#
# build-in-docker.sh — run rootfs/build-rootfs.sh inside the builder container.
#
# The host has no mmdebstrap, no e2fsprogs 1.47 and no passwordless sudo, so everything
# happens in the container. Only two things are host properties and cannot be containerised:
#   * binfmt_misc (arm64 emulation registration) — checked here, with the fix printed
#   * the ability to create user namespaces — mmdebstrap --mode=unshare needs it, hence the
#     seccomp/apparmor opt-outs below
#
set -euo pipefail

PROG=${0##*/}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)

IMAGE=${OMNI_ROOTFS_IMAGE:-omni-rootfs-builder}
DO_BUILD=1
PRIVILEGED=0
DRY_RUN=0
declare -a EXTRA_MOUNTS=()
declare -a FORWARD=()

usage() {
	cat <<EOF
$PROG — build the Avast Omni Debian slot image inside Docker.

USAGE
  $PROG [wrapper options] [-- ] [build-rootfs.sh options]

WRAPPER OPTIONS
  --image NAME      container image tag (default ${IMAGE}, env OMNI_ROOTFS_IMAGE)
  --no-build        do not rebuild the container image first
  --privileged      run the container --privileged. Last resort when the host blocks
                    unprivileged user namespaces even with seccomp/apparmor unconfined.
  -n, --dry-run     print the docker commands and exit (does not imply build-rootfs --dry-run)
  -h, --help        this text

Everything else is forwarded verbatim to build-rootfs.sh, e.g.

  $PROG --kernel-debs /path/to/debs --blocks-from omni-p1-dumpe2fs.txt
  $PROG --dry-run                 # validate inputs inside the container, write nothing
  $PROG --help                    # (after --) shows the builder's own options

The repository is bind-mounted at /workdir. Paths passed to build-rootfs.sh must live
inside it; a --kernel-debs directory outside the repo is bind-mounted read-only at
/kernel-debs automatically.

Outputs land in ${SCRIPT_DIR}/out, owned by $(id -un).
EOF
}

log()  { printf '%s\n' "==> $*" >&2; }
warn() { printf '%s\n' "WARNING: $*" >&2; }
die()  { printf '%s\n' "ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case "$1" in
	--image)      IMAGE=${2:?--image needs a value}; shift 2;;
	--no-build)   DO_BUILD=0; shift;;
	--privileged) PRIVILEGED=1; shift;;
	-n|--dry-run) DRY_RUN=1; shift;;
	-h|--help)    usage; exit 0;;
	--)           shift; FORWARD+=("$@"); break;;
	*)            FORWARD+=("$1"); shift;;
	esac
done

command -v docker >/dev/null 2>&1 || die "docker is not installed or not on PATH"
docker info >/dev/null 2>&1 || die "cannot talk to the docker daemon (is it running, and is $(id -un) in the docker group?)"

# --- host binfmt check. Not containerisable: binfmt_misc is global kernel state.
if [ "$(uname -m)" != "aarch64" ]; then
	found=0
	for reg in /proc/sys/fs/binfmt_misc/qemu-aarch64*; do
		[ -f "$reg" ] || continue
		grep -qx 'enabled' "$reg" && { found=1; break; }
	done
	[ "$found" = 1 ] || die \
"no enabled binfmt_misc registration for aarch64 on this HOST.
mmdebstrap has to execute arm64 maintainer scripts, and binfmt_misc is host-kernel state —
installing qemu inside the container does not help. Register it once:

    docker run --privileged --rm tonistiigi/binfmt --install arm64

  or, persistently:

    sudo apt-get install qemu-user-static binfmt-support

Then re-run $PROG."
fi

# --- rewrite a --kernel-debs path that lives outside the repo into a bind mount
for i in "${!FORWARD[@]}"; do
	[ "${FORWARD[$i]}" = "--kernel-debs" ] || continue
	j=$((i + 1))
	[ "$j" -lt "${#FORWARD[@]}" ] || die "--kernel-debs needs a value"
	kd=${FORWARD[$j]}
	[ -d "$kd" ] || die "--kernel-debs: not a directory: $kd"
	kd=$(cd -- "$kd" && pwd)
	case "$kd" in
		"$REPO_ROOT"/*) FORWARD[$j]="/workdir${kd#"$REPO_ROOT"}";;
		*) EXTRA_MOUNTS+=(-v "${kd}:/kernel-debs:ro"); FORWARD[$j]="/kernel-debs"
		   log "bind-mounting ${kd} at /kernel-debs (read-only)";;
	esac
	break
done

declare -a BUILD_CMD=(docker build
	-f "${SCRIPT_DIR}/Dockerfile"
	--build-arg "UID=$(id -u)"
	--build-arg "GID=$(id -g)"
	-t "$IMAGE"
	"$SCRIPT_DIR")

declare -a RUN_CMD=(docker run --rm
	--env "UID=$(id -u)"
	--env "GID=$(id -g)")
# The authorised SSH key is a build input rather than a committed file, so it has
# to cross the container boundary.
#
# OMNI_SSH_PUBKEY_FILE is resolved HERE, on the host, and forwarded as the key
# itself. Passing the variable through unchanged would hand the container a host
# path such as ~/.ssh/id_ed25519.pub, which does not exist inside it -- only the
# repository is mounted -- and the build would fail with a confusing "not
# readable" on a file the user can plainly see.
_ssh_pubkey="${OMNI_SSH_PUBKEY:-}"
if [ -n "${OMNI_SSH_PUBKEY_FILE:-}" ]; then
	[ -r "$OMNI_SSH_PUBKEY_FILE" ] ||
		die "OMNI_SSH_PUBKEY_FILE is not readable on this host: $OMNI_SSH_PUBKEY_FILE"
	_ssh_pubkey="${_ssh_pubkey}${_ssh_pubkey:+$'\n'}$(cat -- "$OMNI_SSH_PUBKEY_FILE")"
fi
if [ -n "$_ssh_pubkey" ]; then
	RUN_CMD+=(--env "OMNI_SSH_PUBKEY=${_ssh_pubkey}")
fi
# --ssh-pubkey / --allow-no-ssh-key on the command line still work: they are in
# "$@" and forwarded with everything else below.
[ -t 1 ] && RUN_CMD+=(-t)
if [ "$PRIVILEGED" = 1 ]; then
	RUN_CMD+=(--privileged)
else
	# mmdebstrap --mode=unshare calls clone(CLONE_NEWUSER); docker's default seccomp profile
	# denies that, and Ubuntu's apparmor userns restriction denies it again.
	RUN_CMD+=(--security-opt seccomp=unconfined --security-opt apparmor=unconfined)
fi
RUN_CMD+=(-v "${REPO_ROOT}:/workdir")
[ ${#EXTRA_MOUNTS[@]} -gt 0 ] && RUN_CMD+=("${EXTRA_MOUNTS[@]}")
RUN_CMD+=(-w /workdir "$IMAGE"
	/workdir/rootfs/build-rootfs.sh
	# scratch on the bind mount, not the container's writable layer: the tar, the unpacked
	# rootdir and the raw image are ~3 GiB together and the graph driver is usually smaller.
	--work /workdir/rootfs/.work)
[ ${#FORWARD[@]} -gt 0 ] && RUN_CMD+=("${FORWARD[@]}")

if [ "$DRY_RUN" = 1 ]; then
	[ "$DO_BUILD" = 1 ] && { printf '%q ' "${BUILD_CMD[@]}"; printf '\n'; }
	printf '%q ' "${RUN_CMD[@]}"; printf '\n'
	exit 0
fi

mkdir -p "${SCRIPT_DIR}/out" "${SCRIPT_DIR}/.work"

if [ "$DO_BUILD" = 1 ]; then
	log "building ${IMAGE}"
	"${BUILD_CMD[@]}"
else
	docker image inspect "$IMAGE" >/dev/null 2>&1 || die "--no-build given but image ${IMAGE} does not exist"
fi

log "running build-rootfs.sh in ${IMAGE}"
"${RUN_CMD[@]}"

log "artifacts in ${SCRIPT_DIR}/out"
ls -la "${SCRIPT_DIR}/out" >&2 || true

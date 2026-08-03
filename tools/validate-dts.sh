#!/usr/bin/env bash
#
# validate-dts.sh — compile the Omni device tree against real mainline kernel
# headers and report every warning.
#
# Why this exists: a DTS mistake (a phandle that does not exist in the target
# dtsi, a macro whose header was never included, a node name that disagrees
# with its own reg) is invisible until the board fails to boot. On a device in
# a closet with no serial cable that is an expensive way to find out. This
# script turns those into a 5-second local failure.
#
# It is deliberately independent of Armbian: it preprocesses and compiles the
# DTS directly, so it works before the submodule is built and runs in CI in
# seconds. `./compile.sh dts-check` inside Armbian remains the integration
# check; this is the fast inner loop.
#
# Usage:
#   tools/validate-dts.sh [--dts FILE] [--kernel-src DIR] [--kernel-ver TAG]
#                         [--out DIR] [--docker] [--strict]
#
#   --dts FILE         DTS to compile      (default: board/meson-axg-apollo.dts)
#   --kernel-src DIR   Existing kernel tree containing arch/arm64/boot/dts and
#                      include/dt-bindings. If omitted, a sparse checkout is
#                      fetched into .cache/ and reused on later runs.
#   --kernel-ver TAG   Kernel tag to fetch when auto-fetching (default: v6.12)
#   --out DIR          Where to write the .dtb and decompiled .dts
#                      (default: build/dts)
#   --docker           Run the toolchain in a container instead of using the
#                      host's cpp/dtc (for hosts without device-tree-compiler)
#   --strict           Treat dtc warnings as failures
#
# Exit status: 0 = compiled clean, 1 = compile failed, 2 = warnings in --strict.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DTS="${REPO_ROOT}/board/meson-axg-apollo.dts"
KERNEL_SRC=""
KERNEL_VER="v6.12"
OUT="${REPO_ROOT}/build/dts"
USE_DOCKER=0
STRICT=0

die() { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mWARN:\033[0m %s\n' "$*" >&2; }

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//;$d'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dts)        DTS="$2"; shift 2 ;;
    --kernel-src) KERNEL_SRC="$2"; shift 2 ;;
    --kernel-ver) KERNEL_VER="$2"; shift 2 ;;
    --out)        OUT="$2"; shift 2 ;;
    --docker)     USE_DOCKER=1; shift ;;
    --strict)     STRICT=1; shift ;;
    -h|--help)    usage ;;
    *)            die "unknown argument: $1 (try --help)" ;;
  esac
done

[ -f "$DTS" ] || die "DTS not found: $DTS"

# ---------------------------------------------------------------------------
# Kernel sources. We only need the amlogic DT directory and include/dt-bindings,
# so a blobless sparse checkout keeps this at ~20 MB instead of ~4 GB.
# ---------------------------------------------------------------------------
if [ -z "$KERNEL_SRC" ]; then
  KERNEL_SRC="${REPO_ROOT}/.cache/linux-${KERNEL_VER}"
  if [ ! -d "${KERNEL_SRC}/include/dt-bindings" ]; then
    info "fetching mainline ${KERNEL_VER} DT sources (sparse, one time) …"
    mkdir -p "$(dirname "$KERNEL_SRC")"
    rm -rf "$KERNEL_SRC"
    git clone --depth=1 --filter=blob:none --no-checkout \
        --branch "$KERNEL_VER" https://github.com/torvalds/linux.git "$KERNEL_SRC" >/dev/null 2>&1 \
      || die "could not fetch kernel sources for ${KERNEL_VER}"
    # include/uapi/linux is required too: dt-bindings/input/linux-event-codes.h
    # is a symlink into it, so KEY_* macros fail to resolve without it.
    git -C "$KERNEL_SRC" sparse-checkout set --no-cone \
        'arch/arm64/boot/dts' 'include/dt-bindings' 'include/uapi/linux' >/dev/null 2>&1
    git -C "$KERNEL_SRC" checkout >/dev/null 2>&1
  fi
fi

[ -d "${KERNEL_SRC}/include/dt-bindings" ] \
  || die "kernel source has no include/dt-bindings: ${KERNEL_SRC}"
[ -f "${KERNEL_SRC}/arch/arm64/boot/dts/amlogic/meson-axg.dtsi" ] \
  || die "kernel source has no meson-axg.dtsi: ${KERNEL_SRC}"

mkdir -p "$OUT"

DTS_BASE="$(basename "$DTS" .dts)"
AMLOGIC_DIR="${KERNEL_SRC}/arch/arm64/boot/dts/amlogic"

# The DTS does `#include "meson-axg.dtsi"` with a relative path, so it has to be
# preprocessed from inside the amlogic directory. Stage a copy there rather than
# mutating the checkout in place.
STAGED="${AMLOGIC_DIR}/${DTS_BASE}.staged.dts"
cleanup() { rm -f "$STAGED"; }
trap cleanup EXIT
cp "$DTS" "$STAGED"

PRE="${OUT}/${DTS_BASE}.pre.dts"
DTB="${OUT}/${DTS_BASE}.dtb"
DECOMP="${OUT}/${DTS_BASE}.decompiled.dts"
WARNLOG="${OUT}/${DTS_BASE}.dtc-warnings.txt"

# ---------------------------------------------------------------------------
# Toolchain: host by default, container when asked (or when dtc is missing).
# ---------------------------------------------------------------------------
if [ "$USE_DOCKER" -eq 0 ] && ! command -v dtc >/dev/null 2>&1; then
  warn "dtc not found on host; falling back to --docker"
  USE_DOCKER=1
fi
if [ "$USE_DOCKER" -eq 0 ] && ! command -v cpp >/dev/null 2>&1; then
  warn "cpp not found on host; falling back to --docker"
  USE_DOCKER=1
fi

IMAGE="omni-dts-validate:latest"
if [ "$USE_DOCKER" -eq 1 ]; then
  command -v docker >/dev/null 2>&1 || die "--docker requested but docker is not installed"
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    info "building $IMAGE …"
    docker build -q -f "${REPO_ROOT}/tools/dts-validate.Dockerfile" -t "$IMAGE" "${REPO_ROOT}/tools" >/dev/null
  fi
fi

run() {
  if [ "$USE_DOCKER" -eq 1 ]; then
    docker run --rm \
      -u "$(id -u):$(id -g)" \
      -v "${KERNEL_SRC}:${KERNEL_SRC}" \
      -v "${OUT}:${OUT}" \
      -w "$AMLOGIC_DIR" \
      "$IMAGE" "$@"
  else
    ( cd "$AMLOGIC_DIR" && "$@" )
  fi
}

# ---------------------------------------------------------------------------
# 1. Preprocess. -nostdinc + -undef so only kernel headers are visible; a macro
#    resolved from the host's libc headers would be a false pass.
# ---------------------------------------------------------------------------
info "preprocessing $(basename "$DTS") …"
if ! run cpp -nostdinc \
      -I "${KERNEL_SRC}/include" \
      -I "${KERNEL_SRC}/arch/arm64/boot/dts" \
      -I "$AMLOGIC_DIR" \
      -undef -D__DTS__ -x assembler-with-cpp \
      -o "$PRE" "$STAGED"; then
  die "preprocessing failed — almost always a missing #include for a macro you used"
fi

# ---------------------------------------------------------------------------
# 2. Compile. Warnings are captured rather than swallowed: unit_address_vs_reg
#    is exactly the class of mistake that produced the original ramoops@f9800000
#    node whose reg said 0x0f400000.
# ---------------------------------------------------------------------------
#    node_name_chars_strict / property_name_chars_strict are deliberately NOT
#    enabled: mainline meson-axg.dtsi uses underscores in every pinctrl group
#    name, so they emit ~40 warnings we neither caused nor can fix, which buries
#    the ones that matter.
info "compiling to dtb …"
set +e
run dtc -I dts -O dtb -o "$DTB" \
    -W no-simple_bus_reg \
    -W unit_address_vs_reg \
    "$PRE" 2> "$WARNLOG"
DTC_RC=$?
set -e

if [ $DTC_RC -ne 0 ]; then
  printf '\n'; cat "$WARNLOG" >&2; printf '\n'
  die "dtc failed to compile the device tree"
fi

# ---------------------------------------------------------------------------
# 3. Decompile. The plan requires a node-for-node diff of old vs new
#    `dtc -I dtb -O dts`; this produces the "new" side of that comparison.
# ---------------------------------------------------------------------------
info "decompiling for audit diff …"
run dtc -I dtb -O dts -o "$DECOMP" "$DTB" 2>/dev/null

# Split warnings by origin. cpp preserves original filenames in its line
# markers, so dtc attributes each warning to the file that really produced it.
# Warnings from the upstream dtsi are not ours to fix and must not mask ours.
OURS="${OUT}/${DTS_BASE}.warnings-ours.txt"
grep -F "$(basename "$STAGED")" "$WARNLOG" > "$OURS" 2>/dev/null || true

count_lines() { [ -s "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
WARN_TOTAL=$(count_lines "$WARNLOG")
WARN_OURS=$(count_lines "$OURS")
WARN_UPSTREAM=$(( WARN_TOTAL - WARN_OURS ))

printf '\n'
info "device tree compiled successfully"
printf '    dtb            %s (%s bytes)\n' "$DTB" "$(stat -c%s "$DTB")"
printf '    decompiled     %s\n' "$DECOMP"
printf '    warnings       %s in %s, %s inherited from mainline dtsi\n' \
       "$WARN_OURS" "$(basename "$DTS")" "$WARN_UPSTREAM"

if [ "$WARN_OURS" -gt 0 ]; then
  printf '\n'
  info "warnings attributable to $(basename "$DTS"):"
  sed "s|${AMLOGIC_DIR}/||; s/^/    /" "$OURS" >&2
  if [ "$STRICT" -eq 1 ]; then
    printf '\n'; die "--strict: %s warning(s) in %s" "$WARN_OURS" "$(basename "$DTS")"
  fi
else
  info "no warnings attributable to $(basename "$DTS")"
fi

exit 0

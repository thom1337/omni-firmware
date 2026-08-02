#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# sync-armbian-board.sh - push the Omni's board files into the armbian/ submodule.
#
# ONE-WAY, ALWAYS: board/ and tools/ are the source of truth; armbian/ is a
# pinned, disposable build tree. Nothing is ever read out of armbian/ and
# written back into board/. Re-running this script is a no-op when nothing
# changed (rsync --checksum), so it is safe to call from a Makefile or from CI
# before every build.
#
# Run it after: a fresh clone, `git submodule update`, any edit under board/,
# or any armbian/ submodule bump.

set -euo pipefail

# ------------------------------------------------------------------------------
# Defaults
# ------------------------------------------------------------------------------
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

BOARD_DIR="${REPO_ROOT}/board"
ARMBIAN_DIR="${REPO_ROOT}/armbian"

BOARD="avast-omni"
LINUXFAMILY="meson64"
BRANCH="oldlts"          # Armbian branch name; part of the kernel config file name
KERNEL_VERSION="6.12"    # must match AVAST_OMNI_PINNED_KERNEL in the hook
DTS_NAME="meson-axg-apollo.dts"

DRY_RUN="no"
VERBOSE="no"

# ------------------------------------------------------------------------------
# Output helpers
# ------------------------------------------------------------------------------
if [[ -t 1 ]]; then
	C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
	C_RED=""; C_YEL=""; C_GRN=""; C_DIM=""; C_OFF=""
fi

info()  { printf '%s\n' "  $*"; }
ok()    { printf '%s\n' "${C_GRN}  ok${C_OFF}   $*"; }
warn()  { printf '%s\n' "${C_YEL}  warn${C_OFF} $*" >&2; }
debug() { [[ "${VERBOSE}" == "yes" ]] && printf '%s\n' "${C_DIM}  dbg  $*${C_OFF}" >&2 || true; }
die()   { printf '%s\n' "${C_RED}ERROR${C_OFF} ${SCRIPT_NAME}: $*" >&2; exit 1; }

usage() {
	cat <<-EOF
	${SCRIPT_NAME} - one-way sync of Omni board files into the armbian/ build tree.

	USAGE
	    ${SCRIPT_NAME} [OPTIONS]

	OPTIONS
	    -n, --dry-run            Show exactly what would be written; change nothing.
	    -a, --armbian DIR        Path to the armbian/build checkout.
	                             (default: ${ARMBIAN_DIR})
	    -b, --branch NAME        Armbian kernel branch name, sets the kernel config
	                             override file name. (default: ${BRANCH})
	    -k, --kernel-version X.Y Kernel series, selects the DTS drop directory
	                             patch/kernel/archive/${LINUXFAMILY}-X.Y/dt/.
	                             (default: ${KERNEL_VERSION})
	    -v, --verbose            Print resolved paths and rsync itemisation.
	    -h, --help               This text.

	WHAT IT COPIES  (source -> destination, always in this direction only)

	    board/${BOARD}.csc
	        -> armbian/config/boards/${BOARD}.csc
	           Board config. Also read from userpatches/config/boards, but Armbian
	           sources BOTH paths additively, so keep exactly one copy.

	    board/${DTS_NAME}                        [optional until Phase 3]
	        -> armbian/patch/kernel/archive/${LINUXFAMILY}-${KERNEL_VERSION}/dt/${DTS_NAME}
	           Picked up by the dts-directories rule in that archive's
	           0000.patching_config.yaml, which also auto-patches the DT Makefile.

	    board/linux-${LINUXFAMILY}-omni.config   [MERGED, not copied]
	        + armbian/config/kernel/linux-${LINUXFAMILY}-${BRANCH}.config   (upstream base)
	        -> armbian/userpatches/config/kernel/linux-${LINUXFAMILY}-${BRANCH}.config
	           Armbian has no fragment mechanism - that override path REPLACES the
	           whole config (kernel-config.sh:17-19,69). So the delta is merged
	           onto the pinned submodule's own base config on every run, and the
	           per-line trailing comments are stripped.

	    board/post_family_config__${BOARD}.sh
	        -> armbian/userpatches/extensions/post_family_config__${BOARD}.sh
	           Loaded by enable_extension() from the board config; pins
	           KERNEL_MAJOR_MINOR and forces CONFIG_OVERLAY_FS=y.

	EXIT STATUS
	    0  everything in place (or, with --dry-run, nothing prevented it)
	    1  precondition failed - submodule missing, tool missing, upstream moved

	EXAMPLES
	    ${SCRIPT_NAME} --dry-run
	    ${SCRIPT_NAME}
	    ${SCRIPT_NAME} --branch current --kernel-version 6.18   # evaluating 6.18
	EOF
}

# ------------------------------------------------------------------------------
# Argument parsing (no interactive input, ever)
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
	case "$1" in
		-n|--dry-run) DRY_RUN="yes"; shift ;;
		-v|--verbose) VERBOSE="yes"; shift ;;
		-h|--help)    usage; exit 0 ;;
		-a|--armbian)
			[[ $# -ge 2 ]] || die "--armbian needs an argument"
			ARMBIAN_DIR="$2"; shift 2 ;;
		-b|--branch)
			[[ $# -ge 2 ]] || die "--branch needs an argument"
			BRANCH="$2"; shift 2 ;;
		-k|--kernel-version)
			[[ $# -ge 2 ]] || die "--kernel-version needs an argument"
			KERNEL_VERSION="$2"; shift 2 ;;
		--) shift; break ;;
		*)  die "unknown argument '$1' (try --help)" ;;
	esac
done

[[ "${BRANCH}" =~ ^[A-Za-z0-9_-]+$ ]] || die "invalid --branch '${BRANCH}'"
[[ "${KERNEL_VERSION}" =~ ^[0-9]+\.[0-9]+$ ]] || die "invalid --kernel-version '${KERNEL_VERSION}' (want X.Y)"

# ------------------------------------------------------------------------------
# Preconditions - refuse to do anything half-right
# ------------------------------------------------------------------------------
need_tool() {
	command -v "$1" > /dev/null 2>&1 || die "required tool '$1' not found in PATH${2:+ - $2}"
}
need_tool rsync "install it with: sudo apt-get install rsync"
need_tool awk
need_tool mktemp
need_tool cmp

[[ -d "${BOARD_DIR}" ]] || die "no board/ directory at '${BOARD_DIR}'"

# Resolve to an absolute path without requiring realpath(1).
if [[ ! -d "${ARMBIAN_DIR}" ]]; then
	die "armbian submodule is missing or not checked out at '${ARMBIAN_DIR}'.
       Initialise it with:
           git -C '${REPO_ROOT}' submodule update --init --depth 1 armbian
       (If it has never been added, see docs/ARMBIAN-MIGRATION.md Phase 2.)"
fi
ARMBIAN_DIR="$(cd -- "${ARMBIAN_DIR}" && pwd)"

# An empty directory is what an uninitialised submodule looks like; a directory
# without these markers is not an armbian/build checkout at all. Either way,
# writing into it would create a convincing-looking but broken tree.
for marker in compile.sh lib/functions config/boards config/kernel patch/kernel/archive; do
	[[ -e "${ARMBIAN_DIR}/${marker}" ]] || die "'${ARMBIAN_DIR}' does not look like an armbian/build checkout (missing '${marker}').
       If this is an uninitialised submodule, run:
           git -C '${REPO_ROOT}' submodule update --init --depth 1 armbian"
done

# One-way guarantee, mechanically: every destination must live under
# ARMBIAN_DIR, and ARMBIAN_DIR must not contain the source tree.
case "${BOARD_DIR}/" in
	"${ARMBIAN_DIR}/"*) die "refusing to run: board/ ('${BOARD_DIR}') is inside the armbian tree ('${ARMBIAN_DIR}'). That would make the sync circular." ;;
esac

debug "REPO_ROOT      = ${REPO_ROOT}"
debug "BOARD_DIR      = ${BOARD_DIR}"
debug "ARMBIAN_DIR    = ${ARMBIAN_DIR}"
debug "BRANCH         = ${BRANCH}"
debug "KERNEL_VERSION = ${KERNEL_VERSION}"

# Report the submodule pin, if git is available. Purely informational.
if command -v git > /dev/null 2>&1 && [[ -e "${ARMBIAN_DIR}/.git" ]]; then
	ARMBIAN_SHA="$(git -C "${ARMBIAN_DIR}" rev-parse --short=12 HEAD 2> /dev/null || echo "unknown")"
	ARMBIAN_DIRTY=""
	git -C "${ARMBIAN_DIR}" diff --quiet --ignore-submodules 2> /dev/null || ARMBIAN_DIRTY=" (working tree modified - expected, this script writes into it)"
else
	ARMBIAN_SHA="unknown"
	ARMBIAN_DIRTY=""
fi

LINUXCONFIG="linux-${LINUXFAMILY}-${BRANCH}"
BASE_CONFIG="${ARMBIAN_DIR}/config/kernel/${LINUXCONFIG}.config"
DELTA_CONFIG="${BOARD_DIR}/linux-${LINUXFAMILY}-omni.config"
DT_DIR="${ARMBIAN_DIR}/patch/kernel/archive/${LINUXFAMILY}-${KERNEL_VERSION}/dt"

[[ -f "${BASE_CONFIG}" ]] || die "upstream base kernel config not found: '${BASE_CONFIG}'.
       Either BRANCH='${BRANCH}' is wrong for family '${LINUXFAMILY}', or the pinned
       armbian/ commit no longer ships that config. Do not guess - check
       ${ARMBIAN_DIR}/config/kernel/ and update --branch deliberately."

[[ -d "$(dirname "${DT_DIR}")" ]] || die "kernel patch archive '${LINUXFAMILY}-${KERNEL_VERSION}' does not exist in the pinned armbian/ commit.
       Looked for: $(dirname "${DT_DIR}")
       The kernel pin (${KERNEL_VERSION}) and the armbian/ submodule have diverged.
       Roll the submodule back, or move the pin in board/post_family_config__${BOARD}.sh
       and re-run the Phase 4 gate."

printf '\n%s\n' "sync-armbian-board: ${BOARD} -> ${ARMBIAN_DIR}"
info "armbian @ ${ARMBIAN_SHA}${ARMBIAN_DIRTY}"
info "branch=${BRANCH}  kernel=${KERNEL_VERSION}  config=${LINUXCONFIG}.config"
[[ "${DRY_RUN}" == "yes" ]] && info "${C_YEL}DRY RUN - nothing will be written${C_OFF}"
printf '\n'

CHANGED=0
SKIPPED=0

# ------------------------------------------------------------------------------
# install_one <src> <dst> <mode> <label>
#   Copies exactly one file, one way, content-idempotently.
# ------------------------------------------------------------------------------
install_one() {
	local src="$1" dst="$2" mode="$3" label="$4"
	local dstdir rsync_out
	local -a rsync_args

	# Hard guard: never write outside the armbian tree.
	case "${dst}" in
		"${ARMBIAN_DIR}/"*) : ;;
		*) die "internal: destination '${dst}' is outside '${ARMBIAN_DIR}' - refusing" ;;
	esac
	# Hard guard: never write into the source tree.
	case "${dst}" in
		"${BOARD_DIR}/"*|"${SCRIPT_DIR}/"*) die "internal: destination '${dst}' is inside the source tree - refusing (this script is one-way)" ;;
	esac

	[[ -f "${src}" ]] || die "internal: missing source '${src}'"

	dstdir="$(dirname "${dst}")"

	# --checksum: decide by content, not size+mtime, so re-running is a true
	#   no-op even for the kernel config, which is regenerated into a fresh
	#   temp file (and therefore always has a "new" mtime) on every run.
	# NO --times, deliberately: preserving the temp file's mtime would make
	#   rsync report a change (".f..t......") on every single run and would
	#   needlessly re-stamp files the kernel build hashes.
	# --perms/--chmod: force a predictable mode; the source tree's modes and
	#   any umask are irrelevant to what Armbian reads.
	rsync_args=(--checksum --itemize-changes "--chmod=F${mode}" --perms)
	[[ "${DRY_RUN}" == "yes" ]] && rsync_args+=(--dry-run)

	if [[ ! -d "${dstdir}" ]]; then
		if [[ "${DRY_RUN}" == "yes" ]]; then
			info "would mkdir -p ${dstdir#"${ARMBIAN_DIR}"/}"
		else
			mkdir -p -- "${dstdir}"
		fi
	fi

	if [[ "${DRY_RUN}" == "yes" && ! -d "${dstdir}" ]]; then
		# rsync cannot itemise into a directory that does not exist yet.
		printf '%s\n' "${C_YEL}  new${C_OFF}  ${label}"
		info "       -> ${dst#"${ARMBIAN_DIR}"/}"
		CHANGED=$((CHANGED + 1))
		return 0
	fi

	rsync_out="$(rsync "${rsync_args[@]}" -- "${src}" "${dst}")"

	if [[ -n "${rsync_out}" ]]; then
		printf '%s\n' "${C_YEL}  sync${C_OFF} ${label}"
		info "       -> ${dst#"${ARMBIAN_DIR}"/}"
		debug "rsync: ${rsync_out}"
		CHANGED=$((CHANGED + 1))
	else
		ok "${label} ${C_DIM}(unchanged)${C_OFF}"
		SKIPPED=$((SKIPPED + 1))
	fi
}

# ------------------------------------------------------------------------------
# normalize_delta <delta>  -> stdout: one canonical .config line per option
#
#   The delta is written for humans, so it has to be canonicalised before kconfig
#   ever sees it:
#     * "CONFIG_X=v   # why"        -> "CONFIG_X=v"     (quote-aware cut)
#     * "# CONFIG_X is not set # w" -> "# CONFIG_X is not set"
#     * blank lines and prose comments are dropped
#     * a repeated symbol keeps its LAST value, in its first position
#   Trailing comments are NOT valid kernel .config syntax; skipping this step
#   would silently give CONFIG_PANIC_TIMEOUT the value "15   # ...".
#
#   Caveat, documented in the delta file's own header: a prose comment shaped
#   exactly like "# CONFIG_FOO is not set" IS a directive here, wherever it
#   appears.
# ------------------------------------------------------------------------------
normalize_delta() {
	awk '
		function normalize(line,   s, eq, key, val, i, c, inq, out) {
			sub(/\r$/, "", line)
			if (line ~ /^[ \t]*#[ \t]*CONFIG_[A-Za-z0-9_]+[ \t]+is[ \t]+not[ \t]+set/) {
				s = line
				sub(/^[ \t]*#[ \t]*CONFIG_/, "", s)
				sub(/[ \t]+is[ \t]+not[ \t]+set.*$/, "", s)
				return "# CONFIG_" s " is not set"
			}
			if (line !~ /^CONFIG_[A-Za-z0-9_]+=/) return ""
			eq  = index(line, "=")
			key = substr(line, 1, eq)
			val = substr(line, eq + 1)
			inq = 0; out = ""
			for (i = 1; i <= length(val); i++) {
				c = substr(val, i, 1)
				if (c == "\"") { inq = !inq; out = out c; continue }
				if (!inq && c == "#") break
				out = out c
			}
			sub(/[ \t]+$/, "", out)
			if (out == "") return ""
			return key out
		}
		function symof(line,   s) {
			if (line ~ /^# CONFIG_[A-Za-z0-9_]+ is not set$/) {
				s = line; sub(/^# CONFIG_/, "", s); sub(/ is not set$/, "", s); return s
			}
			if (line ~ /^CONFIG_[A-Za-z0-9_]+=/) {
				s = line; sub(/^CONFIG_/, "", s); sub(/=.*$/, "", s); return s
			}
			return ""
		}
		{
			line = normalize($0)
			if (line == "") next
			sym = symof(line)
			if (sym == "") next
			if (!(sym in seen)) { seen[sym] = 1; order[++n] = sym }
			value[sym] = line
		}
		END { for (i = 1; i <= n; i++) print value[order[i]] }
	' "$1"
}

# ------------------------------------------------------------------------------
# merge_kconfig <base> <normalized-delta> <out>
#   Produces a complete kernel defconfig: base minus every symbol the delta
#   mentions, plus the delta's canonical lines appended (later wins in kconfig,
#   but the symbols are removed from the base region anyway so the result has
#   exactly one line per symbol).
# ------------------------------------------------------------------------------
merge_kconfig() {
	local base="$1" ndelta="$2" out="$3"

	{
		printf '# GENERATED by tools/sync-armbian-board.sh - DO NOT EDIT THIS FILE.\n'
		printf '# Source of truth: board/linux-%s-omni.config (the delta) merged onto\n' "${LINUXFAMILY}"
		printf '#                  armbian/config/kernel/%s.config (upstream base).\n' "${LINUXCONFIG}"
		printf '# armbian pin: %s   board: %s   branch: %s   kernel: %s\n' \
			"${ARMBIAN_SHA}" "${BOARD}" "${BRANCH}" "${KERNEL_VERSION}"
		printf '# Regenerate with: tools/sync-armbian-board.sh\n'
		printf '#\n'
		printf '# NOTE: `./compile.sh ... KERNEL_CONFIGURE=yes` rewrites this file in place\n'
		printf '#       (kernel-config.sh:166). Re-running the sync restores it; port any\n'
		printf '#       change you want to keep back into board/linux-%s-omni.config.\n' "${LINUXFAMILY}"

		awk -v NDELTA="${ndelta}" '
			function symof(line,   s) {
				if (line ~ /^# CONFIG_[A-Za-z0-9_]+ is not set$/) {
					s = line; sub(/^# CONFIG_/, "", s); sub(/ is not set$/, "", s); return s
				}
				if (line ~ /^CONFIG_[A-Za-z0-9_]+=/) {
					s = line; sub(/^CONFIG_/, "", s); sub(/=.*$/, "", s); return s
				}
				return ""
			}
			BEGIN {
				n = 0
				while ((getline line < NDELTA) > 0) {
					sym = symof(line)
					if (sym == "") continue
					seen[sym] = 1
					order[++n] = line
				}
				close(NDELTA)
				if (n == 0) {
					print "sync-armbian-board: delta produced 0 usable options" > "/dev/stderr"
					exit 3
				}
			}
			{
				sym = symof($0)
				if (sym != "" && (sym in seen)) next   # superseded by the delta
				print
			}
			END {
				print ""
				print "# --- avast-omni delta (" n " options) ---------------------------------"
				for (i = 1; i <= n; i++) print order[i]
			}
		' "${base}"
	} > "${out}"
}

# ------------------------------------------------------------------------------
# 1. Board config
# ------------------------------------------------------------------------------
BOARD_SRC="${BOARD_DIR}/${BOARD}.csc"
[[ -f "${BOARD_SRC}" ]] || die "missing '${BOARD_SRC}'"
install_one "${BOARD_SRC}" "${ARMBIAN_DIR}/config/boards/${BOARD}.csc" 644 "board config    ${BOARD}.csc"

# Armbian sources BOTH config/boards/<b>.<type> and userpatches/config/boards/<b>.<type>
# additively (config-prepare.sh:100-113). Two copies means the file is sourced
# twice, which double-registers hooks. Catch it.
STRAY="${ARMBIAN_DIR}/userpatches/config/boards/${BOARD}.csc"
if [[ -e "${STRAY}" ]]; then
	warn "a second copy of the board config exists at userpatches/config/boards/${BOARD}.csc - Armbian will source BOTH. Delete it."
fi

# ------------------------------------------------------------------------------
# 2. Device tree source (optional until Phase 3)
# ------------------------------------------------------------------------------
DTS_SRC="${BOARD_DIR}/${DTS_NAME}"
if [[ -f "${DTS_SRC}" ]]; then
	install_one "${DTS_SRC}" "${DT_DIR}/${DTS_NAME}" 644 "device tree     ${DTS_NAME}"
else
	warn "board/${DTS_NAME} does not exist yet - skipping (expected before Phase 3).
       Until it lands, 'compile.sh kernel' works but 'compile.sh dts-check' and
       BOOT_FDT_FILE=amlogic/${DTS_NAME%.dts}.dtb do not."
fi

# ------------------------------------------------------------------------------
# 3. Kernel config: merge delta onto the pinned base, then install
# ------------------------------------------------------------------------------
[[ -f "${DELTA_CONFIG}" ]] || die "missing kernel config delta '${DELTA_CONFIG}'"

TMPDIR_SYNC="$(mktemp -d)"
cleanup() { rm -rf -- "${TMPDIR_SYNC}"; }
trap cleanup EXIT INT TERM

NDELTA="${TMPDIR_SYNC}/delta.normalized"
normalize_delta "${DELTA_CONFIG}" > "${NDELTA}"
DELTA_COUNT="$(grep -c . -- "${NDELTA}" || true)"
[[ "${DELTA_COUNT}" -gt 0 ]] || die "'${DELTA_CONFIG}' yielded 0 usable kernel options - is it really the config delta?"
debug "normalised delta: ${DELTA_COUNT} option(s)"

MERGED="${TMPDIR_SYNC}/${LINUXCONFIG}.config"
merge_kconfig "${BASE_CONFIG}" "${NDELTA}" "${MERGED}"

# Sanity: the merge must not have eaten the config.
BASE_LINES="$(grep -c '^CONFIG_\|^# CONFIG_' "${BASE_CONFIG}" || true)"
MERGED_LINES="$(grep -c '^CONFIG_\|^# CONFIG_' "${MERGED}" || true)"
if [[ "${MERGED_LINES}" -lt "${BASE_LINES}" ]]; then
	die "internal: merged config has ${MERGED_LINES} options, base had ${BASE_LINES}. Refusing to install a truncated kernel config."
fi
debug "merged config: ${MERGED_LINES} options (base ${BASE_LINES})"

# Assert every delta option made it through verbatim, and exactly once.
MISSING=""
DUPED=""
while IFS= read -r want; do
	[[ -n "${want}" ]] || continue
	case "$(grep -cxF -- "${want}" "${MERGED}" || true)" in
		0) MISSING="${MISSING}
       ${want}" ;;
		1) : ;;
		*) DUPED="${DUPED}
       ${want}" ;;
	esac
done < "${NDELTA}"
[[ -z "${MISSING}" ]] || die "merge lost these delta options:${MISSING}"
[[ -z "${DUPED}" ]] || die "merge duplicated these delta options:${DUPED}"

DST_CONFIG="${ARMBIAN_DIR}/userpatches/config/kernel/${LINUXCONFIG}.config"
if [[ "${DRY_RUN}" == "yes" ]] && [[ -f "${DST_CONFIG}" ]] && [[ "${VERBOSE}" == "yes" ]]; then
	diff -u -- "${DST_CONFIG}" "${MERGED}" || true
fi
install_one "${MERGED}" "${DST_CONFIG}" 644 "kernel config   ${LINUXCONFIG}.config (base + ${DELTA_COUNT} delta options)"

# ------------------------------------------------------------------------------
# 4. post_family_config extension
# ------------------------------------------------------------------------------
HOOK_NAME="post_family_config__${BOARD}.sh"
HOOK_SRC="${BOARD_DIR}/${HOOK_NAME}"
[[ -f "${HOOK_SRC}" ]] || die "missing '${HOOK_SRC}' - config/boards/${BOARD}.csc calls enable_extension for it, so the build would exit 17 without it"
install_one "${HOOK_SRC}" "${ARMBIAN_DIR}/userpatches/extensions/${HOOK_NAME}" 644 "hook            ${HOOK_NAME}"

# ------------------------------------------------------------------------------
# Consistency check: the pin in the hook must match --kernel-version
# ------------------------------------------------------------------------------
PINNED_IN_HOOK="$(awk -F'"' '/^declare -g AVAST_OMNI_PINNED_KERNEL=/{print $2; exit}' "${HOOK_SRC}")"
if [[ -n "${PINNED_IN_HOOK}" && "${PINNED_IN_HOOK}" != "${KERNEL_VERSION}" ]]; then
	warn "kernel pin mismatch: the hook pins ${PINNED_IN_HOOK} but this sync targeted ${KERNEL_VERSION}.
       The DTS was placed in ${LINUXFAMILY}-${KERNEL_VERSION}/dt/ but the build will use ${LINUXFAMILY}-${PINNED_IN_HOOK}."
fi
PINNED_BRANCH_IN_HOOK="$(awk -F'"' '/^declare -g AVAST_OMNI_PINNED_BRANCH=/{print $2; exit}' "${HOOK_SRC}")"
if [[ -n "${PINNED_BRANCH_IN_HOOK}" && "${PINNED_BRANCH_IN_HOOK}" != "${BRANCH}" ]]; then
	warn "branch mismatch: the hook pins BRANCH='${PINNED_BRANCH_IN_HOOK}' but this sync wrote the kernel config for '${BRANCH}'.
       A build with BRANCH=${BRANCH} will NOT have its kernel version pinned."
fi

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
printf '\n'
if [[ "${DRY_RUN}" == "yes" ]]; then
	info "dry run: ${CHANGED} file(s) would change, ${SKIPPED} already current"
else
	info "${CHANGED} file(s) written, ${SKIPPED} already current"
	printf '\n'
	info "next:  cd '${ARMBIAN_DIR}' && ./compile.sh kernel BOARD=${BOARD} BRANCH=${BRANCH}"
fi
printf '\n'
exit 0

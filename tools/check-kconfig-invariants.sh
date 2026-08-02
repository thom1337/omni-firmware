#!/usr/bin/env bash
#
# check-kconfig-invariants.sh — assert the kernel-config invariants that the
# Avast Omni Armbian migration depends on.
#
# Authority: docs/ARMBIAN-MIGRATION.md, sections "The DTS port" (kernel config
# delta), "Recovery ladder" rank 4, and appendix correction 5.
#
# This script is READ-ONLY. It never writes to the config, the build tree or
# the device. It exits non-zero when an invariant is violated, printing one
# precise line per failure plus a one-line rationale.
#
# Adding an invariant is exactly one line in the INVARIANTS table below.
#
# Dependencies: bash 4+, coreutils, grep. Optional (probed, never assumed):
# gzip (for *.gz / /proc/config.gz), tar + dpkg-deb (for *.deb).
#
set -euo pipefail

PROG=${0##*/}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(dirname -- "$SCRIPT_DIR")

SELF_TMP=""
cleanup() {
	if [ -n "$SELF_TMP" ] && [ -d "$SELF_TMP" ]; then
		rm -rf -- "$SELF_TMP"
	fi
	return 0
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# The invariant table.
#
#   KEY|RULE|SEVERITY|WHY
#
# RULE:
#   y        must be =y.  STRICT built-in: =m is a FAILURE.
#   ym       must be =y or =m ("present" is enough).
#   m        must be =m.
#   n        must be disabled: absent, or "# CONFIG_X is not set".
#   val:V    must be exactly =V (ints and strings; quotes are stripped).
#
# SEVERITY:
#   fail     violating it is a known-fatal regression -> exit non-zero.
#   warn     violating it is a degradation, not a brick -> reported, exit 0
#            (promote every warn to a failure with --strict).
# ---------------------------------------------------------------------------
INVARIANTS=$(
	cat <<'EOF'
# --- Networking: the RTL8211F RGMII PHY (plan risk 3) ----------------------
CONFIG_REALTEK_PHY|y|fail|STRICT =y: absent from Armbian's meson64 config (it enables ICPLUS_PHY for JetHub). As =m the MAC probes before the module loads, phylib binds genphy and you get "gigabit that mostly works" with the RX/TX delay never programmed.
CONFIG_STMMAC_ETH|ym|fail|dwmac core for &ethmac; without it the single NIC does not exist and the box is unreachable in a closet.
CONFIG_STMMAC_PLATFORM|ym|fail|OF glue for the dwmac core; the meson-axg &ethmac node binds through it.
CONFIG_DWMAC_MESON|ym|fail|Amlogic dwmac glue; provides the RGMII clock setup the s400-derived &ethmac node needs. NOTE the symbol is DWMAC_MESON even though the driver file is dwmac-meson8b.c -- there is no CONFIG_DWMAC_MESON8B (verified against v6.18 drivers/net/ethernet/stmicro/stmmac/Kconfig:114).
# --- Storage and rootfs ----------------------------------------------------
CONFIG_MMC_MESON_GX|y|fail|STRICT =y: eMMC host controller. Both A/B rootfs slots live on it, so it cannot be a module in a modules-in-rootfs layout.
CONFIG_EXT4_FS|y|fail|STRICT =y: every slot (p1/p2), /data (p3) and both overlay uppers (p5/p6) are ext4 and are mounted before any module is reachable.
CONFIG_OVERLAY_FS|y|fail|STRICT =y: the initramfs local-bottom script mounts the root overlay itself; a module would have to be inside the initrd and MODULES=list will not infer it.
CONFIG_MTD_NAND_MESON|n|fail|Mainline adds nand-controller@7800 whose "emmc" reg region IS sd_emmc_c's window, status defaults to okay. If meson_nand binds, the eMMC controller is stolen and the slot does not mount. Plan pins =n plus MODULES_BLACKLIST="meson_nand" plus &nfc { status = "disabled"; }.
# --- Crash / rollback: bootcount can only fire if the box actually reboots --
CONFIG_PANIC_TIMEOUT|val:15|fail|Mainline defaults this to 0 = hang forever, and Armbian's meson64 config leaves it unset. The Yocto 5.4 defconfig has 15 (defconfig:336). Without it a panicked kernel never reboots, bootcount never increments and A/B rollback provably cannot fire (appendix correction 5).
CONFIG_PANIC_ON_OOPS|y|fail|Live on 5.4 (defconfig:335). An oops that only kills a thread leaves a half-dead box in a closet that no bootlimit will ever recover.
CONFIG_PSTORE|y|fail|STRICT =y: pstore must be up before anything can crash; a module misses early panics entirely.
CONFIG_PSTORE_RAM|y|fail|STRICT =y: ramoops@f400000 is the only post-mortem on a headless unit and the phase 9 soak gate is "no pstore records".
CONFIG_WATCHDOG|y|fail|Watchdog core. RuntimeWatchdogSec=10 is carried forward from the Yocto system.conf.
CONFIG_MESON_GXBB_WATCHDOG|y|fail|STRICT =y: Armbian ships it =m. systemd PID1 opens /dev/watchdog before the rootfs modules are loadable, so =m silently disables the hardware watchdog.
# --- Console and recovery --------------------------------------------------
CONFIG_SERIAL_MESON|y|fail|STRICT =y: ttyAML0 is the console and, with no network, the only in-band recovery path (plan risk 5).
CONFIG_SERIAL_MESON_CONSOLE|y|fail|STRICT =y: without the console glue, console=ttyAML0 is silently ignored and a failing boot prints nothing.
CONFIG_KEYBOARD_GPIO|y|fail|STRICT =y: reset button GPIOAO_10 -> KEY_RESTART. =y in stock Armbian; the plan's gpio-keys node depends on it.
# --- LEDs: the initramfs writes these sysfs paths before switch_root -------
CONFIG_LEDS_PWM|y|fail|STRICT =y: the ported initramfs writes apollo:power / apollo:app1 / apollo:app2 before the rootfs is up.
CONFIG_NEW_LEDS|y|fail|LED class core; leds-pwm is useless without it.
CONFIG_LEDS_CLASS|y|fail|LED class core; provides the /sys/class/leds/* paths the initramfs writes.
CONFIG_PWM_MESON|y|fail|STRICT =y: provides &pwm_cd for leds-pwm. On 6.12 this is the amlogic,meson-axg-ee-pwm binding, on 6.18 the pwm-v2 rewrite.
# --- Firewall / VPN: the whole point of the migration ----------------------
CONFIG_NF_TABLES|ym|fail|Absent from the 5.4 vendor config. nftables is the single packet engine the migration standardises on, replacing iptables-legacy + ipset.
CONFIG_NFT_COMPAT|ym|fail|Plan pins =m. trixie's iptables is the nft backend, so any rule still written in iptables syntax needs xt_* matches expressible through nftables.
CONFIG_WIREGUARD|ym|fail|Absent from the 5.4 vendor config; one of the named gaps the migration closes.
CONFIG_NETFILTER_XT_MATCH_CONNTRACK|ym|fail|Any stateful firewall rule needs it.
CONFIG_NF_CONNTRACK|ym|fail|Required by NAT and by the nf_conntrack_tcp_be_liberal sysctl that replaces patch 0010.
CONFIG_NF_NAT|ym|fail|Router NAT.
CONFIG_IPV6_MULTIPLE_TABLES|y|fail|Patch 0011 must NOT be forward-ported because Armbian's meson64 config already sets it =y; if it is missing here, policy routing silently stops working.
CONFIG_SYN_COOKIES|y|fail|Removed by patch 0009's defconfig trimming. A router facing the internet wants it back.
# --- cgroup v2 (phase 8 gate: stat -fc %T /sys/fs/cgroup = cgroup2fs) -------
CONFIG_CGROUPS|y|fail|systemd >=256 refuses to boot without cgroup v2; the Yocto system used a cgroup v1 tmpfs fstab hack.
CONFIG_MEMCG|y|fail|cgroup2 memory accounting. On a 512 MB box, per-unit memory limits are how one leaking service is stopped from taking PID 1 down with it.
CONFIG_BRIDGE|ym|warn|Bridging in its own right -- commit 6035455 added the bridge modules to the 5.4 defconfig deliberately. Present in Armbian's stock meson64 config too.
CONFIG_VETH|ym|warn|veth pairs. Was here for container networking; the image now ships no container runtime, so this is retained only because Armbian provides it free and removing it would cost a rebuild if that changes.
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE|ym|warn|addrtype matches (local/broadcast/multicast). Was a Docker requirement; kept because it is free in Armbian's config and generally useful in a router ruleset.
# --- Router QoS: patch 0009 removed these; the plan says do not re-apply it -
CONFIG_NET_SCH_HTB|ym|warn|Removed by patch 0009. Armbian's config has it; a router wants shaping back.
CONFIG_NET_SCH_TBF|ym|warn|Removed by patch 0009 (the 5.4 defconfig kept =y). Armbian's config has it.
CONFIG_NET_SCH_FQ_CODEL|ym|warn|Removed by patch 0009. Default qdisc on modern kernels; without it bufferbloat comes back.
CONFIG_NET_SCH_INGRESS|ym|warn|Removed by patch 0009. Needed for ingress shaping via IFB.
CONFIG_NET_CLS_U32|ym|warn|Removed by patch 0009. Classifier used by every ingress/egress shaping recipe.
CONFIG_NET_CLS_ACT|y|warn|Removed by patch 0009. Bool: enables tc actions (mirred/redirect to IFB).
CONFIG_IFB|ym|warn|Removed by patch 0009. Intermediate functional block, the standard way to shape ingress.
CONFIG_NETFILTER_XT_TARGET_TCPMSS|ym|warn|Removed by patch 0009. MSS clamping is mandatory on any PPPoE/VPN uplink.
# --- Build hygiene ---------------------------------------------------------
CONFIG_DEBUG_INFO|n|fail|The 5.4 tree has it on (defconfig:334). It inflates vmlinux and every module by an order of magnitude; the slot budget already pays ~40 MB for the flattened /boot copies.
CONFIG_MODULES|y|fail|The rootfs ships /lib/modules from the linux-image deb and the plan relies on MODULES_BLACKLIST.
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

p_pass() { PASS=$((PASS + 1)); say "${C_G}PASS${C_0}  $1"; }
p_skip() { SKIPPED=$((SKIPPED + 1)); say "${C_Y}SKIP${C_0}  $1"; }

p_fail() { # $1 = headline, $2 = why
	FAILED=$((FAILED + 1))
	printf '%sFAIL%s  %s\n' "$C_R" "$C_0" "$1"
	if [ -n "${2-}" ]; then printf '      why: %s\n' "$2"; fi
}

p_warn() { # $1 = headline, $2 = why
	WARNED=$((WARNED + 1))
	printf '%sWARN%s  %s\n' "$C_Y" "$C_0" "$1"
	if [ -n "${2-}" ]; then printf '      why: %s\n' "$2"; fi
}

usage() {
	cat <<EOF
Usage: $PROG [OPTIONS] [KCONFIG]

Assert the kernel-config invariants required by the Avast Omni Armbian
migration (docs/ARMBIAN-MIGRATION.md). Read-only; nothing is ever modified.

KCONFIG may be:
  * a kernel .config file (plain or gzip-compressed, e.g. /proc/config.gz)
  * a linux-image .deb   (needs dpkg-deb + tar; /boot/config-* is read out)
  * a directory          (searched for .config, boot/config-*, config-*)
  * omitted              -> auto-discovery, see below

Auto-discovery order (first hit wins):
  \$OMNI_KCONFIG
  ./.config
  $REPO_ROOT/armbian/.tmp/*/.config
  $REPO_ROOT/armbian/cache/sources/linux-kernel-worktree/*/.config
  $REPO_ROOT/armbian/output/config/*.config
  $REPO_ROOT/armbian/output/debs/linux-image-*.deb   (newest)
  $REPO_ROOT/armbian/userpatches/config/kernel/linux-meson64-*.config
  /boot/config-*  (newest)
  /proc/config.gz

Options:
  -h, --help          this text
      --list          print the invariant table and exit
      --strict        treat WARN invariants as failures
      --skip KEY      do not check CONFIG_KEY (repeatable; KEY may omit the
                      CONFIG_ prefix). Escape hatch for a deliberate waiver.
  -q, --quiet         print only failures/warnings and the summary
      --no-color      never colourise
      --color         always colourise

Severity:
  fail  a known-fatal regression: unbootable slot, unreachable box, or a
        rollback path that cannot fire. Causes exit 1.
  warn  a degradation (router QoS, container niceties). Exit 0 unless --strict.

Exit: 0 all invariants hold, 1 at least one failure, 2 usage/setup error.

Examples:
  $PROG                                   # auto-discover
  $PROG armbian/output/debs/linux-image-current-meson64_*.deb
  $PROG --strict /boot/config-6.12.0-meson64
  ssh root@omni "cat /proc/config.gz" | ... # (fetch first, then pass a file)
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
SKIP_KEYS=""
KCONFIG_ARG=""
DO_LIST=0

while [ $# -gt 0 ]; do
	case "$1" in
	-h | --help)
		usage
		exit 0
		;;
	--list) DO_LIST=1 ;;
	--strict) STRICT=1 ;;
	-q | --quiet) QUIET=1 ;;
	--no-color) USE_COLOR=no ;;
	--color) USE_COLOR=yes ;;
	--skip)
		[ $# -ge 2 ] || die "--skip needs an argument"
		shift
		case "$1" in CONFIG_*) SKIP_KEYS="$SKIP_KEYS $1" ;; *) SKIP_KEYS="$SKIP_KEYS CONFIG_$1" ;; esac
		;;
	--skip=*)
		_k=${1#--skip=}
		[ -n "$_k" ] || die "--skip= needs a value"
		case "$_k" in CONFIG_*) SKIP_KEYS="$SKIP_KEYS $_k" ;; *) SKIP_KEYS="$SKIP_KEYS CONFIG_$_k" ;; esac
		;;
	--config)
		[ $# -ge 2 ] || die "--config needs an argument"
		shift
		KCONFIG_ARG=$1
		;;
	--config=*) KCONFIG_ARG=${1#--config=} ;;
	--)
		shift
		[ $# -eq 0 ] || KCONFIG_ARG=$1
		break
		;;
	-*) die "unknown option '$1' (try --help)" ;;
	*)
		[ -z "$KCONFIG_ARG" ] || die "more than one config path given ('$KCONFIG_ARG' and '$1')"
		KCONFIG_ARG=$1
		;;
	esac
	shift
done

setup_color

rule_desc() {
	case "$1" in
	y) printf '=y (STRICT built-in; =m rejected)' ;;
	ym) printf '=y or =m' ;;
	m) printf '=m' ;;
	n) printf 'disabled (absent or "is not set")' ;;
	val:*) printf '=%s (exact)' "${1#val:}" ;;
	*) printf 'UNKNOWN-RULE(%s)' "$1" ;;
	esac
}

if [ "$DO_LIST" -eq 1 ]; then
	printf '%-42s %-34s %s\n' "SYMBOL" "REQUIRED" "SEVERITY"
	while IFS='|' read -r key rule sev why; do
		case "${key-}" in '' | '#'*) continue ;; esac
		printf '%-42s %-34s %s\n' "$key" "$(rule_desc "$rule")" "$sev"
	done <<<"$INVARIANTS"
	exit 0
fi

# ---------------------------------------------------------------------------
# Locating the config
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

newest_of() { # prints the newest existing path among the arguments, if any
	local best="" p
	for p in "$@"; do
		[ -e "$p" ] || continue
		if [ -z "$best" ] || [ "$p" -nt "$best" ]; then best=$p; fi
	done
	[ -n "$best" ] && printf '%s\n' "$best"
	return 0
}

discover_config() {
	local c
	if [ -n "${OMNI_KCONFIG-}" ]; then
		printf '%s\n' "$OMNI_KCONFIG"
		return 0
	fi
	if [ -f ./.config ]; then
		printf '%s\n' "./.config"
		return 0
	fi

	local -a globs=(
		"$REPO_ROOT"/armbian/.tmp/*/.config
		"$REPO_ROOT"/armbian/cache/sources/linux-kernel-worktree/*/.config
		"$REPO_ROOT"/armbian/output/config/*.config
		"$REPO_ROOT"/armbian/output/debs/linux-image-*.deb
		"$REPO_ROOT"/armbian/userpatches/config/kernel/linux-meson64-*.config
		/boot/config-*
	)
	c=$(newest_of "${globs[@]}")
	if [ -n "$c" ]; then
		printf '%s\n' "$c"
		return 0
	fi
	if [ -r /proc/config.gz ]; then
		printf '%s\n' /proc/config.gz
		return 0
	fi
	return 1
}

resolve_dir() { # a directory was given: find a config inside it
	local d=$1 c
	c=$(newest_of "$d/.config" "$d"/boot/config-* "$d"/config-* "$d"/*.config)
	[ -n "$c" ] || die "no kernel config found under '$d' (looked for .config, boot/config-*, config-*, *.config)"
	printf '%s\n' "$c"
}

extract_deb_config() { # $1 = .deb -> prints a path to the extracted config
	local deb=$1 member
	have dpkg-deb || die "'$deb' is a .deb but dpkg-deb is not installed"
	have tar || die "'$deb' is a .deb but tar is not installed"
	SELF_TMP=${SELF_TMP:-$(mktemp -d "${TMPDIR:-/tmp}/omni-kconfig.XXXXXX")}
	dpkg-deb --fsys-tarfile "$deb" >"$SELF_TMP/fsys.tar" ||
		die "dpkg-deb could not read '$deb'"
	member=$(tar -tf "$SELF_TMP/fsys.tar" | grep -E '(^|/)boot/config-[^/]+$' | head -n 1 || true)
	[ -n "$member" ] || die "'$deb' contains no /boot/config-* (is it really a linux-image package?)"
	tar -xOf "$SELF_TMP/fsys.tar" -- "$member" >"$SELF_TMP/config" ||
		die "could not extract '$member' from '$deb'"
	printf '%s\n' "$SELF_TMP/config"
}

KCONFIG=""
if [ -n "$KCONFIG_ARG" ]; then
	[ -e "$KCONFIG_ARG" ] || die "no such path: '$KCONFIG_ARG'"
	if [ -d "$KCONFIG_ARG" ]; then
		KCONFIG=$(resolve_dir "$KCONFIG_ARG")
	else
		KCONFIG=$KCONFIG_ARG
	fi
else
	KCONFIG=$(discover_config || true)
	[ -n "$KCONFIG" ] || die "no kernel config given and none auto-discovered (try --help)"
	if [ -d "$KCONFIG" ]; then KCONFIG=$(resolve_dir "$KCONFIG"); fi
fi

KCONFIG_DISPLAY=$KCONFIG
case "$KCONFIG" in
*.deb) KCONFIG=$(extract_deb_config "$KCONFIG"); KCONFIG_DISPLAY="$KCONFIG_DISPLAY (/boot/config-* inside)" ;;
esac

[ -r "$KCONFIG" ] || die "config '$KCONFIG' is not readable"

case "$KCONFIG" in
*.gz) have gzip || die "'$KCONFIG' is gzip-compressed but gzip is not installed" ;;
esac

read_config_stream() {
	case "$1" in
	*.gz) gzip -dc -- "$1" ;;
	*) cat -- "$1" ;;
	esac
}

# ---------------------------------------------------------------------------
# Load the config
#
#   CFG[CONFIG_X]="y" | "m" | "15" | "\"str\"" | "__notset__"
#   an absent key is simply not in the array.
# ---------------------------------------------------------------------------
declare -A CFG=()
NOTSET='__notset__'
lines_seen=0
line=""
key=""
val=""

while IFS= read -r line || [ -n "$line" ]; do
	case "$line" in
	CONFIG_*=*)
		key=${line%%=*}
		val=${line#*=}
		# strip a trailing CR from a CRLF file
		val=${val%$'\r'}
		case "$key" in *[!A-Za-z0-9_]*) continue ;; esac
		CFG[$key]=$val
		lines_seen=$((lines_seen + 1))
		;;
	'# CONFIG_'*' is not set')
		key=${line#\# }
		key=${key%% is not set}
		case "$key" in *[!A-Za-z0-9_]*) continue ;; esac
		CFG[$key]=$NOTSET
		lines_seen=$((lines_seen + 1))
		;;
	esac
done < <(read_config_stream "$KCONFIG")

[ "$lines_seen" -gt 0 ] ||
	die "'$KCONFIG' contains no CONFIG_* lines — is it really a kernel config?"

kver=""
if [ -n "${CFG[CONFIG_LOCALVERSION]-}" ]; then kver=${CFG[CONFIG_LOCALVERSION]}; fi
say "${C_B}config:${C_0} $KCONFIG_DISPLAY"
say "${C_B}symbols:${C_0} $lines_seen  ${C_B}localversion:${C_0} ${kver:-<none>}"
say ""

# ---------------------------------------------------------------------------
# Evaluate
# ---------------------------------------------------------------------------
unquote() { # strip one layer of surrounding double quotes
	local v=$1
	case "$v" in
	\"*\") v=${v#\"}; v=${v%\"} ;;
	esac
	printf '%s' "$v"
}

actual_desc() { # $1 = key
	local k=$1
	if [ -z "${CFG[$k]+x}" ]; then
		printf 'absent from the config'
	elif [ "${CFG[$k]}" = "$NOTSET" ]; then
		printf 'explicitly disabled (# %s is not set)' "$k"
	else
		printf '=%s' "${CFG[$k]}"
	fi
}

is_skipped() {
	case " $SKIP_KEYS " in *" $1 "*) return 0 ;; esac
	return 1
}

report_bad() { # $1 = headline, $2 = why, $3 = severity
	if [ "$3" = warn ] && [ "$STRICT" -eq 0 ]; then
		p_warn "$1" "$2"
	else
		p_fail "$1" "$2"
	fi
}

while IFS='|' read -r key rule sev why; do
	case "${key-}" in '' | '#'*) continue ;; esac
	rule=${rule:-y}
	sev=${sev:-fail}

	if is_skipped "$key"; then
		p_skip "$key  (waived with --skip)"
		continue
	fi

	val=""
	present=0
	if [ -n "${CFG[$key]+x}" ]; then
		present=1
		val=${CFG[$key]}
	fi

	head="$key  required: $(rule_desc "$rule")  actual: $(actual_desc "$key")"

	case "$rule" in
	y)
		if [ "$present" -eq 1 ] && [ "$val" = y ]; then
			p_pass "$key=y"
		else
			report_bad "$head" "$why" "$sev"
		fi
		;;
	ym)
		if [ "$present" -eq 1 ] && { [ "$val" = y ] || [ "$val" = m ]; }; then
			p_pass "$key=$val"
		else
			report_bad "$head" "$why" "$sev"
		fi
		;;
	m)
		if [ "$present" -eq 1 ] && [ "$val" = m ]; then
			p_pass "$key=m"
		else
			report_bad "$head" "$why" "$sev"
		fi
		;;
	n)
		if [ "$present" -eq 0 ] || [ "$val" = "$NOTSET" ] || [ "$val" = n ]; then
			p_pass "$key disabled"
		else
			report_bad "$head" "$why" "$sev"
		fi
		;;
	val:*)
		want=${rule#val:}
		got=$(unquote "$val")
		if [ "$present" -eq 1 ] && [ "$val" != "$NOTSET" ] && [ "$got" = "$want" ]; then
			p_pass "$key=$got"
		else
			report_bad "$head" "$why" "$sev"
		fi
		;;
	*)
		p_fail "$key  BAD TABLE ENTRY: unknown rule '$rule'" \
			"fix the INVARIANTS table in $PROG"
		;;
	esac
done <<<"$INVARIANTS"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
say ""
if [ "$SKIPPED" -gt 0 ]; then printf 'skipped: %d (waived with --skip)\n' "$SKIPPED"; fi
if [ "$WARNED" -gt 0 ]; then printf 'warnings: %d (not fatal; re-run with --strict to enforce)\n' "$WARNED"; fi
printf '%d passed, %d failed\n' "$PASS" "$FAILED"

if [ "$FAILED" -gt 0 ]; then
	printf '%sFAILED%s: %s violates %d kernel-config invariant(s) required by docs/ARMBIAN-MIGRATION.md\n' \
		"$C_R" "$C_0" "$KCONFIG_DISPLAY" "$FAILED"
	exit 1
fi
exit 0

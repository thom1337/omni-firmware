# Armbian Migration Plan: Avast Omni


## The shape of the migration

This is tractable because none of the hard parts are actually hard. Mainline Linux has supported Amlogic meson-axg since v4.17 (`meson-axg.dtsi`, `meson-axg-s400.dts`), and [JetHub D1](https://github.com/armbian/build/blob/main/config/boards/jethubj100.conf) is the same SoC family, same 512 MB, same eMMC class, same headless single-Ethernet form factor — with an in-tree DTS (`meson-axg-jethome-jethub-j1xx.dtsi`) you can lift from. Armbian already has `BOARDFAMILY="meson-axg"` and a worked example at [`config/boards/gateway-gz80x.conf`](https://raw.githubusercontent.com/armbian/build/main/config/boards/gateway-gz80x.conf). Most importantly, the Mender boot command loads the kernel, DTB and initramfs from `/boot` **inside the A/B rootfs slot** (`repo/meta-apollo/recipes-bsp/u-boot-apollo/files/0043-apollo-Improve-legibility-of-bootcmd-script.patch`), so a new kernel ships atomically with its rootfs and **the bootloader is never reflashed**.

**Strategy: put a mainline kernel under the *unmodified* Yocto userland first, prove the hardware for a week, then swap the userland to Debian trixie — one variable at a time, with the previous known-good state still installed and bootable at every step.**

---

## Pre-flight: do these before writing anything

Serial console on ttyAML0 (3.3 V USB-TTL, case open) is a **hard prerequisite**, not a convenience.

> **Measured 2026-08-02 — this assumption was wrong, in our favour.** The plan assumed a field unit holds `bootdelay=-2`, making the `=>` prompt unreachable. The unit measured holds **`bootdelay=2`**. `abortboot()` in U-Boot v2018.09 prompts whenever `bootdelay >= 0` (`common/autoboot.c:262`), so the `=>` prompt — rank 1 of the recovery ladder, and the only rung that needs nothing else to be working — **is available today**. Phase 4's "boot entirely from the `=>` prompt" is directly executable, and the whole migration is safer than the plan assumed. Confirm per unit with `fw_printenv bootdelay` before relying on it. Full record: `docs/HARDWARE-MEASURED.md`.

**Order matters: back up before the first env write.** The env is a single non-redundant 8 KB copy (`repo/meta-apollo/recipes-bsp/u-boot-apollo/files/0036-mender-apollo-Do-not-set-CONFIG_ENV_OFFSET_REDUND.patch`, `.../fw_env.config`).

```sh
# 0. Missing tools. The image ships only e2fsprogs-mke2fs
#    (repo/meta-apollo/recipes-core/images/apollo-image.inc:12) — no e2fsck, no dumpe2fs,
#    and none of the Phase 4 gate tools (ethtool, iperf3, fio) either.
#    Build and dpkg -i e2fsprogs-e2fsck, e2fsprogs-dumpe2fs, ethtool, iperf3 and fio
#    from the existing bitbake tree first (the image uses package_deb, apollo-poky.conf:72).
dd --help 2>&1 | grep -q fullblock && dd --help 2>&1 | grep -q fsync   # coreutils is pinned to 6.9
                                                                       # (repo/meta-apollo/conf/distro/apollo-poky.conf:58)

# 1. BACKUP FIRST — before any fw_setenv
ssh root@omni 'sfdisk -d /dev/mmcblk0'              > omni-ptable.sfdisk
ssh root@omni 'fw_printenv | sort'                  > omni-env.txt        # ← only surviving copy of ethaddr
ssh root@omni 'dd if=/dev/mmcblk0boot0 bs=1M'       > omni-boot0.img      # dump ALL of it, not 8 KB
ssh root@omni 'dd if=/dev/mmcblk0boot1 bs=1M'       > omni-boot1.img
ssh root@omni 'dd if=/dev/mmcblk0 bs=4M | gzip -1'  > omni-emmc-full.img.gz
gzip -dc omni-emmc-full.img.gz | md5sum   # must equal `ssh root@omni 'md5sum /dev/mmcblk0'`

# 2. Inventory — closes the two open unknowns
ssh root@omni 'lsblk -b; blockdev --getsize64 /dev/mmcblk0'        # TOTAL eMMC CAPACITY (unknown today)
ssh root@omni 'for p in 1 2 3 5 6 7; do dumpe2fs -h /dev/mmcblk0p$p; done'
ssh root@omni 'cat /sys/kernel/debug/mmc0/ios'                     # baseline: HS200 @ 200 MHz?
ssh root@omni 'cat /sys/kernel/debug/mmc0/mmc0:0001/ext_csd'       # pre_eol_info, life_time_est
ssh root@omni 'cat /proc/cmdline; ls -la /boot; mount'

# 3. Only now: regain the U-Boot prompt
ssh root@omni 'echo 0 > /sys/block/mmcblk0boot0/force_ro; fw_setenv bootdelay 3;
               echo 1 > /sys/block/mmcblk0boot0/force_ro'
```

**Hard checks that gate the project:**

| # | Check | Fail action |
|---|---|---|
| P1 | `fw_printenv force_run_mfc force_run_eol` both `0` | Compiled defaults are `1`; `APOLLO_CHECK_MFC` runs *before* slot selection (`.../0055-apollo-Run-MFC-on-first-boot.patch`) and forces p7. Fix first. |
| P2 | **RESTATED:** `fw_printenv bootargs` contains **no `root=`** (it may legitimately be defined) | `root=` last-occurrence wins; a stale stored `root=` silently boots the selected slot's kernel against the *other* slot's rootfs. **Measured:** a healthy unit has `bootargs=rootwait rw console=ttyAML0` — defined, but with no `root=`, which is patch `0039`'s fixed common cmdline. `MENDER_BOOTARGS` prepends `root=${mender_kernel_root}` each boot, and `/proc/cmdline` confirms the result. The original "must not be defined" wording fails a healthy unit. |
| P3 | `fw_printenv ethaddr` non-empty; MAC stable over 3 reboots | The `check_env` self-heal in `.../0025-configs-apollo-add-env-checking-and-reset.patch` is **dead code** — `0031` replaces `bootcmd` with `CONFIG_MENDER_BOOTCOMMAND`, so `check_env` is never invoked. Lose `ethaddr` and `CONFIG_NET_RANDOM_ETHADDR` gives a new MAC every boot, forever. |
| P4 | `fw_printenv mender_kernel_name mender_dtb_name mender_ramdisk_name` | **Capture verbatim. Never type them from the patches.** Compiled values are `Image` / `meson-axg-apollo.dtb` / `apollo-initramfs-image-meson-apollo.cpio.gz` (`.../0051-apollo-Fix-the-initramfs-name.patch:22`), but a field binary may predate `0050`/`0051`. |
| P5 | `md.w 0xff80023c 1` at `=>` after: cold power-on, `reset`, Linux `reboot`, forced watchdog bite, **cold power cut** | `check_watchdog` (`.../0044-recovery-apollo-Add-support-for-recovery-reset.patch`) reads `0xd000` here and forces `mender_boot_part=7` **ahead of A/B**. If a plain reboot or a power cut latches it, every reboot goes to recovery and the whole risk model changes. `RuntimeWatchdogSec=10` is live today (`repo/meta-apollo/recipes-core/systemd-apollo/files/system.conf:27`, `repo/meta-apollo/recipes-kernel/linux/files/defconfig:237-238`). |
| P6 | Reset-button cold boot reaches a usable shell on p7 | Nothing in this repo builds p7 or `apollo-mfc-initrd-image-*`. If p7 is empty, recovery is serial-only — populate it with a copy of p1 before proceeding. |
| P7 | Env restore drill: corrupt the env, then restore from `omni-boot0.img` via `mmc write` at the `=>` prompt | If you cannot restore the env without a working rootfs, do not arm anything. |
| P8 | `dumpe2fs -h /dev/mmcblk0p2` shows a valid Yocto rootfs | Nothing ever set `upgrade_available=1` — no mender package is installed (`repo/meta-apollo/recipes-core/images/apollo-image.inc`) — so **slot B has never been booted.** It may be zeros. |

**USB routing** (highest-value unknown) is answered free in Phase 5. **eMMC capacity** is answered in step 2.

---

## Phase plan

| # | Goal | Artifact | Evidence that closes it | Days | Rollback |
|---|---|---|---|---|---|
| **0** | Pre-flight above | `docs/HARDWARE.md`, verified backups | 🟡 **PARTIAL 2026-08-02** — `docs/HARDWARE-MEASURED.md` written from a live unit. **P1 pass, P4 captured, P8 answered** (slot B is formatted but empty — never booted, safe to overwrite), **P6 partial** (p7 populated), **P2 restated** (see above), **P3 static half pass**. The env is backed up and CRC-verified. **P5 and P7 still need reboots**; the full-eMMC backup is not achievable over serial (~4 days at 115200) and needs a network cable. | 2.5 | n/a |
| **1** | **First-ever** A/B execution | `tools/omni-{arm,commit,rollback}.sh` | ✅ **DONE 2026-08-02.** Every predicted string appeared. Armed p1 with `--same-slot` (one batched write, read-back asserted); reboot → **`bootcount=1`**, pointer unmoved; second uncommitted reboot → **`Warning: Bootlimit (1) exceeded. Using altbootcmd.`** and `mender_boot_part` flipped 1→2 with `upgrade_available` cleared to 0 by `mender_altbootcmd`. **T9 came free**: slot B is empty, so the flip produced `** File not found /boot/Image **` → **`=>` prompt, not a hang**. Recovered by booting p1 by hand from `=>` and restoring the pointer. `ethaddr` intact throughout. Details in `docs/HARDWARE-MEASURED.md`. | 1.5 | Restore env from `omni-boot0.img` |
| **2** | Armbian kernel factory | `armbian/` submodule pinned to a SHA; `board/` synced in via one-way rsync | ✅ **DONE 2026-08-02.** `./compile.sh kernel BOARD=gateway-gz80x BRANCH=current` produced all four `-meson64` debs (image/headers/dtb/libc-dev) via Armbian's Docker mode. See the branch note below — `BRANCH=oldlts` (6.12) does **not** build. | 1 | n/a |
| **3** | Author the DTS | `meson-axg-apollo.dts`, `avast-omni.csc`, kernel config delta, `docs/dts-port-audit.md` | ✅ **DONE 2026-08-02.** DTS compiles clean (0 attributable dtc warnings) against both v6.12 and v6.18 headers. A full `./compile.sh kernel BOARD=avast-omni BRANCH=current` succeeded: `BOOTCONFIG=none` kept U-Boot untouched, and the `linux-dtb` deb contains `amlogic/meson-axg-apollo.dtb` — the exact `mender_dtb_name`. `tools/check-kconfig-invariants.sh` against the *built* kernel: **44 passed, 0 failed** (same checker reports 15 failures against stock Armbian, so the delta is doing real work). Still open until hardware: the `dtc -I dtb -O dts` old-vs-new diff, which needs the running unit's DTB. | 3 | n/a |
| **4** | **GO/NO-GO: kernel on hardware** | Slot B = byte-clone of slot A + new `Image`/`dtb`/`lib/modules` | 🟡 **MOSTLY PASSED 2026-08-02, one blocker.** Booted `6.18.41` with our DTS entirely from the `=>` prompt against slot A's own userland — nothing persistent written, and a plain reboot returned to 5.4.62. **Passed:** `Machine model: Avast Omni (Apollo)`; eMMC at **HS200, 200 MHz, 8-bit** (exact 5.4 baseline match); all 7 partitions; overlay root assembled; reached a login shell; `/sys/class/leds/` has exactly `apollo:power`/`apollo:app1`/`apollo:app2`; `gpio-keys-polled` registered; no `meson_nand` contention. **Blocked:** the NIC never probed (`DWMAC_MESON=m` + no modules pushed), so **risk #3's RGMII delay comparison is still untested** — config delta now pins it `=y`, needs a rebuild. **Also:** no thermal zones — this unit's SCP firmware is `legacy pre-1.0`, so `scpi_sensors` does not exist. Full detail in `docs/HARDWARE-MEASURED.md`. | 2 | Power cycle (nothing persistent written) |
| **5** | Hardware truth | Final production DTS | USB / gpio-keys / thermal / pstore / PWM answered on throwaway DTBs | 2.5 | Per-experiment |
| **6** | Kernel CI | `.github/workflows/build-omni-kernel.yml` | CI-built `Image` passes the Phase 4 gate unchanged | 1 | n/a |
| **7** | Debian rootfs + initramfs | `omni-slot.ext4.gz` | 🟡 **PARTIAL 2026-08-02.** The builder assembles a complete Debian trixie arm64 rootfs: kernel + DTB installed from the Phase 2 debs, overlay applied, all six customize-hooks green, and `/boot` flattened to real files at the three fixed mender names (`Image` 35 MB, `meson-axg-apollo.dtb` 49 kB, `apollo-initramfs-image-meson-apollo.cpio.gz` 11 MB). All `60-finalise` assertions pass. It still dies in mmdebstrap's own terminal "cleaning package lists" step (apt cannot chown `/var/lib/apt/lists/partial` to `_apt` inside the unshare namespace) — reproduces on host and in a privileged container, survives the `APT::Sandbox::User` workaround. **No `.ext4.gz` yet.** Remaining after that: the qemu-aarch64 loopback boot. | 4 | n/a |
| **8** | **GO/NO-GO: Debian on slot B** | Running Debian trixie | Phase 4 gate re-run on Debian + serial autologin + stable MAC + `stat -fc %T /sys/fs/cgroup` = `cgroup2fs` | 2 | `mender_altbootcmd` → Yocto slot A |
| **9** | 14-day soak, then mirror to slot A | Both slots Debian | 14 d uptime, no pstore records, no mmc errors, one full A→B→A update cycle by script | 1 (+14 elapsed) | `omni-emmc-full.img.gz` |

**Total: ~21 engineering days.** Phases 4 and 8 are hard gates.

### The Phase 4 gate

Boot **entirely from the `=>` prompt** — no `fw_setenv`, no `saveenv`, no `mender_boot_part` change. A power cycle undoes 100 % of it, so DTS iteration costs 30 seconds instead of a bootcount attempt:

```
ext4ls   mmc 0:2 /boot
ext4load mmc 0:2 0x08008000 /boot/meson-axg-apollo.dtb
ext4load mmc 0:2 0x08080000 /boot/Image
ext4load mmc 0:2 0x13000000 /boot/<value of mender_ramdisk_name>
setenv bootargs root=/dev/mmcblk0p2 rootwait rw console=ttyAML0 panic=10
booti 0x08080000 0x13000000:${filesize} 0x08008000
```

Never `saveenv` at the prompt: `MENDER_BOOTARGS` prepends `root=${mender_kernel_root}` to `${bootargs}` each boot, so a saved `bootargs` accumulates duplicate `root=` permanently.

Because slot B is a `dd` clone of slot A (remount the lower `ro` and `sync` first — it is mounted `rw` per `repo/meta-apollo/recipes-core/initrdscripts/initrd-apollo/init:52`), the two rootfs images are **bit-identical** and this is a true single-variable comparison:

1. **NIC.** `ethtool eth0` = 1000/full. Identical 30-min bidirectional iperf3 from 5.4 and from 6.12, both numbers recorded, 6.12 ≥ 5.4. `ethtool -S eth0` rx CRC/length errors = 0. **Compare each direction separately** — an RX-delay fault is asymmetric and TCP hides it in aggregate. 20 cable pulls each produce a link event **and** an incrementing count in `/proc/interrupts` for the gpio_intc line (if the count stays 0 the DTS interrupt is decorative and phylib is polling). **Every comparison boot must be a cold power cycle with mains removed ≥10 s** — the RTL8211F has no reset line in the DTS, so its paged 0xd08 registers persist across soft reboots and 5.4 will look broken after a bad 6.x boot.
2. **eMMC.** `/sys/kernel/debug/mmc0/ios` matches the 5.4 baseline (timing spec, clock, bus width). 2 h `fio --direct=1 --verify=crc32c --verify_fatal=1` on a raw scratch partition. 50 consecutive warm `reboot` cycles, each mounting root — this is the only test that catches an `mmc-pwrseq-emmc` BOOT_9 pad-numbering error, which is cold-boot-invisible.
3. **Recovery unregressed.** Reset-button boot still reaches p7; `md.w 0xff80023c 1` on the new kernel still reads non-`0xd000` after a clean reboot.

Any failure: stop and fix the DTS. Do not proceed to userland.

---

## The DTS port

One file replaces eight patches (0003 patches the Apollo DTS despite its s400-named file). Drop it into `patch/kernel/archive/meson64-6.12/dt/` — the [`dts-directories` + `auto-patch-dt-makefile`](https://raw.githubusercontent.com/armbian/build/main/patch/kernel/archive/meson64-6.18/0000.patching_config.yaml) mechanism (verified present in `meson64-6.12`'s `0000.patching_config.yaml` too) copies it in and patches the DT Makefile automatically.

> **Kernel version — re-checked 2026-08-02, then tested by building.** 6.12 is now Armbian's `oldlts` and its projected EOL (Dec 2026) is only months away. 6.18 LTS — Armbian `current`, archive dir `patch/kernel/archive/meson64-6.18/` — is supported into late 2027. Everything in this plan transfers unchanged; on 6.18 three details actually get simpler: `default-brightness` (landed in 6.13) works, the PWM node is already the pwm-v2 binding described below, and the drop directory becomes `meson64-6.18/dt/`. Armbian's meson64 kernel config is identical on both branches for every option this plan touches (verified against `linux-meson64-oldlts.config` and `-current.config`), and `board/meson-axg-apollo.dts` compiles clean against both v6.12 and v6.18 headers.
>
> **The build settles it: pin 6.18, not 6.12.** At the pinned Armbian SHA, `BRANCH=current` (6.18) obtains all four kernel debs from Armbian's published artifact cache in seconds. `BRANCH=oldlts` (6.12) cannot: the same cache lookup returns `denied: requested access to the resource is denied` for anonymous pulls, so it falls back to building from source — and that build fails deterministically inside Armbian's own `patching.py` before a single patch is applied, for the *reference* board `gateway-gz80x` with none of our changes involved. So 6.12 is not merely closer to EOL, it is the branch that does not build. `board/avast-omni.csc` and the `post_family_config` hook should carry `KERNEL_TARGET="current"` / `KERNEL_MAJOR_MINOR="6.18"` unless someone first fixes the 6.12 patch series upstream.

| Source | Action |
|---|---|
| `0001-arm64-dts-meson-axg-add-apollo-evt0-board.patch` | Rebase — becomes the file. Memory `<0x0 0x0 0x0 0x20000000>` at line 85. |
| `0002` eMMC 200 MHz, `0003` PHY IRQ `<98 IRQ_TYPE_LEVEL_LOW>`, `0004` naming | Fold in |
| `0005-DOWNSTREAM-apollo-leds-*` | **Delete** — patches `include/linux/leds_pwm.h`, gone from mainline |
| `0006` + `0014` dma thresh | **Delete entirely** — `snps,pbl` is a string read by `of_property_read_u32`, never took effect, and mainline `meson-axg.dtsi` (verified on v6.12) already carries the identical `rx-fifo-depth = <4096>` / `tx-fifo-depth = <2048>`, which stmmac reads into `plat->rx_fifo_size` and which gate TSO. |
| `0012` ramoops | Keep; rename `ramoops@f9800000` → `ramoops@f400000` to match its own `reg` |

**Lift from `meson-axg-jethome-jethub-j1xx.dtsi`:** `emmc_pwrseq` (identical BOOT_9), `&sd_emmc_c`, `&uart_AO`, the fixed-regulator idiom, and `thermal-zones` (passive 70 / hot 80 / critical 100 °C — the Omni ships with **no** thermal management today).

**Do not lift ethernet from JetHub** — it is 100 Mbit RMII with an ICPlus PHY. Copy `&ethmac` from `meson-axg-s400.dts` (RGMII gigabit RTL8211F), which the Omni's node is already a byte-for-byte copy of.

**Bindings that changed 5.4 → mainline:**

- **PWM:** on 6.12 the dtsi still uses `amlogic,meson-axg-ee-pwm` (verified — no `clocks` property, old driver). The `amlogic,meson-axg-pwm-v2` conversion with clock parents in the dtsi landed later (present by 6.18). `#pwm-cells` is 3 in both, so `pwms = <&pwm_cd 0 7812500 0>` parses either way — but across the v2 rewrite the 128 Hz period is an empirical check.
- **LEDs:** keep `label = "apollo:power"` / `"apollo:app1"` / `"apollo:app2"` **verbatim**. `led_compose_name()` uses `props.label` as-is for leds-pwm; switching to `function`/`color` renames the sysfs paths the initramfs writes. `default-brightness` landed in 6.13, so on 6.12 use per-LED `max-brightness` + `default-state = "on"`.
- **NAND:** mainline added `nand-controller@7800` whose `"emmc"` reg region *is* `sd_emmc_c`'s window, defaulting to `okay` (verified on v6.12: no `status` property), and Armbian's meson64 config ships `MTD_NAND_MESON=m`, so the module exists and will bind. Add `&nfc { status = "disabled"; };` plus `MODULES_BLACKLIST="meson_nand"` and `CONFIG_MTD_NAND_MESON=n`.
- **PHY delay:** before touching anything, read MDIO page 0xd08 reg 17 bit 8 (TX delay) and reg 21 bit 3 (RX delay) on 5.4, then on 6.x. 5.4's `rtl8211f_config_init()` programs only TX; mainline programs both, so `phy-mode = "rgmii"` may *clear* an RX delay the working system relied on. If they differ, the correct value is `phy-mode = "rgmii-rxid"`.

**Reset button:** GPIOAO_10, active low. U-Boot reads it as a raw register (`setexpr button *0xff800028 & 0x400`, `.../0047-recovery-apollo-Check-registers-to-detect-button.patch`) and is unaffected by Linux. In the DTS use **`gpio-keys-polled`**, not `gpio-keys`, with `<&gpio_ao GPIOAO_10 GPIO_ACTIVE_LOW>` → `KEY_RESTART`.

> **Corrected during implementation.** Plain `gpio-keys` *cannot probe* on meson-axg, for two independent reasons verified in the v6.12 source. `pinctrl-meson` never populates `gpio_chip.to_irq` and never registers a `gpio_irq_chip`, so `gpiod_to_irq()` returns `-ENXIO` and the driver fails with "Unable to get irq number for GPIO". Adding an explicit `interrupt-parent`/`interrupts` does not rescue it either: `gpio_keys_setup_key()` unconditionally requests `IRQF_TRIGGER_RISING | IRQF_TRIGGER_FALLING` whenever a gpiod is present, and `meson8_gpio_irq_set_type()` rejects `EDGE_BOTH` with `-EINVAL` because `axg_params` sets `support_edge_both = false`. This is why every mainline Amlogic board uses `gpio-keys-polled`. Armbian's meson64 config already ships `CONFIG_KEYBOARD_GPIO_POLLED=y`, so no config delta is needed.

**Kernel config delta**, asserted by `tools/check-kconfig-invariants.sh` in CI.

> **Corrected during implementation (2026-08-02).** Two mechanism details in this paragraph were wrong, and both were found by actually building:
>
> 1. `userpatches/config/kernel/linux-meson64-<branch>.config` is a **full replacement, not a fragment.** `kernel-config.sh` copies it over `.config` wholesale and then runs `olddefconfig`, so dropping a 20-line delta there silently discards all ~4100 stock options. `tools/sync-armbian-board.sh` therefore *generates* the override on every run as (pinned base config − every symbol the delta names) + (the delta), and asserts afterwards that each delta option appears exactly once and the result is no shorter than the base.
> 2. **Armbian mutates `.config` after that file is installed,** so two of the delta lines cannot win on their own. `call_extensions_kernel_config()` applies `opts_n → opts_y → opts_m → opts_val` *after* the copy: `OVERLAY_FS` is forced to `=m` by Armbian's docker-support hook (an `opts_y` from us loses, because `opts_m` runs later), and `DEBUG_INFO` is forced on by its eBPF/BTF hook. Both are pinned from `board/post_family_config__avast-omni.sh` using `opts_val`, which is applied last.

Delta contents:

`CONFIG_REALTEK_PHY=y` (**absent from Armbian's meson64 config**, which enables `ICPLUS_PHY` for JetHub; without it the RTL8211F degrades to genphy — "gigabit that mostly works"), `OVERLAY_FS=y`, `LEDS_PWM=y`, `PWM_MESON=y`, `MMC_MESON_GX=y`, `EXT4_FS=y`, `PSTORE_RAM=y`, `NFT_COMPAT=m`, `MESON_GXBB_WATCHDOG=y` (Armbian ships it `=m`), `MTD_NAND_MESON=n`, `CONFIG_PANIC_TIMEOUT=15` and `CONFIG_PANIC_ON_OOPS=y` (both live on 5.4 at `defconfig:335-336`; mainline defaults `PANIC_TIMEOUT` to 0 = hang forever, and Armbian's config leaves it unset — see appendix correction 5), `DEBUG_INFO` unset (5.4 has it on, `repo/meta-apollo/recipes-kernel/linux/files/defconfig:334`). Pin the kernel explicitly with a `post_family_config` hook setting `KERNEL_MAJOR_MINOR="6.12"` — `KERNEL_TARGET` branch names roll forward silently (verified: Armbian's meson-axg family today maps `oldlts`→6.12, `current`→6.18, `edge`→7.1). Do **not** forward-port patches `0009` (defconfig trimming — it removes *packet* schedulers and friends: `NET_SCH_HTB/TBF/FQ_CODEL/INGRESS`, `NET_CLS_U32/ACT`, `IFB`, `SYN_COOKIES`, `xt_TCPMSS`; a router wants those back, and Armbian's config has them), `0010` (→ `net.netfilter.nf_conntrack_tcp_be_liberal=1`) or `0011` (`IPV6_MULTIPLE_TABLES` is not Kconfig-default, but Armbian's meson64 config already sets it `=y`).

---

## Rootfs and initramfs

**Build with `mmdebstrap`, not Armbian's image pipeline.** Armbian is used only as a kernel factory (`BOOTCONFIG="none"` — it then never compiles U-Boot and never calls `write_uboot_to_loop_image`). `mmdebstrap --architectures=arm64 --mode=unshare --variant=important --format=tar`, with a customize-hook installing the Phase 6 `linux-image`/`linux-dtb` debs from a local repo. This structurally eliminates `armbian-bsp-cli` — and therefore `armbian-install`, which repartitions eMMC and rewrites bootloaders. Assert `test ! -e /usr/bin/armbian-install` in CI.

**Pack with a pinned feature set**, derived from the Phase 0 `dumpe2fs -h /dev/mmcblk0p1` line, with a build-time assertion:

```sh
mke2fs -q -t ext4 -b 4096 -m 0 -L omni_root -U <fixed> \
  -O ^64bit,^metadata_csum,^metadata_csum_seed,^orphan_file \
  -E root_owner=0:0 -d rootdir omni-slot.ext4 <blocks matching p2 exactly>
```

Debian trixie's e2fsprogs 1.47 enables `metadata_csum_seed` and `orphan_file` by default ([Debian #1072566](https://bugs.debian.org/1072566)); the current image works only because kirkstone shipped 1.46. This is a **new** risk that fails as an unbootable slot, not a build error.

> **Measured 2026-08-02 — keep the flags, drop the reasoning.** p1's superblock actually reads `64bit` **SET**, `metadata_csum` **SET**, `csum_seed` clear, `orphan_file` clear, block size 1024. So "derive the feature set from p1" would mean *enabling* the first two, and the real news is that **U-Boot 2018.09 reads `64bit` + `metadata_csum` ext4 perfectly well** — it boots that filesystem today. The `-O ^…` line above is still correct to keep, because disabling features only ever makes a filesystem more readable; but the two that genuinely matter are `metadata_csum_seed` and `orphan_file`, the ones 1.47 newly turns on and p1 does not have. Details in `docs/HARDWARE-MEASURED.md`.

**`/boot` uses real files at the exact captured names**, via `/etc/default/omni-boot` (populated from Phase 0's `fw_printenv`, never from literals) consumed by `/etc/kernel/postinst.d/zz-omni-flatten` and `/etc/initramfs/post-update.d/99-omni-flatten`, which `cp -f` — never `ln` — the real `vmlinuz-<ver>`, `dtb-<ver>/amlogic/meson-axg-apollo.dtb` and `initrd.img-<ver>` onto the three fixed names. This means `mender_kernel_name`/`mender_dtb_name`/`mender_ramdisk_name` — which are **global, not per-slot** — never change, so rollback into the Yocto slot stays symmetric, and U-Boot's ext4 symlink behaviour never matters. Cost: ~40 MB per slot.

**Overlay init** becomes `/etc/initramfs-tools/scripts/local-bottom/omni-overlay`, porting `repo/meta-apollo/recipes-core/initrdscripts/initrd-apollo/init` with three fixes: `readlink -f "$ROOT"` instead of `get_last_char()`; `mount -o remount,ro /lower` (the cmdline is `rootwait rw` with no `ro`, so initramfs-tools mounts the lower read-write and dirties the slot every boot); and `panic "..."` on every failure so a fault lands you in the initramfs shell on serial. `initramfs.conf`: `MODULES=list` (never `dep` — it infers from the build host), `ROOTFSTYPE=ext4`, `RESUME=none`, `COMPRESS=gzip`. Keep the original Yocto cpio.gz checked in as a rescue initrd, plus a busybox rescue initrd that drops a shell on ttyAML0 and never `switch_root`s — it can carry `fw_setenv` and un-brick a slot with no rootfs at all.

**Per-slot state.** The overlay upper is p5 for slot A and p6 for slot B (`OVERLAY_PART_NO = ROOT_PART_NO + 4`), so anything written to `/etc` or `/var` reverts to that slot's *stale* state on an A/B flip. Relocate to `/data` (p3, `repo/meta-apollo/recipes-core/systemd-apollo/files/data.mount`):

| Item | Mechanism |
|---|---|
| sshd host keys | `HostKey /data/ssh/ssh_host_ed25519_key` |
| `/root/.ssh`, `/etc/wireguard` | symlinks baked into the image |
| `/etc/machine-id` | **initramfs seed only** — systemd PID1 overmounts it before any unit runs, and systemd-networkd derives its DHCP DUID from it |
| `/var/lib/dpkg`, `/var/lib/apt`, `/etc/passwd`, `/etc/fstab` | **stay per-slot** — sharing them corrupts on first divergence |

Nothing in `/data` is A/B-protected, so a bad config there survives a rollback. **The bootable minimum — an address on the interface and a running sshd — lives in the image.** Do not replicate the current firmware's `/etc/systemd/network/00-eth0.network` → `/data` symlink.

**Three things that will otherwise strand you:**

1. **The NIC will be named `end0`, not `eth0`.** The `aliases { ethernet0 = &ethmac; }` you must keep for `fdt_fixup_ethernet()` is the same alias systemd-udev reads for DT-based naming, gated on scheme v251+. Kirkstone ships systemd 250; trixie ships 257. Match on `Name=e*` or ship a `.link` with `NamePolicy=` forcing `eth0`, and assert the name on serial in Phase 4.
2. **Serial autologin must be preserved.** Today the console is passwordless root (`repo/meta-apollo/recipes-core/systemd-apollo/systemd-serialgetty/access.conf:2` → `ACCESS=-aroot`). Ship `serial-getty@ttyAML0.service.d/autologin.conf` with `--autologin root` and assert it in CI. Harden SSH; do not harden the console — otherwise "no network" means no SSH, no bootloader prompt, and no login.
3. **Delete the cgroup v1 line** `none /sys/fs/cgroup tmpfs ...` from the fstab (`repo/meta-apollo/recipes-core/base-files/files/fstab-logs:8`) — do not edit it. systemd PID1 mounts cgroup2 itself before fstab is processed. Carry `RuntimeWatchdogSec=10` forward (Debian defaults it off) **only after** P5 establishes where a watchdog reset lands.

---

## Flashing and rollback

The Mender daemon was never installed. Its whole bootloader contract is four env writes on install, one on commit, three on rollback — a shell script reproduces it exactly.

```sh
#!/bin/bash
set -euo pipefail

active=$(fw_printenv -n mender_boot_part)
case "$active" in 1) target=2;; 2) target=1;; *) echo "ABORT active=$active"; exit 1;; esac
tgt=/dev/mmcblk0p$target; ovl=/dev/mmcblk0p$((target+4))
grep -q " $tgt \| $ovl " /proc/mounts && { echo "ABORT: target mounted"; exit 1; }
[ "$(blockdev --getsize64 "$tgt")" -ge "$IMG_SIZE" ]

# Quiesce. A 400 MB write on a 512 MB box can starve PID 1 past its 10 s watchdog ping —
# and a watchdog reset goes to p7, NOT to the other slot.
mkdir -p /run/systemd/system.conf.d
printf '[Manager]\nRuntimeWatchdogSec=0\n' > /run/systemd/system.conf.d/99-flash.conf
systemctl daemon-reexec
[ "$(systemctl show -p RuntimeWatchdogUSec --value)" = "0" ]
trap 'rm -f /run/systemd/system.conf.d/99-flash.conf; systemctl daemon-reexec;
      systemctl start docker containerd syslog-ng || true' EXIT
# The Debian image ships no container runtime (see below); these are still stopped
# because this runs on whichever slot is booted NOW, and during migration that is
# the Yocto slot, which has them. Absent/inactive units are skipped.
systemctl stop docker.service containerd.service syslog-ng.service
sysctl -qw vm.dirty_bytes=16777216 vm.dirty_background_bytes=8388608 kernel.printk="3 4 1 3"
sync; echo 3 > /proc/sys/vm/drop_caches
awk '/MemAvailable/{exit ($2 < 250000)}' /proc/meminfo   # /var/volatile/log alone is a 140 MB tmpfs

# Stage on /data if it fits — decouples a dead network from a half-written slot.
# Streaming fallback (curl exiting mid-transfer leaves a truncated image that dd reports as success):
mkfs.ext4 -F "$ovl"                                   # stale Avast files in the upper WILL reappear
curl -fL "$URL" | gzip -dc | dd of="$tgt" bs=1M iflag=fullblock conv=fsync
sync; blockdev --flushbufs /dev/mmcblk0

[ "$(head -c "$IMG_SIZE" "$tgt" | sha256sum | cut -d' ' -f1)" = "$IMG_SHA" ]
e2fsck -fn "$tgt"

# Arm: ONE batched write. 2018.09 syntax is "name value"; libubootenv uses "key=value".
printf 'mender_boot_part %s\nmender_boot_part_hex %s\nbootcount 0\nupgrade_available 1\n' \
  "$target" "$target" > /run/env.txt
echo 0 > /sys/block/mmcblk0boot0/force_ro
fw_setenv -s /run/env.txt
echo 1 > /sys/block/mmcblk0boot0/force_ro
fw_printenv mender_boot_part upgrade_available bootcount     # read back and assert
sync; reboot
```

Batching covers only **one of three** env-write windows: `CONFIG_BOOTCOUNT_ENV=y` means U-Boot itself calls `env_save()` on **every armed boot**, and `mender_altbootcmd` `saveenv`s again. Minimise armed time; do not power-cycle between arm and commit.

**Commit + deadman**, shipped in the image. The guard must require positive evidence (carrier up, default route, a successful outbound TCP connect) and must **not** use `After=network-online.target` alone — `After=` is ordering, not a dependency, so the guard can fire instantly and disarm the slot permanently. Pair it with `omni-deadman.timer` (`OnBootSec=15min`) that reboots if `upgrade_available` is still `1` — nothing else will power-cycle a box in a closet.

**Recovery ladder, by reliability:**

| Rank | Path | Depends on |
|---|---|---|
| 1 | Serial `=>` prompt | `bootdelay >= 0`. Note a *failed* `load` drops to `=>` regardless of bootdelay — a slot that fails to load is always recoverable. |
| 2 | Reset button → p7 | p7 populated (P6). Overrides `mender_boot_part`; needs no tools. |
| 3 | `fw_setenv force_hard_recovery 1` → p7 | Same, armed in advance from a working Linux |
| 4 | `bootcount`/`bootlimit` auto-rollback | Something must *reboot*. Today `CONFIG_PANIC_TIMEOUT=15` (`defconfig:336`) reboots a panicked 5.4 kernel, so rollback does fire — but mainline defaults the timeout to 0 (hang forever) and Armbian's config leaves it unset, so the **new** kernel must carry `CONFIG_PANIC_TIMEOUT=15` in the config delta, plus `panic=10` in `bootargs` as belt-and-braces. Also neutralise `check_watchdog` (`fw_setenv check_watchdog "false"`) during migration, or a watchdog reset diverts to p7 instead of rolling back. |
| 5 | Amlogic USB boot (`1b8e:c003`, [pyamlboot](https://github.com/superna9999/pyamlboot) `s400`) | A physically routed USB port — unknown until Phase 5 |

---

## What this fixes

| Gap today | After |
|---|---|
| No WireGuard (`CONFIG_WIREGUARD` absent) | `WIREGUARD=m` in Armbian's stock meson64 config |
| No nftables (`CONFIG_NF_TABLES` absent); iptables-legacy + ipset | `NF_TABLES=m` + `NFT_COMPAT`; native nft sets, and `iptables` on trixie is the nft backend so there is one packet engine, not two |
| cgroup v1 via a tmpfs fstab hack (`fstab-logs:8`); systemd ≥256 refuses to boot on v1 | cgroup v2, mounted by systemd PID 1 itself; the fstab line simply does not exist |
| Yocto rebuild for every package change; 6 h CI | `apt`; kernel + initrd maintained by dpkg postinst hooks |
| Kernel 5.4.62 vendor tree, EOL since Dec 2025 | Mainline LTS — 6.12 only to Dec 2026, 6.18 into late 2027; see the kernel-version note in *The DTS port* |
| Forked GCC 10.2 in meta-smarthome-common; meta-gplv2 (bash 3.2, coreutils 6.9, tar 1.17) | Debian toolchain and userland, both deleted |

---

## Risks

1. **A watchdog reset goes to p7, not to the other slot.** `check_watchdog` runs before `mender_setup`, and `altbootcmd` ends in `run bootcmd`, which re-evaluates it — so rollback cannot escape a latched register. *Mitigation:* P5 characterisation; `fw_setenv check_watchdog "false"` during migration; watchdog off during any flash.
2. **A torn env write is unrecoverable in-band.** Single 8 KB copy + `env default -a; saveenv; reset` on canary loss restores `force_run_mfc=1`, which wants a file this repo cannot build. *Mitigation:* P7 restore drill before arming anything; one batched write; short armed window.
3. **`REALTEK_PHY` missing / wrong `phy-mode`** degrades to polled genphy with cleared RX delay — "gigabit that mostly works." *Mitigation:* CI kconfig assertion; MDIO 0xd08 register comparison; per-direction iperf3; cold power cycle between comparison boots.
4. **e2fsprogs 1.47 defaults produce a filesystem U-Boot may refuse.** *Mitigation:* clone p1's feature set, assert at build time, prove with `ext4load` before arming.
5. **The Debian slot boots with no console and no network** (`end0` rename + locked root + no autologin). *Mitigation:* serial autologin asserted in CI; `Name=e*`; deadman timer.
6. **The initramfs-tools port is unexercised through Phase 6.** *Mitigation:* qemu-aarch64 loopback dry-run during the Phase 5 soak — off-hardware, zero critical-path cost.
7. **The stale overlay upper (p5/p6)** resurrects years-old Avast files over a new lower. *Mitigation:* guarded `mkfs.ext4 -F` in the flash script, before the rootfs write.
8. **Armbian `current` rolls the kernel major forward silently.** *Mitigation:* submodule SHA pin + explicit `KERNEL_MAJOR_MINOR`; weekly rebase-into-a-branch CI, never auto-merge.

---

## Open questions — measure on the device

| Question | How |
|---|---|
| Total eMMC capacity and p1/p2/p3/p5/p6/p7 sizes | `blockdev --getsize64`, `sfdisk -d` |
| Is p7 populated and bootable? | Reset-button cold boot (P6) |
| Is a USB2 port physically routed? | `&usb { status = "okay"; }` on a throwaway DTB + a known-good dongle — decides 2-NIC router vs router-on-a-stick |
| What sets `0xff80023c` to `0xd000`? | P5, six reset types |
| eMMC wear (`pre_eol_info`, `life_time_est`) | `ext_csd` — a worn card will look like a DTS bug |
| Does `bootcount` actually persist and `altbootcmd` actually exist in the *stored* env? | Phase 1 |
| Does U-Boot 2018.09 have `setexpr` on this unit? | `setexpr b *0xff800028 & 0x400` at `=>`; absent means pre-`0041` and the reset button does nothing |
| ~~Is `/data` (p3) large enough for Docker images?~~ | ✅ **CLOSED — Docker dropped.** Measured `/data` = 150 MiB total, 130 MiB free: not enough for one image. But the prior question was whether Docker is needed at all, and on the measured unit `docker.service` is **inactive with zero images** — and it could not work well anyway, because its data-root would sit on the root overlayfs and **overlayfs cannot be an overlayfs upperdir** (the kernel logs `not supported as upperdir` on every start attempt), leaving only the `vfs` driver, which stores every layer as a full copy on a 4 GB eMMC. So `docker.io`, `containerd` and `runc` are **removed from the Debian image**, along with `etc/docker/daemon.json` and `etc/containerd/config.toml`. This closes the `/data` capacity problem outright. If containers are ever needed: p5/p6 are 650 MiB each holding 2.0 MB of real data, so shrink them and grow p3 first, give Docker a data-root on a real filesystem, then re-add the packages (both config files are in git history). |

---

## Appendix: independent verification of the safety-critical claims

The five claims below decide whether the rollback story actually works. Each was re-checked
directly against the repo rather than taken from the analysis.

| # | Claim | Verdict | Evidence |
|---|---|---|---|
| 1 | `check_env` (the `ethaddr` self-heal) is dead code | **CONFIRMED** | `0025-configs-apollo-add-env-checking-and-reset.patch` sets `CONFIG_BOOTCOMMAND="run check_env; run distro_bootcmd"`, but `0031-mender-Disable-CONFIG_BOOTCOMMAND-and-enable-CONFIG_.patch` rewrites `include/env_default.h` so `bootcmd` is populated from `CONFIG_MENDER_BOOTCOMMAND` instead. `check_env` is never invoked. |
| 2 | A watchdog reset diverts to p7 and rollback cannot escape it | **CONFIRMED** | `0044-recovery-apollo-Add-support-for-recovery-reset.patch:36` defines `check_watchdog=itest.w *0xff80023c -eq 0xd000` (`0047:24` carries it as unchanged context while converting the button check to a register read). The bootcmd branches on `run check_watchdog \|\| test "${force_hard_recovery}" = "1"` **before** slot selection (`0044:63`, and `0055` places `APOLLO_CHECK_MFC` ahead of even that), and `0029-mender-Generic-boot-code-for-Mender.patch:157` defines `altbootcmd=run mender_altbootcmd; run bootcmd` — so the fallback re-enters bootcmd and re-evaluates `check_watchdog`. A latched register traps every boot in recovery. |
| 3 | U-Boot rewrites the env on every armed boot | **CONFIRMED** | `CONFIG_BOOTCOUNT_ENV=y` at `0038-defconfig-apollo-Regenerate-defconfig.patch:22` and `0033-mender-apollo-Apply-mender_auto_configured.patch.patch:50`. Combined with the single non-redundant 8 KB env copy, the armed window is the torn-write exposure. |
| 4 | `altbootcmd` ends in `run bootcmd` | **CONFIRMED** | `0029-mender-Generic-boot-code-for-Mender.patch:157-158`. |
| 5 | "No `panic=` anywhere today, so a panicking kernel hangs forever and rollback provably cannot fire" | **WRONG about the current system** | `repo/meta-apollo/recipes-kernel/linux/files/defconfig:336` has `CONFIG_PANIC_TIMEOUT=15`, and `:335` has `CONFIG_PANIC_ON_OOPS=y`. The running kernel reboots 15 s after a panic without any `panic=` on the cmdline, so bootcount rollback **does** fire today. |

### Consequence of correction 5

The recommendation (`panic=10` in bootargs) is still right, but for the opposite reason than stated.
The hazard is not the current system — it is the **new** one. `CONFIG_PANIC_TIMEOUT` defaults to `0`
(hang forever) in mainline, and it is absent from this plan's kernel-config delta. A mainline kernel
built from Armbian's stock meson64 config would therefore lose a panic-reboot behaviour the current
firmware has.

Two amendments to the plan above — **both now folded into the main body** (the kernel-config
delta in *The DTS port* and recovery-ladder rank 4):

1. Add `CONFIG_PANIC_TIMEOUT=15` and `CONFIG_PANIC_ON_OOPS=y` to the kernel config delta in
   *The DTS port*, and to `tools/check-kconfig-invariants.sh`.
2. Treat `panic=10` on the cmdline as belt-and-braces, not as the primary mechanism.

Do not read correction 5 as softening risk #1. Items 1-4 all confirmed, and risk #1 — a watchdog
reset escaping the A/B model entirely — is real and is the single most important thing to
characterise in pre-flight check P5.

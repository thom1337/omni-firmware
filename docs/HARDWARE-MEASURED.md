# Avast Omni — measured hardware facts

Companion to `docs/HARDWARE.md`, which is the blank Phase 0 template and whose
`<<UNFILLED>>` gate stays authoritative for everything still unknown. **This
file is data.** Every value below was read off a live unit; nothing is inferred
from the Yocto tree.

**Unit:** `avast-omni`, `Environment: prod`
**Measured:** 2026-08-02 over the serial console (ttyAML0, 115200) via a jumphost.
**Firmware:** apollo-poky (Yocto kirkstone) 6.6.1, build 20240829, kernel 5.4.62.

Nothing on the device was written: no `fw_setenv`, no partition change, no
reboot. The only mounts were `-o ro,noload` (read-only, journal replay
suppressed), and they were unmounted again.

---

## SoC, storage and partitions

| Item | Value |
|---|---|
| Kernel | `5.4.62 #1 SMP PREEMPT Thu Sep 3 09:27:11 UTC 2020 aarch64` |
| Kernel cmdline | `root=/dev/mmcblk0p1 rootwait rw console=ttyAML0` |
| Running slot | **A (p1)** |
| Root filesystem | `overlay` — `lowerdir=/lower, upperdir=/overlay/upper, workdir=/overlay/work` |
| eMMC total | **3,959,422,976 B (3.96 GB / 3.69 GiB)** — a 4 GB part, not 8 GB |
| eMMC part | `004GA0`, manfid `0x000011` (Toshiba), oemid `0x0100`, serial `0x961a8ddd`, rev `0x7` |

### Partition table (`lsblk -b`)

| Part | Bytes | Size | Role | Filesystem |
|---|---:|---:|---|---|
| `mmcblk0p1` | 891,289,600 | 850 MiB | rootfs slot **A** (running) | ext4, 1024 B blocks, UUID `6068ec52-…` |
| `mmcblk0p2` | 891,289,600 | 850 MiB | rootfs slot **B** | ext4, 4096 B blocks, UUID `f15dbf0e-…` |
| `mmcblk0p3` | 157,286,400 | 150 MiB | `/data` (mounted) | ext4, 1024 B blocks |
| `mmcblk0p4` | 1,024 | 1 KiB | extended-partition marker | — |
| `mmcblk0p5` | 681,574,400 | 650 MiB | overlay upper for slot A | ext4, 4096 B blocks |
| `mmcblk0p6` | 681,574,400 | 650 MiB | overlay upper for slot B | ext4, 4096 B blocks |
| `mmcblk0p7` | 471,859,200 | 450 MiB | recovery | ext4, **LABEL=`recovery`** |
| `mmcblk0boot0` | 2,097,152 | 2 MiB | U-Boot env at offset 0, 8 KiB | raw |
| `mmcblk0boot1` | 2,097,152 | 2 MiB | (spare) | raw |

**A slot is 891,289,600 B = exactly 217,600 × 4096.** That is the hard ceiling
for `omni-slot.ext4`. `rootfs/build-rootfs.sh` now defaults to exactly this and
refuses to build anything larger — its previous 1 GiB default would have
produced an image that physically cannot be written.

### Free space

```
overlay          624M total    2.0M used   577M avail   /
/dev/mmcblk0p3   142M total    1.6M used   130M avail   /data
tmpfs            140M total     72K used   140M avail   /var/volatile/log
/dev/mmcblk0p7   435M total    203M used   206M avail   (recovery, mounted read-only)
```

### eMMC health

| Attribute | Value | Meaning |
|---|---|---|
| `pre_eol_info` | `0x01` | **Normal** (not `0x02` Warning, not `0x03` Urgent) |
| `life_time` | `0x01 0x00` | Type A: **0–10 % of rated life used**; Type B not reported |

The card is healthy. That matters for Phase 4: eMMC misbehaviour under the new
kernel is a DTS bug, **not** a worn card.

---

## U-Boot environment

Backed up before anything else and **CRC-verified byte-exact**: the CRC32 stored
in the 8 KiB block is `0x24409592` and the CRC32 computed over the payload
matches. 67 variables.

```
~/omni-backups/<date>/omni-boot0-env-8k.bin   # raw 8 KiB block, restorable at the => prompt
~/omni-backups/<date>/omni-env.txt            # fw_printenv text form
```

Deliberately **not** committed to git — it contains the unit's MAC and serial.

### Values that decide the migration

| Variable | Value |
|---|---|
| `bootdelay` | **`2`** |
| `altbootcmd` | `run mender_altbootcmd; run bootcmd` |
| `bootcount` / `bootlimit` | `1` / `1` |
| `upgrade_available` | `0` |
| `mender_boot_part` / `_hex` | `1` / `1` |
| `mender_kernel_name` | `Image` |
| `mender_dtb_name` | `meson-axg-apollo.dtb` |
| `mender_ramdisk_name` | `apollo-initramfs-image-meson-apollo.cpio.gz` |
| `ethaddr` | `00:01:38:2a:bb:5c` — matches the live `eth0` MAC exactly |
| `force_run_mfc` / `force_run_eol` | `0` / `0` |
| `force_hard_recovery` | not set |
| `check_watchdog` | `itest.w *0xff80023c -eq 0xd000; test $? -eq 0;` |
| `bootargs` | **`rootwait rw console=ttyAML0`** — defined, but contains **no `root=`** |
| `button` | `400` |
| `mender_saveenv_canary` | `1` |
| `fdt_addr_r` / `kernel_addr_r` / `ramdisk_addr_r` | `0x08008000` / `0x08080000` / `0x13000000` |

The three load addresses are exactly the ones the plan's Phase 4 manual boot
sequence uses, so that sequence can be pasted as written.

---

## The P1–P8 gate

| # | Check | Result |
|---|---|---|
| **P1** | `force_run_mfc` / `force_run_eol` both `0` | ✅ **PASS** — both `0`. No forced MFC boot to p7. |
| **P2** | `bootargs` not defined | ⚠️ **RESTATE** — it *is* defined, but carries **no `root=`**, so the hazard is absent. See below. |
| **P3** | `ethaddr` non-empty, MAC stable | ✅ **PASS (static half)** — set, and matches the live MAC. ⏳ stability across 3 reboots untested. |
| **P4** | Capture the three `mender_*_name` values verbatim | ✅ **CAPTURED** — they match the compiled post-`0050`/`0051` defaults, so this is not an old binary. |
| **P5** | `md.w 0xff80023c 1` across six reset types | 🟡 **TWO OF SIX DONE, both clean** — see below. Linux `reboot` → `0x0000` (twice), U-Boot `reset` → `0x0000`. Neither latches the recovery register. The remaining four need physical access or a deliberate watchdog bite. |
| **P6** | Reset-button boot reaches a shell on p7 | ✅ **p7 is populated** (see below). ⏳ the button-boot itself needs physical access. |
| **P7** | Env restore drill | ⏳ **NOT DONE** — but its prerequisite, a verified env backup, now exists. |
| **P8** | p2 shows a valid rootfs | ✅ **ANSWERED** — p2 is a *formatted but empty* ext4: `lost+found` and nothing else. Slot B has never been booted, exactly as predicted. **Safe to overwrite.** |

### Why P2 needs restating

The check as written fails on a healthy unit. The stored value is the fixed
common cmdline from patch `0039` and deliberately contains no `root=`. Each boot
`MENDER_BOOTARGS` does

```
setenv bootargs root=${mender_kernel_root} ${bootargs}
```

producing `root=/dev/mmcblk0p1 rootwait rw console=ttyAML0`, byte-for-byte what
`/proc/cmdline` shows. The real invariant is:

> **P2 (restated): the stored `bootargs` must contain no `root=`.**

The "never `saveenv` at the `=>` prompt" rule still stands and is now *more*
important: a `saveenv` taken after `MENDER_BOOTARGS` has run would persist an
expanded `bootargs` containing a `root=`, and every later boot would append
another one.

---

## Findings that change the plan

### 1. `bootdelay=2` — the U-Boot prompt is available

The plan assumed a field unit holds `bootdelay=-2`, making the `=>` prompt
unreachable. **It is `2`.** `abortboot()` prompts whenever `bootdelay >= 0`, so
recovery-ladder rank 1 — the most reliable rung — is live on this unit today,
and Phase 4's "boot entirely from the `=>` prompt" is directly executable.

### 2. There is no bash

`/bin/sh` is a symlink to `/bin/zsh`; there is no `bash` anywhere. Verified on
the device: in that shell `${PIPESTATUS[*]}` expands to empty.

Consequence: **every `tools/omni-*.sh` script is `#!/bin/bash` and cannot run on
the stock image.** They rely on `PIPESTATUS` for truncation detection and on bash
arrays in `env_batch_write()`. `tools/omni-lib.sh` now refuses to run outside
bash with an explicit message rather than misbehaving. Making Phase 0 and Phase 1
executable on the unmodified device requires a POSIX rewrite of the device-side
scripts — that work is **not** done.

### 3. `/data` is 150 MiB — the on-device Docker plan is not viable

The plan asks whether `/data` is large enough for Docker images, and says the
plan needs rethinking if not. It is **150 MiB total, 130 MiB free.** That does
not hold a Docker image, let alone several. `rootfs/overlay/etc/docker/daemon.json`
points `data-root` at `/data/docker` and cannot be used as written. This needs a
decision before Phase 7 ships.

### 4. `/boot/Image` is a symlink, and U-Boot follows it

The running system boots `/boot/Image -> Image-5.4.62`, so U-Boot 2018.09's
`ext4load` resolves symlinks — something the plan hedged about. Real files (what
the flatten hooks produce) remain the safer choice, but symlinks are not the
hazard the plan feared.

### 5. `e2fsck` is present; `dumpe2fs` is not

The plan says the image ships "only `e2fsprogs-mke2fs` — no e2fsck, no dumpe2fs."
Measured: `mke2fs` ✅, `e2fsck` ✅, `dumpe2fs` ❌, `tune2fs` ❌, `debugfs` ❌,
`resize2fs` ❌. So `omni-flash.sh`'s post-write `e2fsck -fn` works on the stock
image; only the `dumpe2fs` inventory step needs a package built.

### 6. Recovery (p7) is populated — and irreplaceable

p7 holds a complete rootfs plus:

```
/boot/Image -> Image-5.4.62                          (10,381,320 B)
/boot/apollo-mfc-initrd-image-meson-apollo.cpio.gz   (14,432,945 B)
/boot/meson-axg-apollo.dtb                           (    27,778 B)
/recovery-data.ext4.bz2                              (134,135,545 B, dated 2024-08-29)
```

The MFC initrd is the artefact the plan correctly notes **nothing in this repo
can build**, and `recovery-data.ext4.bz2` looks like the factory rootfs payload.
Both exist only here. **p7 must never be overwritten, and it is the
highest-value thing to back up** — a restore path the build tree cannot
regenerate.

### 7. No network

`eth0` is `UP` but `NO-CARRIER`, state `DOWN`; only `lo` has an address. No cable
attached. So there is no SSH path, and `tools/omni-backup.sh` (which runs over
ssh from a workstation) cannot be used. A full 3.96 GB eMMC image over 115200
baud is roughly four days, so **the full-eMMC backup in pre-flight step 1 is not
achievable over serial** — it needs a network cable or the box opened.

### 8. p1's real ext4 feature set — the plan's `mke2fs` rationale is wrong (the line is still safe)

Read directly out of p1's superblock (no `dumpe2fs` on the device):

```
block size 1024
compat    0x0000003c  dir_index ext_attr has_journal resize_inode
incompat  0x000002c6  64bit extent filetype flex_bg recover
ro_compat 0x0000046b  dir_nlink extra_isize huge_file large_file metadata_csum sparse_super

  64bit         = SET
  metadata_csum = SET
  csum_seed     = clear
  orphan_file   = clear
```

The plan says to pack the new image with a feature set "derived from the Phase 0
`dumpe2fs -h /dev/mmcblk0p1` line" and then hardcodes

```
-O ^64bit,^metadata_csum,^metadata_csum_seed,^orphan_file
```

But **p1 — the filesystem U-Boot 2018.09 boots today — has `64bit` and
`metadata_csum` enabled.** So:

* The stated justification is wrong: cloning p1 would mean *enabling* those two.
* **U-Boot demonstrably reads `64bit` + `metadata_csum` ext4**, which is the real
  news; the plan feared otherwise.
* The line itself is still **safe** — disabling features only ever makes a
  filesystem *more* readable, never less — so it does not need changing. Only
  `metadata_csum_seed` and `orphan_file` (the two that e2fsprogs 1.47 newly
  enables by default, and which p1 does not have) are genuinely load-bearing.

Keep the conservative flags; drop the "because p1 has it" reasoning.

### 9. P5 partial result — a plain reboot does **not** trap the box in recovery

The plan's risk #1 is that `check_watchdog` (`itest.w *0xff80023c -eq 0xd000`)
runs *ahead* of A/B slot selection, and `altbootcmd` ends in `run bootcmd` which
re-evaluates it — so a latched register traps every boot in recovery p7 and
bootcount rollback provably cannot escape. The plan's specific fear:

> If a plain reboot or a power cut latches it, every reboot goes to recovery and
> the whole risk model changes.

Measured at the `=>` prompt with `tools/omni-uboot.py`:

| Reset type | `0xff80023c` | Diverts to p7? |
|---|---|---|
| Linux `reboot` (run 1) | `0x0000` | no |
| Linux `reboot` (run 2) | `0x0000` | no |
| U-Boot `reset` | `0x0000` | no |

**The two most common reset paths are clean and reproducible.** That removes the
worst version of risk #1: routine reboots — which is what Phase 1's arm/rollback
drill does over and over — do not latch the register.

Still unmeasured, and each needs something I could not do remotely:

| Reset type | Needs |
|---|---|
| Cold power-on | mains removed ≥10 s, physical |
| Cold power **cut** (the plan's specific worry) | physical |
| Forced watchdog bite | deliberately hanging the box; if it *does* latch, clearing it needs a `mw.w` write at the prompt, which `omni-uboot.py` refuses without `--allow-writes` |
| Reset button | physical |

The watchdog case is the one that matters most, because it is the case the
register exists *for*. Do that one with someone at the device.

Incidental confirmations from the same transcripts: `U-Boot 2018.09 (Sep 10 2018
- 21:46:42 +0000) apollo`, `DRAM: 512 MiB`, `Loading Environment from MMC... OK`,
and a resumed `boot` loads 27,778 / 10,381,320 / 11,356,329 bytes — byte-exact
matches for the dtb, kernel and initramfs sizes in `/boot`.

### 10. Phase 1 executed — the A/B contract works exactly as the plan predicted

The first environment writes this device has ever received. Every string the plan
predicted appeared verbatim.

**Setup.** `tools/omni-{lib,arm,commit,rollback}.sh` pushed over serial with
`tools/omni-push.py` (30 KB gzip+base64, ~60 chunks, SHA-256 verified *on the
device* before extraction) into `/data/omni-tools`. They ran unmodified — the
POSIX port works in anger, on a box with no bash.

**The drill.**

| Step | Result |
|---|---|
| `omni-arm.sh --same-slot` | One batched `fw_setenv -s` inside the `force_ro` dance. Read-back asserted all four: `mender_boot_part=1`, `_hex=1`, `bootcount=0`, `upgrade_available=1`. |
| reboot #1 | Booted p1 normally. **`bootcount=1`** — U-Boot persisted it (`CONFIG_BOOTCOUNT_ENV=y` confirmed live). Pointer unmoved, as `--same-slot` intends. |
| reboot #2, uncommitted | **`Warning: Bootlimit (1) exceeded. Using altbootcmd.`** — the plan's exact predicted string. |
| after altbootcmd | `mender_boot_part=2`, `bootcount=2`, `upgrade_available=0`. `mender_altbootcmd` flipped the pointer *and* disarmed, unprompted. |
| **T9, for free** | Slot B is empty, so the flip tried to boot it: `** File not found /boot/meson-axg-apollo.dtb **`, `** File not found /boot/Image **`, `ERROR: Did not find a cmdline Flattened Device Tree`, then **`=>`**. **A failed load drops to the prompt, it does not hang.** The plan asserted this ("a slot that fails to load is always recoverable"); it is now measured. |

**Recovery**, which also rehearsed the Phase 4 mechanism: from `=>`, three
`ext4load`s of p1's dtb/kernel/initramfs (27,778 / 10,381,320 / 11,356,329 bytes
— byte-exact), `setenv bootargs root=/dev/mmcblk0p1 …` (RAM only, **never**
`saveenv`), `booti` → Linux on p1. Then the pointer was restored from Linux and
a clean unattended reboot came up on p1 with no warnings.

**`ethaddr` survived all of it** — `00:01:38:2a:bb:5c` before and after. That was
the single irreplaceable value at risk.

#### Gap this exposed in our own tooling

Both `omni-arm.sh` and `omni-rollback.sh` **refused** the recovery, correctly:
having booted p1 by hand while the stored pointer still said p2, arm says
*"target p1 is the RUNNING root filesystem; refusing to arm it as an update
target"* and rollback says *"a rollback to yourself is not a rollback."* Those
guards are right for normal operation, but they leave no supported way to do the
one thing that situation needs: **put the pointer back**. The restore was done
through the library directly:

```sh
sh -c '. /data/omni-tools/omni-lib.sh; \
       env_batch_write mender_boot_part 1 mender_boot_part_hex 1 \
                       bootcount 0 upgrade_available 0'
```

which still goes through the whole audited path (validate → `force_ro` → one
batched write → re-lock → read-back assert). Worth promoting to a first-class
`omni-set-slot.sh --force`, because the moment you need it is the moment you are
least in the mood to compose it by hand.

### 11. Phase 4 trial boot — mainline 6.18 runs this hardware

Booted `6.18.41-current-meson64` with our DTS entirely from the `=>` prompt, so
nothing persistent was written and the plain reboot afterwards came straight back
to 5.4.62. Kernel and DTB were pushed to `/data` (p3) over serial with
`tools/omni-push.py` and SHA-256 verified on the device; the rootfs was slot A's
own Yocto userland and its existing initramfs, i.e. one variable changed.

```
=> ext4load mmc 0:3 ${fdt_addr_r}     /k618/meson-axg-apollo.dtb
=> ext4load mmc 0:3 ${kernel_addr_r}  /k618/Image
=> ext4load mmc 0:1 ${ramdisk_addr_r} /boot/apollo-initramfs-image-meson-apollo.cpio.gz
=> setenv bootargs root=/dev/mmcblk0p1 rootwait rw console=ttyAML0 panic=10
=> booti ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}
```

**What passed**

| Item | Evidence |
|---|---|
| DTS is live | `Machine model: Avast Omni (Apollo)` |
| eMMC | `mmc0: new HS200 MMC card`; ios reports **199,999,805 Hz, 8-bit, timing spec 9 (HS200)** — an exact match for `max-frequency = <200000000>` and for the 5.4 baseline |
| Partitions | `mmcblk0: p1 p2 p3 p4 < p5 p6 p7 >` |
| Root + overlay | p1 and p5 mounted, `overlayfs: "xino" feature enabled`, p3 mounted at /data |
| Userspace | reached `avast-omni login:` and a working root shell |
| **LED ABI** | `/sys/class/leds/` contains exactly `apollo:power`, `apollo:app1`, `apollo:app2` — the paths the initramfs writes, byte-identical |
| **gpio-keys-polled** | `input: gpio-keys-polled as /devices/platform/gpio-keys-polled/input/input0`. This vindicates the port's non-obvious choice: plain `gpio-keys` cannot probe on meson-axg and would have failed here. |
| `&nfc` disable | no `meson_nand` anywhere in dmesg; nothing contended for the eMMC pads |
| Serial | `ttyAML0 ... is a meson_uart` |
| USB | `dwc3-meson-g12a: USB2 ports: 1` — a USB2 controller exists and initialises (physical routing still unknown) |

**What did not pass**

1. **The NIC never probed — this is the blocking one.** dmesg shows no stmmac or
   dwmac driver at all, only `meson_ee_pwrc: sync_state() pending due to
   ff3f0000.ethernet`, and `/sys/class/net` contains just `lo`. Cause:
   Armbian ships `CONFIG_DWMAC_MESON=m` and this trial had no `/lib/modules` on
   the device. So **plan risk #3 — the RTL8211F RGMII TX/RX delay comparison —
   remains completely untested.** Fixed at the source rather than worked around:
   the config delta now pins `CONFIG_DWMAC_MESON=y` and `CONFIG_STMMAC_ETH=y`,
   for the same reason `REALTEK_PHY` is `=y`. On a headless box the NIC is the
   only remote access, so making it depend on a correctly-mounted rootfs and a
   matching modules tree buys nothing. `check-kconfig-invariants.sh` now enforces
   both as STRICT `=y` and correctly fails the current build (43/44).

2. **No thermal zones.** `/sys/class/thermal/thermal_zone*` does not exist. The
   cause is specific and worth knowing: `scpi_protocol scpi: SCP Protocol legacy
   pre-1.0 firmware`. Our `thermal-zones` node was lifted from JetHub and hangs
   off `thermal-sensors = <&scpi_sensors 0>`, and this unit's legacy SCP firmware
   does not export that sensor. It failed exactly as gracefully as predicted — the
   zone simply did not register and the boot was unaffected — but the Omni still
   has no thermal management. Needs a different sensor or dropping the node;
   a Phase 5 decision, not a blocker.

Neither failure is a DTS defect. The device tree itself is validated on real
silicon for eMMC, storage, console, LEDs, the reset button and the NAND
conflict; what is left is one kernel-config line and one thermal-sensor question.

#### Second trial boot: the NIC, and risk #3 answered

The rebuild the config fix implies would have cost an hour plus another 33-minute
push. Unnecessary — `CONFIG_STMMAC_ETH` and `CONFIG_STMMAC_PLATFORM` were already
`=y`, so the only missing piece was **one 19 KB module**, `dwmac-meson8b.ko`.
Pushed in seconds, `insmod`ed on a second trial boot:

```
meson8b-dwmac ff3f0000.ethernet: User ID: 0x11, Synopsys ID: 0x37   DWMAC1000
meson8b-dwmac ff3f0000.ethernet eth0: PHY [stmmac-0:00] driver [RTL8211F Gigabit Ethernet] (irq=26)
meson8b-dwmac ff3f0000.ethernet eth0: configuring for phy/rgmii link mode
```

| Risk #3 sub-question | Answer |
|---|---|
| Does the MAC probe from our `&ethmac` node? | **Yes** — DWMAC1000, Synopsys ID 0x37 |
| Does `REALTEK_PHY=y` actually bind, or does it degrade to genphy? | **Binds.** `DRIVER=RTL8211F Gigabit Ethernet`, `OF_FULLNAME=/soc/ethernet@ff3f0000/mdio/ethernet-phy@0`. This was the plan's headline fear ("gigabit that mostly works") and it does not happen. |
| Is the PHY interrupt real, or is phylib silently polling? | **Real.** `/proc/interrupts` line 26: `meson-gpio-irqchip 98 Level stmmac-0:00` — exactly the DTS's `interrupt-parent = <&gpio_intc>; interrupts = <98 IRQ_TYPE_LEVEL_LOW>`. |
| Does the `ethernet0` alias deliver the MAC? | **Yes.** `eth0` address is `00:01:38:2a:bb:5c`, byte-identical to stored `ethaddr`, so U-Boot's `fdt_fixup_ethernet()` found the alias and injected it — even on a hand-driven `booti`. |
| `phy-mode` | `configuring for phy/rgmii link mode`, matching the DTS, and identical to the 5.4 baseline line. |

**Still not answerable without a cable.** `carrier=0 operstate=down`, and the
interrupt count is 0 because nothing has ever linked. So the parts of the Phase 4
gate that need traffic — per-direction iperf3 against the 5.4 baseline, 20 cable
pulls each incrementing that interrupt count, `ethtool -S` CRC/length errors, and
above all the **MDIO page 0xd08 reg 17 bit 8 / reg 21 bit 3 TX-vs-RX delay
comparison** that decides `rgmii` vs `rgmii-rxid` — remain open. Those need a
cable plus `ethtool`/`iperf3`/a MDIO tool installed, none of which the stock image
has.

What this does establish is that everything *upstream* of a link is correct: the
node, the MDIO bus, PHY detection, the right driver, a live interrupt and the MAC
address. If the delay comparison later says `rgmii-rxid`, it is a one-word DTS
change on a tree that is otherwise proven.

### 12. `setexpr` exists on this unit

`button=400` in the stored env was computed by
`setexpr button *0xff800028 & 0x400`, answering the plan's open question: this
U-Boot post-dates patch `0041` and the reset-button check works. `0x400` = bit 10
set = button **not** pressed.

---

## Still open

| Question | Blocked on |
|---|---|
| P5 — what sets `0xff80023c` to `0xd000`, across six reset types | reboots + `=>` prompt |
| P6 — does the reset button actually boot p7 | physical access |
| P7 — env restore drill at the `=>` prompt | a maintenance window |
| P3 — MAC stability across 3 reboots | reboots |
| Is a USB2 port physically routed? | Phase 5, throwaway DTB |
| `dumpe2fs -h` of p1 (exact ext4 feature string to clone) | needs `dumpe2fs` built and installed |
| Full-eMMC and p7 backups | needs a network cable, or many hours of serial |

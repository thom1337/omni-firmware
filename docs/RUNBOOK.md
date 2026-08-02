# RUNBOOK — Avast Omni Armbian migration

This is the operator's book. It assumes it is 02:00, you have a serial cable in
one hand, and the box is not answering. It tells you what to type, in what
order, what proves the step worked, and what to do when it did not.

* **The plan** — why any of this is being done, and the reasoning behind every
  constraint: [`docs/ARMBIAN-MIGRATION.md`](ARMBIAN-MIGRATION.md).
* **The measured truth about this device** — filled on the hardware, gates the
  whole project: [`docs/HARDWARE.md`](HARDWARE.md).
* **The device-tree port audit** — Phase 3 evidence:
  [`docs/dts-port-audit.md`](dts-port-audit.md).

If this book and the plan disagree, **the plan wins** and this book is wrong;
fix it.

---

## Contents

| § | |
|---|---|
| [0](#0-before-you-touch-anything) | Before you touch anything |
| [1](#1-serial-console) | Serial console |
| [2](#2-the-seven-rules) | The seven rules |
| [3](#3-if-you-brick-it) | **IF YOU BRICK IT** |
| [4](#phase-0--pre-flight) | Phase 0 — pre-flight |
| [5](#phase-1--first-ever-ab-execution) | Phase 1 — first-ever A/B execution |
| [6](#phase-2--armbian-kernel-factory) | Phase 2 — Armbian kernel factory |
| [7](#phase-3--author-the-dts) | Phase 3 — author the DTS |
| [8](#phase-4--gono-go-kernel-on-hardware) | Phase 4 — **GO/NO-GO**: kernel on hardware |
| [9](#phase-5--hardware-truth) | Phase 5 — hardware truth |
| [10](#phase-6--kernel-ci) | Phase 6 — kernel CI |
| [11](#phase-7--debian-rootfs--initramfs) | Phase 7 — Debian rootfs + initramfs |
| [12](#phase-8--gono-go-debian-on-slot-b) | Phase 8 — **GO/NO-GO**: Debian on slot B |
| [13](#phase-9--soak-then-mirror-to-slot-a) | Phase 9 — soak, then mirror to slot A |
| [A](#appendix-a--the-device-in-one-page) | Appendix A — the device in one page |
| [B](#appendix-b--u-boot-environment-reference) | Appendix B — U-Boot environment reference |
| [C](#appendix-c--tool-index) | Appendix C — tool index |

---

## 0. Before you touch anything

**Physical kit:**

* 3.3 V USB-TTL serial adapter (**3.3 V, not 5 V**) and jumper wires.
* A screwdriver — the console header is inside the case.
* A switched power strip or an inline switch. You will be power-cycling this
  device dozens of times, and "cold power cycle, mains removed ≥ 10 s" is a
  literal requirement in several tests, not a figure of speech.
* Ethernet to a switch you control, ideally with the port counters visible.
* A workstation on the same L2 for iperf3.

**State you must already have:**

* `docs/HARDWARE.md` filled in — see [Phase 0](#phase-0--pre-flight). Until
  `grep -n '<<UNFILLED>>' docs/HARDWARE.md | grep -v GATE-SELF-REF` prints
  nothing, **you are in Phase 0 whatever you think you are doing**.
* Verified backups, and a second copy of them somewhere else.
* `/data/omni-env-8k.bin` staged **on the device**.

**Conventions in this book:**

| Prompt | Where you are |
|---|---|
| `$` | your workstation |
| `#` | a root shell on the Omni (ssh or serial) |
| `=>` | the U-Boot prompt on the serial console |

---

## 1. Serial console

`ttyAML0`, **115200 8N1**, no flow control. It is the only out-of-band access
this box has.

```
$ picocom -b 115200 /dev/ttyUSB0
  # or
$ screen /dev/ttyUSB0 115200
  # or, if you want a transcript (you do — several gates require one)
$ picocom -b 115200 --logfile omni-$(date +%Y%m%d-%H%M%S).log /dev/ttyUSB0
```

Connect **GND, adapter-RX ← board-TX, adapter-TX → board-RX**. Do **not**
connect Vcc; the board is mains-powered and you will fight the regulator.

**Always keep a logfile.** "The serial console said something about bootlimit"
is not evidence; a transcript is.

### Getting a `=>` prompt

U-Boot only offers the autoboot prompt when `bootdelay >= 0`
(`common/autoboot.c:262` in v2018.09). A field unit almost certainly has
`bootdelay=-2` stored, because `mender_setup`'s first-boot `env default -a;
saveenv` persisted the compiled default. So:

```
# echo 0 > /sys/block/mmcblk0boot0/force_ro
# fw_setenv bootdelay 3
# echo 1 > /sys/block/mmcblk0boot0/force_ro
# reboot
```

Then hit any key during the countdown.

> **A failed `load` drops you to `=>` regardless of `bootdelay`.** A slot that
> fails to load is always recoverable. This is the single most reassuring fact
> in this document.

---

## 2. The seven rules

1. **Back up before the first `fw_setenv`, ever.** The environment is one
   non-redundant 8 KB copy at offset 0 of `/dev/mmcblk0boot0`. `ethaddr` exists
   nowhere else — `check_env`, the self-heal that would regenerate it, is dead
   code (`0031` replaces `bootcmd` with `CONFIG_MENDER_BOOTCOMMAND`, so it is
   never invoked). Lose it and `CONFIG_NET_RANDOM_ETHADDR` gives you a new MAC
   every boot, forever.

2. **Every environment write is wrapped in the `force_ro` dance.**
   ```sh
   echo 0 > /sys/block/mmcblk0boot0/force_ro
   fw_setenv ...
   echo 1 > /sys/block/mmcblk0boot0/force_ro
   ```
   The `tools/omni-*.sh` scripts and `/usr/lib/omni/omni-uboot-env.sh` do this
   for you and restore `force_ro` on any exit path. Hand-typed `fw_setenv` does
   not.

3. **Never `saveenv` at the `=>` prompt.** `MENDER_BOOTARGS` prepends
   `root=${mender_kernel_root}` to `${bootargs}` on every boot, so a saved
   `bootargs` accumulates a duplicate `root=` **permanently** — and `root=`
   last-occurrence wins, which means one slot's kernel booting against the
   other slot's rootfs.

4. **Keep the armed window short and never power-cycle inside it.** While
   `upgrade_available=1`, U-Boot itself calls `env_save()` on *every* boot
   (`CONFIG_BOOTCOUNT_ENV=y`), and `mender_altbootcmd` `saveenv`s again. Those
   are two more torn-write windows on a single-copy environment that batching
   cannot remove.

5. **A watchdog reset goes to p7, not to the other slot.** `check_watchdog`
   (`itest.w *0xff80023c -eq 0xd000`) runs *before* slot selection, and
   `altbootcmd` ends in `run bootcmd`, which re-evaluates it. Bootcount
   rollback cannot escape a latched register. Turn the watchdog **off** during
   any flash, and set `check_watchdog false` for the duration of the migration
   once [P5](HARDWARE.md#8-p5--the-watchdog-latch-at-0xff80023c-across-six-reset-types)
   says what it does on this unit.

6. **Cold power cycle between comparison boots — mains removed ≥ 10 s.** The
   RTL8211F has no reset line in the DTS, so its paged `0xd08` registers persist
   across a soft reboot. After a bad 6.x boot, 5.4 will look broken until you
   pull the plug, and you will chase the wrong bug for an hour.

7. **The `=>` prompt is free.** A boot driven entirely from the prompt writes
   nothing persistent — a power cycle undoes 100 % of it. Prefer it over any
   experiment that costs a bootcount attempt.

---

## 3. IF YOU BRICK IT

> Work **down** this list. Rank 1 is the most reliable thing you have.
> Do not skip to rank 4 because it sounds easier — it is the one that needs
> something to still be able to *reboot*.

### Rank 1 — the serial `=>` prompt

**Depends on:** `bootdelay >= 0`, **or** a failed `load` (which drops to `=>`
regardless of bootdelay — a slot that fails to load is *always* recoverable).

Boot the other slot by hand, persisting nothing:

```
=> ext4ls   mmc 0:1 /boot
=> ext4load mmc 0:1 0x08008000 /boot/meson-axg-apollo.dtb
=> ext4load mmc 0:1 0x08080000 /boot/Image
=> ext4load mmc 0:1 0x13000000 /boot/<value of mender_ramdisk_name>
=> setenv bootargs root=/dev/mmcblk0p1 rootwait rw console=ttyAML0 panic=10
=> booti 0x08080000 0x13000000:${filesize} 0x08008000
```

Change `0:1`/`mmcblk0p1` to `0:2`/`mmcblk0p2` for slot B, `0:7`/`mmcblk0p7` for
recovery. Substitute the **captured** artefact names from
[`HARDWARE.md` §6.1](HARDWARE.md#61-the-three-global-artefact-names--p4-capture-verbatim);
never type them from the patches.

**`${filesize}` is set by the LAST `ext4load`.** Load the ramdisk last, always.
Getting this wrong hands `booti` a garbage initrd length and the kernel panics
in a way that looks like a DTS problem.

Once you have a shell, fix the environment properly and reboot.

### Rank 2 — reset button → p7 recovery

**Depends on:** p7 being populated ([P6](HARDWARE.md#9-p6--is-p7-recovery-populated-and-bootable)),
and `setexpr` existing in the stored U-Boot
([§11](HARDWARE.md#11-does-the-stored-u-boot-have-setexpr)).

Hold the reset button (GPIOAO_10, active low) while applying mains, and keep
holding it until the console shows the recovery branch being taken. This
**overrides `mender_boot_part`** and needs no tools, no network and no login.

If `setexpr` is absent, the binary predates patch `0041` and **the button does
nothing**. If p7 is empty, there is nothing to boot into. Both are recorded in
`HARDWARE.md`; if you did not check, assume the worst.

### Rank 3 — `force_hard_recovery`

**Depends on:** a working Linux *now*, to arm it for later.

```
# echo 0 > /sys/block/mmcblk0boot0/force_ro
# fw_setenv force_hard_recovery 1
# echo 1 > /sys/block/mmcblk0boot0/force_ro
```

Same destination as rank 2, same precondition on p7, but armed in advance from
software. **Set it back to `0` from recovery**, or every subsequent boot goes to
p7 too.

### Rank 4 — `bootcount` / `bootlimit` auto-rollback

**Depends on:** something actually *rebooting* the box.

Today that works: `CONFIG_PANIC_TIMEOUT=15` is compiled into the 5.4 kernel
(`defconfig:336`) so a panicked kernel reboots by itself, `bootlimit=1` is
exceeded on the second armed boot, and `altbootcmd` flips the pointer. On
serial you will see:

```
Warning: Bootlimit (1) exceeded. Using altbootcmd.
```

Mainline defaults `PANIC_TIMEOUT` to **0 — hang forever**, and Armbian's stock
meson64 config leaves it unset. That is why `CONFIG_PANIC_TIMEOUT=15` and
`CONFIG_PANIC_ON_OOPS=y` are in the kernel-config delta and asserted by
`tools/check-kconfig-invariants.sh`, and why `panic=10` goes on the cmdline as
belt and braces.

Also: **neutralise `check_watchdog` during the migration** (`fw_setenv
check_watchdog false`), or a watchdog reset diverts to p7 instead of rolling
back, and rank 4 silently does not exist.

### Rank 5 — Amlogic USB boot

**Depends on:** a physically routed USB port — *unknown* until Phase 5.

USB ID `1b8e:c003`, driven with [pyamlboot](https://github.com/superna9999/pyamlboot)
using the `s400` profile (same SoC family). If
[`HARDWARE.md` §12](HARDWARE.md#12-usb--is-a-port-physically-routed) says the
port is not routed, this rank does not exist and rank 1 is your floor.

### The environment is corrupt (nothing boots, U-Boot complains about CRC)

```
=> ext4load mmc 0:3 0x08000000 /omni-env-8k.bin
=> mmc dev 0 1
=> mmc write 0x08000000 0 0x10
=> mmc dev 0 0
=> reset
```

`0x10` = 16 × 512-byte blocks = 8192 bytes = exactly the environment. `mmc dev 0
1` selects the `boot0` hardware partition; U-Boot has no `force_ro` equivalent,
so there is no unlock step.

**Do not run `env default -a; saveenv`.** It restores `force_run_mfc=1`, which
makes every boot go to p7 looking for an `apollo-mfc-initrd-image-*` that
nothing in this repository can build.

If `/data/omni-env-8k.bin` was never staged, your remaining options are tftp (if
U-Boot's network works and `ethaddr` survived) or USB boot. This is exactly why
[Phase 0](#phase-0--pre-flight) stages it.

### Decision table

| Symptom | Go to |
|---|---|
| `=>` prompt reachable | rank 1 |
| Kernel loads then panics, repeatedly | rank 1; if unattended, rank 4 will fire |
| `load` fails / file not found | you are already at `=>` — rank 1 |
| No serial output at all | rank 2, then rank 5 |
| Serial output stops in the bootloader with a CRC/env complaint | "environment is corrupt", above |
| Boots but no network and no login | rank 2 (p7) or rank 1 with `init=/bin/sh` appended to `bootargs` |
| Every boot lands in recovery | `check_watchdog` latched — read `md.w 0xff80023c 1` at `=>`, then rank 1 into a slot and `fw_setenv check_watchdog false` |

---

## Phase 0 — pre-flight

**Goal:** know the device. **Artefacts:** `docs/HARDWARE.md`, verified backups.
**Closes when:** P1–P8 all pass. **Rollback:** n/a — nothing is changed except
`bootdelay`, at the very end.

### Preconditions

* ssh key access to the device (`BatchMode=yes` must work — no password prompt).
* Enough local disk for a full eMMC image.
* Serial console physically attached and proven (§1).

### Commands, in order

```
# 0. Missing tools. The stock image ships e2fsprogs-mke2fs only, and none of the
#    Phase 4 gate tools. Build e2fsprogs-e2fsck, e2fsprogs-dumpe2fs, ethtool,
#    iperf3 and fio from the existing bitbake tree and dpkg -i them.
$ make all TARGET="e2fsprogs ethtool iperf3 fio"
$ scp build/tmp/deploy/deb/aarch64/*.deb root@omni:/tmp/
# dpkg -i /tmp/*.deb

# 1. BACKUP — before any fw_setenv. Nothing in this script writes to the device.
$ tools/omni-backup.sh root@omni --quiesce --outdir ./omni-backups
$ tools/omni-backup.sh root@omni --dry-run          # if you want to see it first

# 2. INVENTORY — read-only, evaluates P1..P4 and P8 automatically
$ scp tools/omni-preflight.sh root@omni:/tmp/
# /tmp/omni-preflight.sh --mount-debugfs --outdir /data/omni-preflight
$ scp -r root@omni:/data/omni-preflight/ ./

# 3. Stage the environment image ON the device, for rank-1 recovery
$ scp omni-backups/*/omni-env-8k.bin root@omni:/data/omni-env-8k.bin
# sync

# 4. Only now: regain the U-Boot prompt
# echo 0 > /sys/block/mmcblk0boot0/force_ro
# fw_setenv bootdelay 3
# echo 1 > /sys/block/mmcblk0boot0/force_ro
# reboot
```

Then the three gates that cannot be automated, each described step-by-step in
`HARDWARE.md`:

* **P5** — [six reset types, `md.w 0xff80023c 1`](HARDWARE.md#8-p5--the-watchdog-latch-at-0xff80023c-across-six-reset-types).
  Needs serial and a lot of power cycling. Budget an afternoon.
* **P6** — [reset-button cold boot into p7](HARDWARE.md#9-p6--is-p7-recovery-populated-and-bootable).
* **P7** — [the environment corrupt/restore drill](HARDWARE.md#10-p7--the-environment-restore-drill).
  Do this on a **bench** unit if you have one.

Finally, transcribe everything into `docs/HARDWARE.md` and commit it.

### Evidence that closes Phase 0

| Evidence | Where |
|---|---|
| `grep -n '<<UNFILLED>>' docs/HARDWARE.md \| grep -v GATE-SELF-REF` prints nothing | — |
| P1–P8 all `PASS` (or a written, reviewed waiver) | `HARDWARE.md` §14 |
| `omni-preflight.sh` exits `0` | its `SUMMARY.txt` |
| Full eMMC image md5 matches the device's own `md5sum /dev/mmcblk0` | `MD5-VERIFY.txt` |
| A `=>` prompt personally reached and a transcript kept | serial log |
| P7 restore drill completed **by you**, not read about | serial log |

### If it goes wrong

| Problem | Action |
|---|---|
| `force_run_mfc` or `force_run_eol` is `1` (P1 fail) | Set both to `0` and re-verify. `APOLLO_CHECK_MFC` runs *before* slot selection and forces p7. |
| `bootargs` is defined (P2 fail) | `fw_setenv bootargs` with no value deletes it. Do not try to "correct" its contents. |
| `ethaddr` missing (P3 fail) | Restore from `omni-env.txt`, the device label, or DHCP records. Do not proceed without it. |
| p7 empty (P6 fail) | Populate it with a copy of p1, or accept in writing that recovery is serial-only. |
| The environment write bricks it | You have not written one yet. That is the point of the ordering. |

---

## Phase 1 — first-ever A/B execution

**Goal:** prove the Mender contract actually works on this unit. Nothing about
A/B has *ever* run here — no Mender daemon is installed, so nothing ever set
`upgrade_available=1`. **Rollback:** restore the environment from
`omni-boot0.img`.

### Preconditions

* Phase 0 closed. Serial attached, transcript running.
* `bootdelay=3`, `=>` prompt reachable.
* You are on site or can power-cycle remotely.

### 1.1 The same-slot drill — bootcount and bootlimit, without moving the pointer

This is the safe version: it arms the slot you are **already running**, so the
only thing a failure changes is which slot the rollback lands on.

```
# tools/omni-arm.sh --same-slot --dry-run     # read this output before continuing
# tools/omni-arm.sh --same-slot
# fw_printenv mender_boot_part bootcount upgrade_available
    # expect: pointer unchanged, bootcount 0, upgrade_available 1
# reboot
```

After the reboot:

```
# fw_printenv bootcount
    # expect: 1     <- this proves CONFIG_BOOTCOUNT_ENV persists it
```

Now reboot **again without committing**:

```
# reboot
```

On serial you must see:

```
Warning: Bootlimit (1) exceeded. Using altbootcmd.
```

and the pointer must have flipped. Then put it back:

```
# fw_printenv mender_boot_part           # the OTHER slot now
# tools/omni-rollback.sh --to <original slot>
```

### 1.2 The commit path

```
# tools/omni-arm.sh --same-slot
# reboot
# tools/omni-commit.sh --dry-run
# tools/omni-commit.sh
# fw_printenv upgrade_available bootcount    # 0 and 0
```

`omni-commit.sh` refuses if the `root=` it parses out of `/proc/cmdline` (last
occurrence wins) does not resolve to the stored `mender_boot_part`. That refusal
is not overridable and it is the check that stops you blessing a slot you are
not actually running.

### 1.3 The T9 case — a failed load must drop to `=>`, not hang

```
# mkdir -p /mnt/b && mount /dev/mmcblk0p2 /mnt/b
# cp /mnt/b/boot/Image /mnt/b/boot/Image.bak        # keep it
# : > /mnt/b/boot/Image                             # truncate to zero
# umount /mnt/b
# tools/omni-arm.sh --slot 2 --no-check-boot        # --no-check-boot is required here
# reboot
```

Watch the console. The expected outcome is a `load` failure followed by a `=>`
prompt. A **hang** is a project-level finding: it means rank 1 recovery is
weaker than the plan assumes.

Recover with rank 1 (boot slot 1 by hand from `=>`), then restore
`/mnt/b/boot/Image` from the `.bak` and roll the pointer back.

### Evidence that closes Phase 1

| Evidence | How |
|---|---|
| `bootcount` reached `1` after one armed boot | `fw_printenv bootcount` |
| `Warning: Bootlimit (1) exceeded. Using altbootcmd.` on serial | transcript |
| Pointer flipped automatically at bootlimit | `fw_printenv mender_boot_part` |
| `omni-commit.sh` cleared `upgrade_available` and `bootcount` | `fw_printenv` |
| T9: a truncated `/boot/Image` produced a `=>` prompt, not a hang | transcript |
| `altbootcmd` and `bootlimit` genuinely exist in the **stored** env | `fw_printenv \| sort` |

### If it goes wrong

| Problem | Action |
|---|---|
| `bootcount` stays 0 across an armed boot | `CONFIG_BOOTCOUNT_ENV` is not doing what the patches claim. **Stop.** Auto-rollback (rank 4) does not exist on this unit and the whole plan needs re-costing. |
| `altbootcmd` undefined in the stored env | Same conclusion. Do not arm anything again until it is understood. |
| Box lands in p7 instead of the other slot | `check_watchdog` latched. Read `md.w 0xff80023c 1` at `=>` and revisit P5. |
| Environment looks damaged | Rank-1 restore from `/data/omni-env-8k.bin` (§3). |

---

## Phase 2 — Armbian kernel factory

**Goal:** prove the *build host*, not your DTS. **Rollback:** n/a — nothing
touches the device.

### Preconditions

* Docker, ~40 GB free, a decent network.
* `armbian/` submodule initialised and **pinned to a SHA**.

### Commands

```
$ git submodule update --init armbian
$ git -C armbian rev-parse HEAD          # record this SHA in the commit message
$ cd armbian
$ ./compile.sh kernel BOARD=gateway-gz80x BRANCH=oldlts
```

`gateway-gz80x` is Armbian's own worked `meson-axg` example. Building *it*
first separates "my host/toolchain is broken" from "my board files are broken",
which is worth the extra hour the first time.

### Evidence

Four `-meson64` `.deb`s in `armbian/output/debs/`:
`linux-image-*`, `linux-dtb-*`, `linux-headers-*`, `linux-libc-dev*`.

```
$ ls -la armbian/output/debs/*meson64*
$ tools/check-kconfig-invariants.sh armbian/output/debs/linux-image-*meson64*.deb
```

The invariants check will **fail** at this point — `CONFIG_REALTEK_PHY` is
absent from Armbian's stock meson64 config, which is the entire reason the
kernel-config delta exists. Seeing it fail here, for that reason, is the
evidence that the checker works.

### If it goes wrong

| Problem | Action |
|---|---|
| Build fails before touching the kernel | Host problem. Armbian's own docs; do not start editing board files. |
| Build succeeds but produces no debs | Check `BOOTCONFIG`; a board that builds U-Boot produces different artefacts. |
| `BRANCH=oldlts` produced something other than 6.12 | Armbian rolled the mapping forward. This is risk #8. Pin `KERNEL_MAJOR_MINOR` (Phase 3) and re-pin the submodule. |

---

## Phase 3 — author the DTS

**Goal:** one file replaces eight patches. **Rollback:** n/a.

### Preconditions

* Phase 2 green.
* `docs/HARDWARE.md` §6.1 captured — the DTB filename must match
  `mender_dtb_name` **as stored**, not as compiled.

### Commands

```
$ tools/validate-dts.sh --strict                      # fetches a sparse 6.12 tree on first run
$ tools/sync-armbian-board.sh --dry-run
$ tools/sync-armbian-board.sh
$ cd armbian && ./compile.sh dts-check BOARD=avast-omni BRANCH=oldlts
$ cd armbian && ./compile.sh kernel    BOARD=avast-omni BRANCH=oldlts
$ tools/check-kconfig-invariants.sh --strict armbian/output/debs/linux-image-*meson64*.deb
```

Then produce the audit evidence — the full procedure is
[`docs/dts-port-audit.md` §7](dts-port-audit.md#7-mandated-verification--producing-and-diffing-the-dtbs):

```
$ ssh root@omni 'cat /boot/meson-axg-apollo.dtb' > old-5.4.dtb
$ cp /tmp/dtsval/meson-axg-apollo.dtb new-6.12.dtb
$ # normalise with `dtc -I dtb -O dts -s`, strip phandles, diff the board-owned
$ # subtrees only — see the audit, §7.2 and §7.3
```

### Evidence that closes Phase 3

| Evidence | Where |
|---|---|
| `validate-dts.sh --strict` clean — exactly the 4 inherited dtsi warnings, none naming our file | its output |
| `./compile.sh dts-check` clean | Armbian log |
| Board-owned `dtc -I dtb -O dts` diff produced, and **every line maps to a row in the audit** | `docs/dts-port-audit.md` |
| `check-kconfig-invariants.sh --strict` passes | its output |
| `git -C armbian status --porcelain` shows only the synced `dt/` copies | — |

### If it goes wrong

| Problem | Action |
|---|---|
| A `dtc` warning names a line in `meson-axg-apollo.dts` | It is ours. Fix it — do not waive it. |
| The diff contains something not in the audit | Add a row **with a reason**, or revert. An unaudited DTS change is how Phase 4 fails mysteriously. |
| `check-kconfig-invariants.sh` fails on `OVERLAY_FS` | Armbian's `armbian-kernel.sh` forces it to `=m` *after* the config is copied in. That is what `board/post_family_config__avast-omni.sh` is for. |
| Sync overwrote something in `armbian/` | Expected — the sync is one-way and destructive on the target side. Never edit inside the submodule. |

---

## Phase 4 — GO/NO-GO: kernel on hardware

**This is a hard gate.** Boot **entirely from the `=>` prompt** — no
`fw_setenv`, no `saveenv`, no `mender_boot_part` change. **A power cycle undoes
100 % of it**, so a DTS iteration costs 30 seconds instead of a bootcount
attempt.

### Preconditions

* Phase 3 green; Phase 1 proved rollback works.
* Serial attached, transcript running. **Do not attempt this remotely.**
* Slot B (`p2`) is not the running root.
* Baseline numbers for 5.4 already recorded (`HARDWARE.md` §4) — you cannot
  collect a "before" after the fact.

### 4.1 Build slot B as a byte-clone of slot A

The two rootfs images must be **bit-identical** for this to be a true
single-variable comparison. The lower is mounted `rw` (`initrd-apollo/init:52`),
so quiesce and remount it read-only first. The lower's mount point is recorded
in [`HARDWARE.md` §5.3](HARDWARE.md#53-mounts--where-the-overlay-lower-actually-lives).

```
# systemctl stop docker.socket docker.service containerd.service syslog-ng.service
# sync
# mount -o remount,ro <lower mount point from HARDWARE.md §5.3>
# dd if=/dev/mmcblk0p1 of=/dev/mmcblk0p2 bs=4M iflag=fullblock conv=fsync status=progress
# sync; blockdev --flushbufs /dev/mmcblk0
# mount -o remount,rw <lower mount point>
```

Verify, then wipe slot B's overlay upper — **p6 for slot B**, `ROOT_PART_NO +
4`. Slot B has never been booted, so p6 may be uninitialised garbage; if it is
not wiped, whatever is in it lands on top of your test rootfs.

```
# cmp /dev/mmcblk0p1 /dev/mmcblk0p2 && echo "slots identical"
# mke2fs -q -t ext4 -F /dev/mmcblk0p6
```

### 4.2 Install the new kernel into slot B only

```
$ scp armbian/output/debs/linux-image-*meson64*.deb \
      armbian/output/debs/linux-dtb-*meson64*.deb root@omni:/tmp/
# mkdir -p /mnt/b && mount /dev/mmcblk0p2 /mnt/b
# dpkg-deb -x /tmp/linux-image-*.deb /tmp/ki && dpkg-deb -x /tmp/linux-dtb-*.deb /tmp/kd
# cp -f /tmp/ki/boot/vmlinuz-*            /mnt/b/boot/Image
# cp -f /tmp/kd/boot/dtb-*/amlogic/meson-axg-apollo.dtb /mnt/b/boot/meson-axg-apollo.dtb
# cp -a /tmp/ki/lib/modules/*             /mnt/b/lib/modules/
# sync; umount /mnt/b
```

Substitute the **captured** names from `HARDWARE.md` §6.1 if they differ from
`Image` / `meson-axg-apollo.dtb`.

> The initramfs in slot B is still the Yocto `.cpio.gz` from the clone. That is
> intentional — it keeps the variable count at one. It is a busybox initrd that
> mounts and switch_roots; it does not modprobe 5.4 modules. If it turns out to,
> that is a finding: record it and rebuild the initrd before continuing.

### 4.3 The boot sequence — verbatim from the plan

Interrupt autoboot, then:

```
ext4ls   mmc 0:2 /boot
ext4load mmc 0:2 0x08008000 /boot/meson-axg-apollo.dtb
ext4load mmc 0:2 0x08080000 /boot/Image
ext4load mmc 0:2 0x13000000 /boot/<value of mender_ramdisk_name>
setenv bootargs root=/dev/mmcblk0p2 rootwait rw console=ttyAML0 panic=10
booti 0x08080000 0x13000000:${filesize} 0x08008000
```

* **`setenv`, never `saveenv`.** See rule 3.
* **The ramdisk load is last** because `${filesize}` is set by the most recent
  `load`.
* A power cycle at any point puts you back exactly where you started.

### 4.4 The gate — all three must pass

**1. NIC.**

```
# ethtool eth0 | grep -E 'Speed|Duplex'          # 1000Mb/s, Full
# ethtool -S eth0 | grep -iE 'crc|length|error'  # all zero
# grep -i eth /proc/interrupts                   # note the gpio_intc line + count
```

* 30-minute bidirectional `iperf3`, run identically from 5.4 and from 6.12,
  **both numbers recorded**, 6.12 ≥ 5.4.
* **Compare each direction separately.** An RX-delay fault is asymmetric and TCP
  hides it in the aggregate.
* 20 cable pulls, each producing a link event **and** an incrementing count on
  the `gpio_intc` line in `/proc/interrupts`. A count stuck at 0 means the DTS
  interrupt is decorative and phylib is polling.
* **Every comparison boot is a cold power cycle, mains removed ≥ 10 s.**

**2. eMMC.**

```
# cat /sys/kernel/debug/mmc0/ios     # must match the 5.4 baseline: timing spec, clock, bus width
# fio --name=verify --filename=/dev/mmcblk0pX --direct=1 --verify=crc32c \
      --verify_fatal=1 --rw=randwrite --bs=64k --runtime=7200 --time_based
```

Use a **raw scratch partition** for fio — not a slot, not `/data` if `/data`
holds anything you want.

Then **50 consecutive warm `reboot` cycles**, each mounting root. This is the
only test that catches an `mmc-pwrseq-emmc` BOOT_9 pad-numbering error, which is
cold-boot-invisible. Every one of these 50 boots is driven from the `=>` prompt,
so none of them costs a bootcount.

**3. Recovery unregressed.**

```
# reboot                              # clean
=> md.w 0xff80023c 1                  # must NOT read 0xd000
```

and the reset button must still reach p7.

### Evidence that closes Phase 4

| Evidence | Form |
|---|---|
| Serial transcript of the `=>` boot to a login prompt | log file |
| `ethtool` 1000/full, zero CRC/length errors | pasted output |
| Per-direction iperf3 numbers, 5.4 vs 6.12, 30 min each | table |
| `gpio_intc` count incremented on all 20 cable pulls | `/proc/interrupts` before/after |
| `ios` matches the 5.4 baseline on timing spec, clock, bus width | side-by-side |
| 2 h fio with `--verify_fatal=1`, zero errors | fio output |
| 50/50 warm reboots mounted root | transcript |
| `md.w 0xff80023c 1` non-`0xd000` after a clean reboot | transcript |
| Reset button still reaches p7 | transcript |

### If it goes wrong

**Any failure: stop and fix the DTS. Do not proceed to userland.**

| Symptom | Likely cause |
|---|---|
| Link up but throughput bad in one direction only | RGMII delay. `phy-mode = "rgmii-rxid"` — see [audit §4.3](dts-port-audit.md#43-open-item--the-rgmii-delay). Compare MDIO `0xd08` regs 17/21 before changing anything. |
| Link up, throughput mediocre both ways, PHY shows as "Generic PHY" | `CONFIG_REALTEK_PHY` missing. |
| `/proc/interrupts` count stays 0 | PHY interrupt not wired; phylib is polling. Not fatal, but record it. |
| Root mounts on cold boot, intermittently fails on warm reboot | `mmc-pwrseq-emmc` BOOT_9. This is what test 2 exists for. |
| `ios` shows a slower timing spec than 5.4 | eMMC capability mismatch in the DTS, or the controller fell back. |
| Kernel panics, console fills, box hangs | You are at `=>` after `panic=10` + reboot, or you power-cycle. Nothing persistent was written. |
| Boot lands in p7 | `check_watchdog`. Read the register; revisit P5. |

**Rollback:** power cycle. That is the whole rollback. Nothing persistent was
written except slot B's contents and p6, both of which are the test area.

---

## Phase 5 — hardware truth

**Goal:** answer the open hardware questions on **throwaway** DTBs.
**Rollback:** per experiment — every one is a `=>` boot, so a power cycle.

Each experiment: build a modified DTB on the workstation, `scp` it into slot B's
`/boot` under a *different* name, and load that name explicitly at the `=>`
prompt. Never commit an experimental property to `board/meson-axg-apollo.dts`
before it has booted.

```
=> ext4load mmc 0:2 0x08008000 /boot/experiment-usb.dtb
```

| Experiment | What to change | What it answers | Record in |
|---|---|---|---|
| USB routing | `&usb { status = "okay"; };` + a known-good dongle | 2-NIC router vs router-on-a-stick; recovery rank 5 | `HARDWARE.md` §12 |
| RGMII delay | nothing — read MDIO page `0xd08` reg 17 bit 8 and reg 21 bit 3 on 5.4, then on 6.12 | final `phy-mode` | `HARDWARE.md` §13 |
| gpio-keys | already in the DTS | `cat /proc/bus/input/devices`; button press registers | `HARDWARE.md` §13 |
| thermal | already in the DTS | `cat /sys/class/thermal/thermal_zone0/{type,temp}`; does `scpi_sensors 0` exist? | `HARDWARE.md` §13 |
| pstore | already in the DTS | panic, reboot, `ls /sys/fs/pstore/` | `HARDWARE.md` §13 |
| PWM | already in the DTS | measured LED period ≈ 128 Hz | `HARDWARE.md` §13 |

Also during this phase, off the critical path: the qemu-aarch64 loopback dry-run
of the initramfs-tools port (risk #6), which costs nothing on hardware.

**Evidence:** every `<<DEFERRED:P5>>` in `docs/HARDWARE.md` replaced with a
measurement; the final production DTS committed with the `phy-mode` decision
made and the audit updated.

---

## Phase 6 — kernel CI

**Goal:** the same kernel, built by a machine. **Rollback:** n/a.

### Commands

```
$ git add .github/workflows/build-omni-kernel.yml
$ gh workflow run build-omni-kernel.yml
$ gh run download <id> -n omni-kernel-debs
```

The workflow must:

* check out the **pinned** `armbian/` submodule SHA;
* run `tools/sync-armbian-board.sh`;
* `./compile.sh kernel BOARD=avast-omni BRANCH=oldlts`;
* run `tools/check-kconfig-invariants.sh --strict` on the produced
  `linux-image-*.deb` and **fail the build** if it does not pass;
* run `tools/validate-dts.sh --strict`;
* upload the four `-meson64` debs plus the built DTB as artefacts.

### Evidence

A **CI-built** `Image` passes the Phase 4 gate **unchanged** — re-run §4.3 and
§4.4 with the artefact from CI, not from your laptop. If the two differ, you
have a reproducibility problem, and reproducibility is what CI is for.

### If it goes wrong

| Problem | Action |
|---|---|
| CI kernel differs from the local one | Compare `/proc/config.gz` and the `.deb` version strings. Usually a stale `userpatches/` in the local tree. |
| `BRANCH=oldlts` built a different kernel series in CI | Risk #8. `KERNEL_MAJOR_MINOR` pin is not taking effect — check the `post_family_config` extension is actually being loaded. |

---

## Phase 7 — Debian rootfs + initramfs

**Goal:** a slot image. **Rollback:** n/a — nothing goes near the device.

### Preconditions

* `HARDWARE.md` §3.1 filled: p1's exact feature string and block count.
* `HARDWARE.md` §6.1 filled and transcribed into
  `rootfs/overlay/etc/default/omni-boot`, with `OMNI_BOOT_VERIFIED="yes"`.
  **The build fails closed until you do this** — deliberately.

> **Set both spellings of the initrd name.** `/usr/lib/omni/omni-flatten` reads
> `OMNI_INITRD_NAME`; `tools/check-image-invariants.sh` looks for
> `OMNI_RAMDISK_NAME` (or `MENDER_RAMDISK_NAME`) and fails the image if it is
> absent; `tools/omni-preflight.sh` emits `OMNI_RAMDISK_NAME` in its
> `boot-names.env`. Put **both** keys in `/etc/default/omni-boot`, with the same
> value, until that is unified.

### Commands

```
$ rootfs/build-in-docker.sh --dry-run \
      --kernel-debs armbian/output/debs \
      --blocks-from omni-preflight/*/dumpe2fs-p1.txt
$ rootfs/build-in-docker.sh \
      --kernel-debs armbian/output/debs \
      --blocks-from omni-preflight/*/dumpe2fs-p1.txt
$ tools/check-image-invariants.sh rootfs/out/omni-slot.ext4.gz --strict
```

### Evidence

| Evidence | How |
|---|---|
| `check-image-invariants.sh --strict` passes | its output |
| `test ! -e /usr/bin/armbian-install` inside the image | part of the above |
| Filesystem features match p1 exactly (no `metadata_csum_seed`, no `orphan_file`) | `dumpe2fs -h` on the built image |
| Block count ≤ p2's | compare against `HARDWARE.md` §2.1 |
| qemu-aarch64 loopback boot reaches a login prompt on a merged overlay | qemu transcript |
| Serial autologin unit present and enabled | `check-image-invariants.sh` |
| `/boot` holds three **real files** (not symlinks) at the captured names | `check-image-invariants.sh` |

### If it goes wrong

| Problem | Action |
|---|---|
| Build refuses with `OMNI_BOOT_VERIFIED` | Correct. Capture the names from the device (P4) and set it. `--allow-unverified-boot-names` is for test images that must never be armed. |
| `metadata_csum_seed` / `orphan_file` present | e2fsprogs 1.47 defaults. This produces a filesystem U-Boot may refuse — an **unbootable slot**, not a build error. Fix the `-O` pin. |
| Image is bigger than p2 | Re-size with `--blocks`; never "it will probably fit". |
| qemu boot drops to an initramfs shell | The initramfs-tools port. Better here than on hardware — that is why this step exists. |

---

## Phase 8 — GO/NO-GO: Debian on slot B

**This is the second hard gate**, and unlike Phase 4 it writes persistent state.
**Rollback:** `mender_altbootcmd` → the Yocto slot A.

### Preconditions

* Phase 4 gate passed with a **CI-built** kernel.
* Phase 7 image built and verified.
* Serial attached, transcript running, **you are physically present**.
* `check_watchdog` neutralised for the duration
  (`fw_setenv check_watchdog false`) — otherwise a watchdog reset during the
  flash goes to p7, not to slot A.
* Slot A still Yocto, still known-good, still bootable.

### Commands

```
$ scp rootfs/out/omni-slot.ext4.gz root@omni:/data/
# tools/omni-flash.sh --dry-run \
      --image /data/omni-slot.ext4.gz \
      --sha256 $(cat omni-slot.ext4.sha256) \
      --size   $(cat omni-slot.ext4.size)
# tools/omni-flash.sh \
      --image /data/omni-slot.ext4.gz \
      --sha256 ... --size ... --no-reboot
# fw_printenv mender_boot_part upgrade_available bootcount
# reboot
```

`omni-flash.sh` does, in this order, refusing at every precondition:
quiesce (watchdog **off**, asserted; docker/containerd/syslog-ng stopped) →
`mkfs.ext4` on the target's overlay upper → `dd` the image → sha256 + `e2fsck
-fn` → **only then** the single batched environment write via `omni-arm.sh`.
A failure anywhere before that last step leaves `mender_boot_part` untouched.

> **Wiping the overlay upper is not optional.** p6 holds years-old Avast files
> from a previous life; on a fresh lower they reappear as a working system that
> behaves inexplicably. `--keep-overlay` exists only for deliberate forensics.

### On the new slot

```
# tools/omni-commit.sh --expect-slot 2
```

Do **not** commit until the gate below passes. The `omni-deadman.timer`
(`OnBootSec=15min`) reboots the box if `upgrade_available` is still `1` — that
timer is the only thing that will ever power-cycle a device in a closet, and it
is what turns a silent failure into an automatic rollback.

### The gate

Re-run the **entire Phase 4 gate** on Debian (NIC, eMMC, recovery), plus:

| Check | Command | Expected |
|---|---|---|
| Serial autologin works | watch the console | root shell, no password |
| MAC is stable and equals `ethaddr` | `ip link show`; `fw_printenv -n ethaddr` | identical across 3 cold boots |
| Interface name handled | `ip -br link` | `eth0` (via `.link`) or a `Name=e*` match that actually matched |
| cgroup v2 | `stat -fc %T /sys/fs/cgroup` | `cgroup2fs` |
| sshd reachable with the `/data` host keys | `ssh root@omni` from the workstation | no host-key change warning after a reboot |
| `/data` mounted, per-slot state relocated | `mount \| grep /data` | present |
| Rollback still armed | `fw_printenv bootcount upgrade_available` | as expected for the phase |

### If it goes wrong

| Symptom | Action |
|---|---|
| Box does not come back after the armed reboot | Wait for `bootlimit` (rank 4). If nothing happens in ~5 min, rank 1 on serial: boot slot 1 by hand. |
| Comes up, no network | Serial autologin (rule: harden SSH, never the console). Fix, or `tools/omni-rollback.sh --to 1`. |
| Comes up, no console **and** no network | Rank 2 (reset button → p7), then rank 1. This is risk #5 and the reason the deadman timer exists. |
| Lands in p7 | `check_watchdog` was not neutralised, or P5 was wrong. |
| Old Avast files present on a brand-new rootfs | The overlay upper was not wiped. `mkfs.ext4 -F /dev/mmcblk0p6` and reflash. |
| `armbian-install` exists in the image | Stop. It repartitions eMMC and rewrites bootloaders. CI asserts its absence for exactly this reason. |

**Rollback:** `tools/omni-rollback.sh --to 1` from the Debian slot, or rank 1
from serial. Slot A is untouched Yocto throughout Phase 8.

---

## Phase 9 — soak, then mirror to slot A

**Goal:** both slots Debian. **Rollback:** `omni-emmc-full.img.gz` — the full
Phase 0 image.

### The soak — 14 days

| Daily check | Command | Must be |
|---|---|---|
| Uptime | `uptime` | monotonically increasing |
| No pstore records | `ls /sys/fs/pstore/` | empty |
| No mmc errors | `dmesg \| grep -i mmc` | clean |
| No NIC errors | `ethtool -S eth0 \| grep -i err` | zero |
| Thermal sane | `cat /sys/class/thermal/thermal_zone0/temp` | below the 70 °C passive trip |
| Environment stable | `fw_printenv bootcount upgrade_available` | `0`, `0` |

### Then

1. Build the same image again and flash it to **slot A** with
   `tools/omni-flash.sh --slot 1`.
2. Perform **one full A→B→A update cycle by script**, with no manual steps.
3. Restore the watchdog: undo `check_watchdog false`, and confirm
   `RuntimeWatchdogSec=10` is carried forward on Debian — but only after
   [P5](HARDWARE.md#8-p5--the-watchdog-latch-at-0xff80023c-across-six-reset-types)
   is settled and the register behaviour is written down.
4. Restore `bootdelay` to whatever the policy is for shipped units (and write
   down what that is — a `bootdelay` of `-2` means no rank-1 recovery on a boot
   that *does* load).

### Evidence

14 days of the table above, plus a scripted A→B→A cycle with a serial
transcript, plus `tools/check-image-invariants.sh --rootfs / --skip machine-id`
run **on the live device**.

---

## Appendix A — the device in one page

| | |
|---|---|
| SoC | Amlogic A113D (`meson-axg`), quad Cortex-A53 |
| RAM | 512 MiB |
| Storage | eMMC — capacity in [`HARDWARE.md` §2](HARDWARE.md#2-emmc--capacity-and-geometry) |
| NIC | one RTL8211F, RGMII, gigabit. Needs `CONFIG_REALTEK_PHY` |
| Console | `ttyAML0`, 115200 8N1, inside the case |
| Display / wireless | none |
| Bootloader | vendor U-Boot 2018.09 + Mender A/B |
| Environment | **one non-redundant 8 KB copy** at offset 0 of `/dev/mmcblk0boot0` |

### Partitions

| Part | Role |
|---|---|
| `p1` | rootfs slot **A** |
| `p2` | rootfs slot **B** |
| `p3` | `/data` — shared, **not** A/B protected. A bad config here survives a rollback. |
| `p5` | overlay upper for slot A |
| `p6` | overlay upper for slot B |
| `p7` | recovery |

**Overlay upper = root partition + 4.** Anything written to `/etc` or `/var`
reverts to *that slot's stale state* on an A/B flip — which is why per-slot
state that must survive lives in `/data`, and why `/var/lib/dpkg`,
`/var/lib/apt`, `/etc/passwd` and `/etc/fstab` deliberately do **not**.

### Boot order (simplified, from the U-Boot patches)

```
APOLLO_CHECK_MFC            (force_run_mfc / force_run_eol)   -> p7
check_watchdog              (*0xff80023c == 0xd000)           -> p7
force_hard_recovery == 1                                      -> p7
reset button held (setexpr *0xff800028 & 0x400)               -> p7
mender_setup: select slot from mender_boot_part               -> p1 or p2
  bootcount++ ; if bootcount > bootlimit -> altbootcmd -> flip, run bootcmd
load /boot/${mender_kernel_name}, ${mender_dtb_name}, ${mender_ramdisk_name}
  ... from INSIDE the selected slot
```

**Recovery is checked ahead of A/B selection, and `altbootcmd` re-enters
`bootcmd`.** That is the single most important structural fact about this
device.

---

## Appendix B — U-Boot environment reference

| Variable | Meaning | Safe to change? |
|---|---|---|
| `mender_boot_part` | `1` or `2` — the active slot. `7` means you are in recovery. | via `omni-arm.sh` / `omni-rollback.sh` only |
| `mender_boot_part_hex` | same value in hex; **must be kept in sync** | same |
| `bootcount` | incremented by U-Boot on every armed boot | via the scripts |
| `bootlimit` | `1` — one armed boot, then `altbootcmd` | no |
| `upgrade_available` | `1` = armed (bootcount protection on), `0` = committed | via the scripts |
| `altbootcmd` | runs `mender_altbootcmd; run bootcmd` — flips the pointer, then **re-enters bootcmd** | no |
| `mender_kernel_name` | **global**, not per-slot. Capture verbatim. | no |
| `mender_dtb_name` | **global**. Renaming it bricks *both* slots. | no |
| `mender_ramdisk_name` | **global**. | no |
| `bootargs` | **must not be defined.** `root=` last occurrence wins. | delete only |
| `bootdelay` | `>= 0` to get a `=>` prompt; likely `-2` as stored | yes — `3` for the migration |
| `check_watchdog` | `itest.w *0xff80023c -eq 0xd000` → p7, **before** slot selection | `false` during the migration |
| `force_hard_recovery` | `1` → p7 on the next boot | yes — recovery rank 3 |
| `force_run_mfc` / `force_run_eol` | must both be `0`; compiled defaults are `1` | must be `0` |
| `ethaddr` | the only copy of this unit's MAC. | **never** |

Read: `fw_printenv | sort`. Write: always inside the `force_ro` dance
(rule 2), and prefer one batched `fw_setenv -s file` over several calls.

---

## Appendix C — tool index

Everything below has `--help`, and everything destructive has `--dry-run`.
**Read the `--dry-run` output before the real run.** Every one of these is
written to run *on the device* except `omni-backup.sh`, `sync-armbian-board.sh`,
`validate-dts.sh` and the `rootfs/` builders, which run on the workstation.

| Script | Runs on | What it does | Phase |
|---|---|---|---|
| `tools/omni-backup.sh` | workstation, over ssh | full backup: partition table, environment, both boot HW partitions, whole eMMC, md5-verified. **Writes nothing to the device.** | 0 |
| `tools/omni-preflight.sh` | device | read-only inventory; evaluates P1–P4, P8 automatically; emits `boot-names.env` and `SUMMARY.txt` | 0 |
| `tools/omni-arm.sh` | device | the Mender "install" env write: pointer, `bootcount=0`, `upgrade_available=1`. `--same-slot` is the Phase 1 drill. | 1, 8 |
| `tools/omni-commit.sh` | device | the "commit" write. Refuses if the running `root=` disagrees with `mender_boot_part`. | 1, 8 |
| `tools/omni-rollback.sh` | device | deliberate flip to the other slot, mirroring `mender_altbootcmd` exactly | 1, 8 |
| `tools/omni-flash.sh` | device | install + verify + arm a slot image, with the quiesce/watchdog-off dance and the overlay wipe | 8, 9 |
| `tools/omni-lib.sh` | device | shared helpers for the above; not run directly | — |
| `tools/sync-armbian-board.sh` | workstation | one-way sync of `board/` into the pinned `armbian/` submodule, including the kernel-config **merge** | 2, 3 |
| `tools/validate-dts.sh` | workstation | compile + decompile the DTS against a sparse mainline checkout; classifies dtc warnings | 3 |
| `tools/check-kconfig-invariants.sh` | workstation or CI | asserts the kernel-config delta on a `.config`, a `linux-image` deb, or `/proc/config.gz` | 3, 6 |
| `tools/check-image-invariants.sh` | workstation, CI, or device (`--rootfs /`) | asserts the rootfs/image invariants; read-only | 7, 9 |
| `rootfs/build-rootfs.sh` | workstation | mmdebstrap → ext4 slot image with a pinned feature set | 7 |
| `rootfs/build-in-docker.sh` | workstation | the same, containerised | 7 |

### Quickest useful commands

```
# where am I?
# fw_printenv mender_boot_part upgrade_available bootcount; cat /proc/cmdline

# is anything armed right now?
# fw_printenv upgrade_available          # 1 means a rollback is pending

# did the last boot come from recovery?
# fw_printenv mender_boot_part           # 7

# what will U-Boot try to load?
# fw_printenv mender_kernel_name mender_dtb_name mender_ramdisk_name
# ls -la /boot

# is the watchdog going to bite me during this maintenance?
# systemctl show -p RuntimeWatchdogUSec --value
```

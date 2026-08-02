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
| **P5** | `md.w 0xff80023c 1` across six reset types | ⏳ **NOT DONE** — needs repeated reboots and the `=>` prompt. |
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

### 8. `setexpr` exists on this unit

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

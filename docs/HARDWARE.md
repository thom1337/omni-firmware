# HARDWARE.md — Avast Omni, measured truth

> **THIS IS A TEMPLATE. IT IS NOT DATA.**
>
> Every field below marked `<<UNFILLED>>` is a value that **nobody currently <!-- GATE-SELF-REF -->
> knows**. The migration plan (`docs/ARMBIAN-MIGRATION.md`) treats each one as a
> gate, not as a nice-to-have. A guessed value here becomes a wrong `mke2fs`
> feature set, a wrong `mender_ramdisk_name`, or a rollback path that does not
> exist — none of which fail loudly, and all of which fail on a device in a
> closet that you cannot reach.
>
> **The project is not cleared to proceed past Phase 0 while any such marker
> remains.** The literal, mechanical gate is:
>
> ```sh
> grep -n '<<UNFILLED>>' docs/HARDWARE.md | grep -v GATE-SELF-REF   # must print NOTHING  (GATE-SELF-REF)
> ```
>
> (The `grep -v` drops the handful of lines in this document that *talk about*
> the marker rather than *being* one; they carry an invisible `GATE-SELF-REF`
> HTML comment for exactly that purpose.)
>
> Fields marked `<<DEFERRED:P5>>` are deliberately answered later, in Phase 5,
> on throwaway DTBs. They do **not** block Phase 1–4. Everything else does.
>
> Do not delete a field you could not measure. Replace it with
> `NOT-MEASURABLE: <reason>` and get that reason reviewed. "I skipped it" and
> "it cannot be measured" are different facts and only one of them is allowed.

---

## 0. Provenance

| Field | Value |
|---|---|
| Device / hostname | `<<UNFILLED>>` |
| Serial number / asset tag | `<<UNFILLED>>` |
| Hardware revision (silkscreen) | `<<UNFILLED>>` |
| Captured by | `<<UNFILLED>>` |
| Captured on (UTC) | `<<UNFILLED>>` |
| Firmware version (`cat /etc/version`) | `<<UNFILLED>>` |
| Kernel (`uname -a`) | `<<UNFILLED>>` |
| U-Boot version (`version` at `=>`) | `<<UNFILLED>>` |
| U-Boot build date (same output) | `<<UNFILLED>>` |
| Is this a field-returned unit or a bench unit? | `<<UNFILLED>>` |

A **bench** unit and a **field** unit are not interchangeable evidence. A field
unit's stored environment has been rewritten by `mender_setup`'s first-boot
`env default -a; saveenv`; a bench unit may still be carrying the compiled
defaults. If this is a bench unit, say so — every conclusion about the *stored*
environment (P1, P2, P3, P4, `setexpr`) then applies only to bench units and has
to be repeated on a field unit before Phase 8.

---

## How to fill this in

Almost all of section 1–7 is produced in one shot by the Phase 0 collector,
which is **read-only** — it writes nothing to the device and does not touch the
U-Boot environment:

```sh
# on the device (or: ssh root@omni 'sh -s' < tools/omni-preflight.sh)
./omni-preflight.sh --mount-debugfs --outdir /data/omni-preflight
```

It drops one file per item under `/data/omni-preflight/<timestamp>/`, plus
`SUMMARY.txt` (the P1–P8 table) and `boot-names.env` (the verbatim P4 capture).
Copy the values out of those files into this document. Keep the whole report
directory alongside the backups; this file is the human-readable index to it,
not a replacement for it.

**Order matters.** `tools/omni-backup.sh` runs *before* anything else, because
the first `fw_setenv` you ever run is the first chance to destroy the only copy
of `ethaddr`.

---

## 1. Backups — these exist before the first environment write

Produced by `tools/omni-backup.sh root@omni --quiesce` from the workstation.

| Artefact | Size (bytes) | sha256 (first 16) | Present? |
|---|---|---|---|
| `omni-ptable.sfdisk` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| `omni-env.txt` (the only copy of `ethaddr`) | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| `omni-env-8k.bin` (what you restore at `=>`) | 8192 | `<<UNFILLED>>` | `<<UNFILLED>>` |
| `omni-boot0.img` (all of `mmcblk0boot0`) | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| `omni-boot1.img` (all of `mmcblk0boot1`) | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| `omni-emmc-full.img.gz` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |

| Check | Result |
|---|---|
| `gzip -dc omni-emmc-full.img.gz \| md5sum` | `<<UNFILLED>>` |
| device's own `md5sum /dev/mmcblk0` | `<<UNFILLED>>` |
| **The two md5 values are identical** | `<<UNFILLED>>` (yes/no) |
| Backup directory (absolute path, on which machine) | `<<UNFILLED>>` |
| Second copy of the backup exists off that machine | `<<UNFILLED>>` (where) |
| `omni-env-8k.bin` **also staged on the device at `/data/omni-env-8k.bin`** | `<<UNFILLED>>` (yes/no) |

The last row is not bureaucracy. Recovery rank 1 is the serial `=>` prompt, and
the `=>` prompt can only restore an environment it can *read*. With no working
rootfs and no known-good USB port, `ext4load mmc 0:3 ... /omni-env-8k.bin` off
`/data` is the only in-band path back. Stage it now, while the box works.

---

## 2. eMMC — capacity and geometry

```sh
lsblk -b
blockdev --getsize64 /dev/mmcblk0
cat /proc/partitions
```

| Field | Command | Value |
|---|---|---|
| Total eMMC user-area capacity (bytes) | `blockdev --getsize64 /dev/mmcblk0` | `<<UNFILLED>>` |
| Same, in GiB | — | `<<UNFILLED>>` |
| `mmcblk0boot0` size (bytes) | `blockdev --getsize64 /dev/mmcblk0boot0` | `<<UNFILLED>>` |
| `mmcblk0boot1` size (bytes) | `blockdev --getsize64 /dev/mmcblk0boot1` | `<<UNFILLED>>` |
| eMMC CID name / manufacturer | `cat /sys/block/mmcblk0/device/{name,manfid,oemid,cid}` | `<<UNFILLED>>` |
| eMMC firmware rev | `cat /sys/block/mmcblk0/device/fwrev` | `<<UNFILLED>>` |
| eMMC spec version | `cat /sys/block/mmcblk0/device/rev` | `<<UNFILLED>>` |

The user-area capacity is one of the two open unknowns the plan calls out
explicitly. It decides whether a full `dd` backup is a 15-minute job or an
hour-long one, and whether staging a slot image on `/data` is possible at all.

### 2.1 Partition table

```sh
sfdisk -d /dev/mmcblk0
for p in 1 2 3 5 6 7; do
  printf 'p%-2s %s bytes\n' "$p" "$(blockdev --getsize64 /dev/mmcblk0p$p)"
done
```

Paste `sfdisk -d /dev/mmcblk0` **verbatim** here — it is the restore recipe:

```
<<UNFILLED>>
```

| Part | Role | Start (512 B sectors) | Sectors | Size (bytes) | Size (MiB) |
|---|---|---|---|---|---|
| p1 | rootfs slot **A** | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| p2 | rootfs slot **B** | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| p3 | `/data` (shared, **not** A/B protected) | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| p4 | extended container (if MBR) | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| p5 | overlay **upper for slot A** (= p1 + 4) | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| p6 | overlay **upper for slot B** (= p2 + 4) | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| p7 | recovery | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |

| Derived fact | Value |
|---|---|
| **p1 and p2 are the same size** (they must be — the slot image is built to one block count) | `<<UNFILLED>>` (yes/no) |
| If not equal: which is smaller, and by how much | `<<UNFILLED>>` |
| Unallocated space after the last partition (bytes) | `<<UNFILLED>>` |
| Partition table type (`dos`/`gpt`) | `<<UNFILLED>>` |

The slot image block count in `rootfs/build-rootfs.sh --blocks-from` is derived
from p1's filesystem, but it must also *fit* p2. If p1 > p2 the build must be
sized to p2 and this must be written down here in red.

---

## 3. Filesystems — the feature set the new image has to clone

```sh
for p in 1 2 3 5 6 7; do
  echo "=== /dev/mmcblk0p$p ==="
  dumpe2fs -h /dev/mmcblk0p$p 2>&1
done
```

> `dumpe2fs` is **not** on the stock image — `apollo-image.inc` installs
> `e2fsprogs-mke2fs` only. Build and `dpkg -i` `e2fsprogs-dumpe2fs` (and
> `e2fsprogs-e2fsck`) from the existing bitbake tree first, or run the whole
> inventory from a USB/recovery userland. Record which you did:
> `<<UNFILLED>>`

Per partition:

| Part | Has valid ext2/3/4 superblock? | Block size | Block count | Filesystem UUID | Volume label |
|---|---|---|---|---|---|
| p1 | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| p2 | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| p3 | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| p5 | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| p6 | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| p7 | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |

### 3.1 p1's feature string, verbatim

This single line is the input to the `mke2fs -O ...` pin in
`rootfs/build-rootfs.sh`. Debian trixie's e2fsprogs 1.47 turns on
`metadata_csum_seed` and `orphan_file` by default; the current image only works
because kirkstone shipped 1.46. Getting this wrong produces a slot U-Boot
cannot read — an unbootable device, not a build error.

```
Filesystem features:  <<UNFILLED>>
```

| Feature | Present on p1? | Notes |
|---|---|---|
| `64bit` | `<<UNFILLED>>` | plan pins `^64bit` |
| `metadata_csum` | `<<UNFILLED>>` | plan pins `^metadata_csum` |
| `metadata_csum_seed` | `<<UNFILLED>>` | new default in e2fsprogs 1.47 |
| `orphan_file` | `<<UNFILLED>>` | new default in e2fsprogs 1.47 |
| `has_journal` | `<<UNFILLED>>` | |
| `extent` | `<<UNFILLED>>` | |
| `huge_file` / `dir_nlink` / `extra_isize` | `<<UNFILLED>>` | |
| Anything else present that the pin above does **not** name | `<<UNFILLED>>` | |

| Field | Value |
|---|---|
| p1 `Reserved block count` / `Reserved GDT blocks` | `<<UNFILLED>>` |
| p1 `Inode count`, `Inode size` | `<<UNFILLED>>` |
| e2fsprogs version that created p1 (`dumpe2fs` header / `Filesystem created`) | `<<UNFILLED>>` |
| p3 free space (`df -k /data`) | `<<UNFILLED>>` |
| **Is p3 large enough for the intended Docker images?** | `<<UNFILLED>>` (yes/no + margin) |

---

## 4. eMMC bus baseline and wear

These two are the "a worn card looks exactly like a DTS bug" insurance. Capture
them on 5.4 **before** any new kernel touches the device, because after Phase 4
you can no longer prove what the baseline was.

```sh
mount -t debugfs none /sys/kernel/debug   # if not already mounted
cat /sys/kernel/debug/mmc0/ios
```

| `ios` field | 5.4 baseline value |
|---|---|
| `clock` | `<<UNFILLED>>` |
| `actual clock` | `<<UNFILLED>>` |
| `vdd` | `<<UNFILLED>>` |
| `bus mode` | `<<UNFILLED>>` |
| `chip select` | `<<UNFILLED>>` |
| `power mode` | `<<UNFILLED>>` |
| **`bus width`** | `<<UNFILLED>>` (expect `3 (8 bits)`) |
| **`timing spec`** | `<<UNFILLED>>` (expect `9 (mmc HS200)`) |
| `signal voltage` | `<<UNFILLED>>` (expect `1 (1.80 V)`) |
| `driver type` | `<<UNFILLED>>` |

Paste the raw file too, so a future reader is not trusting this transcription:

```
<<UNFILLED>>
```

### 4.1 Wear (`ext_csd`)

```sh
E=$(cat /sys/kernel/debug/mmc0/mmc0:0001/ext_csd)     # 1024 hex chars, byte N at 2N
b() { printf '%s\n' "${E:$((2*$1)):2}"; }             # bash; the device has bash 3.2
printf 'PRE_EOL_INFO      [267] = 0x%s\n' "$(b 267)"
printf 'LIFE_TIME_EST_A   [268] = 0x%s\n' "$(b 268)"
printf 'LIFE_TIME_EST_B   [269] = 0x%s\n' "$(b 269)"
printf 'BOOT_SIZE_MULT    [226] = 0x%s\n' "$(b 226)"  # x 128 KiB = boot0/boot1 size
```

| Field | Raw | Meaning |
|---|---|---|
| `PRE_EOL_INFO` [267] | `<<UNFILLED>>` | `0x01` Normal · `0x02` Warning (80 % of reserved blocks consumed) · `0x03` Urgent (90 %) |
| `DEVICE_LIFE_TIME_EST_TYP_A` [268] | `<<UNFILLED>>` | `0x01` = 0–10 % of life used … `0x0A` = 90–100 %, `0x0B` = exceeded |
| `DEVICE_LIFE_TIME_EST_TYP_B` [269] | `<<UNFILLED>>` | same scale, for the other cell type |
| `BOOT_SIZE_MULT` [226] | `<<UNFILLED>>` | boot0/boot1 size = value × 128 KiB |
| `PARTITION_CONFIG` [179] | `<<UNFILLED>>` | which hardware partition the ROM boots from |
| **Verdict** | `<<UNFILLED>>` | `PRE_EOL_INFO != 0x01` or life-time ≥ `0x05` ⇒ stop and discuss before writing 400 MB slots repeatedly |

Raw `ext_csd` (keep it — it is also the only record of the boot-partition
config if you ever have to rebuild one):

```
<<UNFILLED>>
```

---

## 5. Boot-time state of the running system

```sh
cat /proc/cmdline
ls -la /boot
mount
cat /proc/mounts
```

### 5.1 `/proc/cmdline`, verbatim

```
<<UNFILLED>>
```

| Derived | Value |
|---|---|
| Number of `root=` occurrences (last one wins) | `<<UNFILLED>>` |
| Effective `root=` | `<<UNFILLED>>` |
| Is `ro` present? (the plan says it is **not** — `rootwait rw`) | `<<UNFILLED>>` |
| Is `panic=` present? | `<<UNFILLED>>` |
| `console=` value | `<<UNFILLED>>` |

### 5.2 `/boot` of the running slot

```
<<UNFILLED>>          # paste `ls -la /boot`
```

| File | Present? | Size | Regular file or symlink? |
|---|---|---|---|
| `/boot/<mender_kernel_name>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| `/boot/<mender_dtb_name>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| `/boot/<mender_ramdisk_name>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |

### 5.3 Mounts — where the overlay lower actually lives

You need this exact path for the Phase 4 slot clone (`mount -o remount,ro` on
the lower before `dd`), and nothing in the repo tells you what it is at runtime.

| Field | Value |
|---|---|
| Mount point of `/dev/mmcblk0p<active>` (the overlay **lower**) | `<<UNFILLED>>` |
| Its mount options (expect `rw`) | `<<UNFILLED>>` |
| Mount point of `/dev/mmcblk0p<active+4>` (the overlay **upper**) | `<<UNFILLED>>` |
| Mount point of `/dev/mmcblk0p3` | `<<UNFILLED>>` |
| `/` filesystem type (expect `overlay`) | `<<UNFILLED>>` |
| Full `mount` output pasted below | `<<UNFILLED>>` |

```
<<UNFILLED>>
```

---

## 6. The stored U-Boot environment

```sh
fw_printenv | sort
```

> Reading is safe. **Writing** requires
> `echo 0 > /sys/block/mmcblk0boot0/force_ro` first and
> `echo 1 > ...` after, and it rewrites the single non-redundant 8 KB copy at
> offset 0 of `/dev/mmcblk0boot0`. Do not write anything until section 1 is
> complete and verified.

Full sorted dump (this is the authoritative record; the table below is a
convenience index into it):

```
<<UNFILLED>>
```

| Variable | Value as stored | Defined at all? |
|---|---|---|
| `mender_boot_part` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| `mender_boot_part_hex` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| `mender_uboot_dev` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| `bootcount` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| `bootlimit` | `<<UNFILLED>>` (expect `1`) | `<<UNFILLED>>` |
| `upgrade_available` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| `altbootcmd` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| `mender_altbootcmd` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| `bootcmd` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| `bootdelay` (before you change it) | `<<UNFILLED>>` (expect `-2`) | `<<UNFILLED>>` |
| `bootargs` | **must be UNDEFINED** — see P2 | `<<UNFILLED>>` |
| `check_watchdog` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| `force_hard_recovery` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| `force_run_mfc` | `<<UNFILLED>>` (must be `0`) | `<<UNFILLED>>` |
| `force_run_eol` | `<<UNFILLED>>` (must be `0`) | `<<UNFILLED>>` |
| `ethaddr` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| Environment size actually used / 8192 | `<<UNFILLED>>` | — |

### 6.1 The three GLOBAL artefact names — P4, capture verbatim

> **NEVER type these from the U-Boot patches.** A field binary may predate
> patches `0050`/`0051` and carry different strings. These names are *global*,
> not per-slot: both the Yocto slot and the Debian slot must expose real files
> at exactly these paths, or rollback stops being symmetric.

```sh
fw_printenv mender_kernel_name mender_dtb_name mender_ramdisk_name
```

Paste the command's output **byte for byte**, including any trailing
whitespace oddities:

```
<<UNFILLED>>
```

| Variable | Captured value | Matches the compiled default? |
|---|---|---|
| `mender_kernel_name` | `<<UNFILLED>>` | compiled default is `Image` — `<<UNFILLED>>` |
| `mender_dtb_name` | `<<UNFILLED>>` | compiled default is `meson-axg-apollo.dtb` — `<<UNFILLED>>` |
| `mender_ramdisk_name` | `<<UNFILLED>>` | compiled default is `apollo-initramfs-image-meson-apollo.cpio.gz` — `<<UNFILLED>>` |

These three go into `rootfs/overlay/etc/default/omni-boot`, and only then may
`OMNI_BOOT_VERIFIED` be flipped to `"yes"`:

| Field | Value |
|---|---|
| `rootfs/overlay/etc/default/omni-boot` updated from this capture | `<<UNFILLED>>` (yes/no) |
| `OMNI_BOOT_VERIFIED="yes"` set, with `OMNI_BOOT_CAPTURED_FROM` / `_AT` | `<<UNFILLED>>` |
| Both spellings written (`OMNI_INITRD_NAME` **and** `OMNI_RAMDISK_NAME`) — see the note in RUNBOOK Phase 7 | `<<UNFILLED>>` |

### 6.2 `ethaddr` and MAC stability — P3

`check_env`, the self-heal that would regenerate a lost `ethaddr`, is dead code:
patch `0031` replaces `bootcmd` with `CONFIG_MENDER_BOOTCOMMAND`, so `check_env`
is never invoked. Lose `ethaddr` and `CONFIG_NET_RANDOM_ETHADDR` hands out a new
MAC on every boot, forever.

| Field | Value |
|---|---|
| `ethaddr` from `fw_printenv` | `<<UNFILLED>>` |
| MAC on the running interface (`ip link show eth0`) | `<<UNFILLED>>` |
| They match | `<<UNFILLED>>` (yes/no) |
| MAC after cold reboot #1 | `<<UNFILLED>>` |
| MAC after cold reboot #2 | `<<UNFILLED>>` |
| MAC after cold reboot #3 | `<<UNFILLED>>` |
| **Stable across 3 reboots** | `<<UNFILLED>>` (yes/no) |
| DHCP reservation / switch port config keyed to this MAC (where) | `<<UNFILLED>>` |

---

## 7. Tool inventory on the stock image

The stock image ships `e2fsprogs-mke2fs` only, `coreutils` is pinned to 6.9, and
none of the Phase 4 gate tools are present. Anything missing has to be built
from the bitbake tree and `dpkg -i`'d before it is needed — not discovered
missing at 2 a.m.

| Tool | Present? | Version | Needed for |
|---|---|---|---|
| `fw_printenv` / `fw_setenv` | `<<UNFILLED>>` | `<<UNFILLED>>` | everything |
| `dd` supports `iflag=fullblock` | `<<UNFILLED>>` | — | flash without silent truncation |
| `dd` supports `conv=fsync` | `<<UNFILLED>>` | — | flash durability |
| `sha256sum` | `<<UNFILLED>>` | `<<UNFILLED>>` | image verification |
| `mke2fs` / `mkfs.ext4` | `<<UNFILLED>>` | `<<UNFILLED>>` | overlay upper wipe |
| `e2fsck` | `<<UNFILLED>>` | `<<UNFILLED>>` | post-write check |
| `dumpe2fs` | `<<UNFILLED>>` | `<<UNFILLED>>` | section 3 |
| `ethtool` | `<<UNFILLED>>` | `<<UNFILLED>>` | Phase 4 NIC gate |
| `iperf3` | `<<UNFILLED>>` | `<<UNFILLED>>` | Phase 4 NIC gate |
| `fio` | `<<UNFILLED>>` | `<<UNFILLED>>` | Phase 4 eMMC gate |
| `dtc` | `<<UNFILLED>>` | `<<UNFILLED>>` | Phase 3 DTB diff |
| `devmem2` / `busybox devmem` | `<<UNFILLED>>` | `<<UNFILLED>>` | reading `0xff80023c` from Linux |
| `sfdisk` | `<<UNFILLED>>` | `<<UNFILLED>>` | partition dump |
| `blockdev` | `<<UNFILLED>>` | `<<UNFILLED>>` | sizes |
| `curl` | `<<UNFILLED>>` | `<<UNFILLED>>` | streaming flash |
| `systemctl show -p RuntimeWatchdogUSec` works | `<<UNFILLED>>` | — | flash quiesce assertion |

| Field | Value |
|---|---|
| Packages built and installed to close the gaps above | `<<UNFILLED>>` |
| Where those `.deb`s are archived | `<<UNFILLED>>` |

---

## 8. P5 — the watchdog latch at `0xff80023c`, across six reset types

This is **the single most important measurement in Phase 0.** `check_watchdog`
is `itest.w *0xff80023c -eq 0xd000`, it runs *before* A/B slot selection, and
`altbootcmd` ends in `run bootcmd` — which re-evaluates it. If that register
latches on anything other than an actual watchdog bite, then **bootcount
rollback cannot escape recovery** and the entire risk model of this migration
changes.

### Method

Read the register from the U-Boot prompt, before `bootcmd` runs, so nothing has
had a chance to consume or clear it:

```
=> md.w 0xff80023c 1
```

Getting to `=>` requires `bootdelay >= 0` (section 6) and a keypress during the
autoboot countdown. Do **not** `saveenv` at the prompt for any reason.

Produce each reset type as follows:

| # | Reset type | How to produce it |
|---|---|---|
| 1 | Cold power-on after a clean shutdown | `poweroff`, wait for the console to stop, remove mains ≥ 10 s, reapply |
| 2 | Cold power **cut** while running | yank mains with the system idle at a shell, wait ≥ 10 s, reapply |
| 3 | U-Boot soft reset | at `=>`, type `reset` |
| 4 | Clean Linux reboot | `reboot` (full systemd shutdown, then PSCI `SYSTEM_RESET`) |
| 5 | Hard Linux reboot, no shutdown | `echo 1 > /proc/sys/kernel/sysrq; echo b > /proc/sysrq-trigger` |
| 6 | **Forced watchdog bite** | see below |

**Producing a real watchdog bite (#6).** `RuntimeWatchdogSec=10` is live, and
systemd holds `/dev/watchdog`, so you cannot simply stop pinging it from
userspace. Panic the kernel instead and let the hardware win the race:

```sh
# confirm the watchdog is armed first
systemctl show -p RuntimeWatchdogUSec --value      # expect 10s
echo 1 > /proc/sys/kernel/sysrq
echo c > /proc/sysrq-trigger                        # panic; systemd stops pinging
```

With `CONFIG_PANIC_TIMEOUT=15` compiled in and the watchdog at 10 s, the
watchdog expires ~5 s *before* the panic reboot would have fired. To be sure you
measured a watchdog reset and not a panic reset, run the same panic **twice**:

* once with `RuntimeWatchdogSec=0` (write
  `/run/systemd/system.conf.d/99-p5.conf`, `systemctl daemon-reexec`, assert
  `RuntimeWatchdogUSec` is `0`) → that is a **panic reboot**, record it as 5b;
* once with the watchdog armed → that is the **watchdog bite**, row 6.

Record the wall-clock delay from the panic message to the reboot: ~10 s means
the watchdog won, ~15 s means the panic timer won and row 6 is invalid.

### Results

| # | Reset type | `md.w 0xff80023c` | Latched (`0xd000`)? | Where did it boot? | Notes |
|---|---|---|---|---|---|
| 1 | Cold power-on (clean) | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| 2 | Cold power cut | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| 3 | `reset` at `=>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| 4 | Linux `reboot` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| 5 | sysrq-b hard reboot | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| 5b | Panic reboot (watchdog **off**) | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| 6 | **Watchdog bite** | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| c1 | *control:* reset button held on cold boot | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | expect p7 |
| c2 | *control:* `force_hard_recovery=1` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | expect p7 |

### The follow-on question that decides the risk model

| Question | Answer |
|---|---|
| After a confirmed latch (row 6), does the register still read `0xd000` on the **next** boot? | `<<UNFILLED>>` |
| If yes: what clears it — a cold power-on? a specific write? | `<<UNFILLED>>` |
| Does **any** of rows 1–5 latch it? | `<<UNFILLED>>` (a `yes` here is a project-level stop) |
| Conclusion in one sentence | `<<UNFILLED>>` |
| Decision: run the migration with `check_watchdog` set to `false`? | `<<UNFILLED>>` (yes/no + who decided) |

---

## 9. P6 — is p7 recovery populated and bootable?

If p7 is empty, recovery rank 2 and rank 3 both evaporate and the only
out-of-band path left is the serial prompt.

This repo now builds a Debian recovery image for p7 —
[`RUNBOOK.md` Appendix D](RUNBOOK.md#appendix-d--the-recovery-slot-p7). It does
**not** build `apollo-mfc-initrd-image-*`, so `force_run_mfc=1` is still fatal,
and writing that image over p7 destroys the factory MFC payload for good. Take
the whole-eMMC backup first; it is the only copy.

```sh
dumpe2fs -h /dev/mmcblk0p7
mkdir -p /mnt/p7 && mount -o ro /dev/mmcblk0p7 /mnt/p7 && ls -la /mnt/p7 /mnt/p7/boot
```

| Field | Value |
|---|---|
| p7 has a valid superblock | `<<UNFILLED>>` |
| p7 mounts read-only without error | `<<UNFILLED>>` |
| Contents of `/mnt/p7` (top level) | `<<UNFILLED>>` |
| Contents of `/mnt/p7/boot` | `<<UNFILLED>>` |
| p7 contains all three artefacts under the **captured** names from §6.1 | `<<UNFILLED>>` |
| Bytes used / total on p7 | `<<UNFILLED>>` |
| **Reset-button cold boot reaches a usable shell on p7** | `<<UNFILLED>>` (yes/no) |
| Serial transcript of that boot archived at | `<<UNFILLED>>` |
| Does the p7 shell have `fw_setenv`? | `<<UNFILLED>>` |
| Does the p7 shell see `/dev/mmcblk0p1..p7`? | `<<UNFILLED>>` |
| If p7 is empty: was it populated with a copy of p1? When, by whom? | `<<UNFILLED>>` |

**How to press the button:** it is GPIOAO_10, active low, read by U-Boot as a
raw register before Linux runs. Hold it while applying mains and keep holding
until the serial console shows the recovery path being taken.

---

## 10. P7 — the environment restore drill

Do not arm anything until you have *personally* restored a deliberately
corrupted environment from the `=>` prompt. A torn write to the single 8 KB copy
is unrecoverable in-band, and `env default -a; saveenv` restores
`force_run_mfc=1`, which wants a file this repo cannot build.

### Method (all at the `=>` prompt, with `/data/omni-env-8k.bin` staged per §1)

```
=> ext4load mmc 0:3 0x08000000 /omni-env-8k.bin
=> mmc dev 0 1
=> mmc write 0x08000000 0 0x10
=> mmc dev 0 0
=> reset
```

`0x10` = 16 × 512-byte blocks = 8192 bytes = exactly the environment. `mmc dev
0 1` selects the `boot0` hardware partition; U-Boot has no `force_ro`
equivalent, so no unlock step is needed there.

Corrupt it first, deliberately, from Linux:

```sh
echo 0 > /sys/block/mmcblk0boot0/force_ro
dd if=/dev/urandom of=/dev/mmcblk0boot0 bs=1 count=64 seek=0 conv=notrunc
echo 1 > /sys/block/mmcblk0boot0/force_ro
sync; reboot
```

| Field | Value |
|---|---|
| Corruption produced the expected U-Boot symptom (what did it print?) | `<<UNFILLED>>` |
| `ext4load` from p3 worked at `=>` | `<<UNFILLED>>` |
| `mmc write` completed, reported blocks written | `<<UNFILLED>>` |
| Box booted normally afterwards | `<<UNFILLED>>` |
| `fw_printenv \| sort` after restore is byte-identical to `omni-env.txt` | `<<UNFILLED>>` |
| `ethaddr` survived | `<<UNFILLED>>` |
| Total wall-clock time of the drill | `<<UNFILLED>>` |
| Serial transcript archived at | `<<UNFILLED>>` |
| Alternative path tested (tftp / usb / p7) | `<<UNFILLED>>` |

---

## 11. Does the stored U-Boot have `setexpr`?

If `setexpr` is absent, the binary predates patch `0041`, the reset-button check
`setexpr button *0xff800028 & 0x400` was never compiled in, **and the reset
button does nothing.** Recovery rank 2 disappears.

```
=> setexpr b *0xff800028 & 0x400
=> printenv b
=> md.l 0xff800028 1
```

| Field | Value |
|---|---|
| `setexpr` exists (no "Unknown command") | `<<UNFILLED>>` |
| `printenv b` with the button **released** | `<<UNFILLED>>` |
| `printenv b` with the button **held** | `<<UNFILLED>>` |
| Raw `md.l 0xff800028 1`, button released | `<<UNFILLED>>` |
| Raw `md.l 0xff800028 1`, button held | `<<UNFILLED>>` |
| Bit 0x400 changes state with the button | `<<UNFILLED>>` (yes/no) |
| `help` output at `=>` archived at | `<<UNFILLED>>` |
| Does `ext4load` exist? | `<<UNFILLED>>` |
| Does `ext4ls` exist? | `<<UNFILLED>>` |
| Does `booti` exist? | `<<UNFILLED>>` |
| Does `mmc write` exist? | `<<UNFILLED>>` |

The last four are not paranoia: the entire Phase 4 gate and the entire P7
restore drill are built out of exactly those commands. If any is missing, the
plan changes shape before a single line of DTS is written.

---

## 12. USB — is a port physically routed?

Answered for free in Phase 5 with a throwaway DTB (`&usb { status = "okay"; };`)
loaded from the `=>` prompt and a known-good dongle. It decides whether this box
can ever be a two-NIC router or is permanently router-on-a-stick, and it is
recovery rank 5 (Amlogic USB boot, `1b8e:c003`, pyamlboot `s400`).

| Field | Value |
|---|---|
| Is there a USB connector on the case? | `<<UNFILLED>>` |
| Are there USB pads/headers on the PCB (photo reference) | `<<UNFILLED>>` |
| `&usb` enabled on a throwaway DTB: does `dwc3`/`dwc2` probe? | `<<DEFERRED:P5>>` |
| Does a known-good USB-Ethernet dongle enumerate? | `<<DEFERRED:P5>>` |
| Does a USB mass-storage device enumerate? | `<<DEFERRED:P5>>` |
| Does the SoC enter USB boot mode (`lsusb` on the host shows `1b8e:c003`)? | `<<DEFERRED:P5>>` |
| Verdict: 2-NIC router possible? | `<<DEFERRED:P5>>` |
| Verdict: recovery rank 5 available? | `<<DEFERRED:P5>>` |

---

## 13. Other Phase 5 hardware truths

| Question | Answer |
|---|---|
| MDIO page `0xd08` reg 17 bit 8 (TX delay) on **5.4** | `<<DEFERRED:P5>>` |
| MDIO page `0xd08` reg 21 bit 3 (RX delay) on **5.4** | `<<DEFERRED:P5>>` |
| Same two registers on **6.12** with `phy-mode = "rgmii"` | `<<DEFERRED:P5>>` |
| Final `phy-mode` decision (`rgmii` vs `rgmii-rxid`) | `<<DEFERRED:P5>>` |
| `/proc/interrupts` line for the PHY `gpio_intc` IRQ, and does it increment on cable pulls? | `<<DEFERRED:P5>>` |
| Does `scpi_sensors 0` exist (`/sys/class/thermal/thermal_zone0/{type,temp}`)? | `<<DEFERRED:P5>>` |
| Idle SoC temperature | `<<DEFERRED:P5>>` |
| Temperature under 30 min of iperf3 + fio | `<<DEFERRED:P5>>` |
| Measured PWM period on the LED channels (128 Hz expected) | `<<DEFERRED:P5>>` |
| Does `pstore`/`ramoops` capture a panic across a reset at `0x0f400000`? | `<<DEFERRED:P5>>` |
| `mmc-pwrseq-emmc` BOOT_9: 50 warm reboots all mounted root | `<<DEFERRED:P5>>` |

---

## 14. P1–P8 gate results

This is the table that decides whether the project proceeds. `PASS` requires
*evidence*, not an opinion: a file in the Phase 0 report directory, a serial
transcript, or a pasted command output above.

| # | Check | Result | Evidence (file / §) | Who | When |
|---|---|---|---|---|---|
| **P1** | `force_run_mfc` and `force_run_eol` both `0` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| **P2** | `bootargs` is **not defined** in the stored env | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| **P3** | `ethaddr` non-empty; MAC stable over 3 reboots | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| **P4** | the three `mender_*_name` values captured verbatim | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| **P5** | `0xff80023c` characterised across six reset types | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| **P6** | reset-button cold boot reaches a usable shell on p7 | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| **P7** | env corrupt → restore drill completed at `=>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |
| **P8** | `dumpe2fs -h /dev/mmcblk0p2` shows a valid rootfs | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` | `<<UNFILLED>>` |

### Fail actions, restated so nobody has to go and look them up

| # | If it fails |
|---|---|
| P1 | Compiled defaults are `1`, and `APOLLO_CHECK_MFC` runs *before* slot selection and forces p7. Set them to `0` and re-verify **before** anything else. |
| P2 | A stale stored `bootargs` silently boots one slot's kernel against the other slot's rootfs (`root=` last occurrence wins). Delete the variable, do not "fix" it. |
| P3 | `check_env` is dead code. A lost `ethaddr` is lost forever and every boot gets a fresh random MAC. If it is already missing, restore it from `omni-env.txt` or from the label/DHCP records before continuing. |
| P4 | Do not proceed. Every downstream artefact name in `rootfs/` derives from this capture. |
| P5 | If a plain reboot or a power cut latches `0xd000`, every reboot goes to recovery, bootcount rollback cannot escape, and the plan's rollback story is wrong. Stop and re-plan. |
| P6 | Recovery is serial-only. Populate p7 with a copy of p1 before proceeding, or accept — explicitly, in writing — that a bad flash means opening the case. |
| P7 | If you cannot restore the environment without a working rootfs, **do not arm anything.** |
| P8 | Slot B has never been booted (nothing ever set `upgrade_available=1`; no Mender daemon is installed). It may be zeros. That is expected — but it must be *known*, because Phase 4 clones slot A onto it. |

---

## 15. Readiness sign-off

| Statement | Answer |
|---|---|
| The readiness grep at the top of this file prints nothing | `<<UNFILLED>>` |
| All eight of P1–P8 are `PASS` (or have a written, reviewed waiver) | `<<UNFILLED>>` |
| Waivers, if any, with the reviewer's name | `<<UNFILLED>>` |
| Backups verified by md5 against the device (§1) | `<<UNFILLED>>` |
| A second, off-machine copy of the backups exists | `<<UNFILLED>>` |
| `/data/omni-env-8k.bin` staged on the device | `<<UNFILLED>>` |
| `bootdelay` set to `3` and a `=>` prompt personally reached | `<<UNFILLED>>` |
| Serial console works, and the cable/adapter is stored **with** the device | `<<UNFILLED>>` |
| Phase 0 report directory archived at | `<<UNFILLED>>` |
| **Cleared to start Phase 1** — signed | `<<UNFILLED>>` |

> If you are reading this document to decide whether it is safe to do something
> and any field above is still an unfilled marker, the answer is no.

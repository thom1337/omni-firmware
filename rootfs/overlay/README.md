# `rootfs/overlay/` — files baked into the Debian slot image

Everything under this directory mirrors the target filesystem layout and is
copied verbatim into the mmdebstrap rootdir before `mke2fs -d` packs it into
`omni-slot.ext4`. Nothing here is installed at runtime, and nothing here is
generated — if a file is not in this tree, it is not in the image.

Authoritative spec: [`docs/ARMBIAN-MIGRATION.md`](../../docs/ARMBIAN-MIGRATION.md),
sections *Rootfs and initramfs* and *Flashing and rollback*.

---

## 1. Read this first: the per-slot state model

The root filesystem is an **overlayfs assembled in the initramfs**, not a plain
ext4 mount:

| Layer | Slot A | Slot B | Notes |
|---|---|---|---|
| lower (read-only) | `/dev/mmcblk0p1` | `/dev/mmcblk0p2` | the image this tree becomes |
| upper + work | `/dev/mmcblk0p5` | `/dev/mmcblk0p6` | `upper` = lower partition **+ 4** |
| merged | `/` | `/` | what userspace sees |

Consequences that decide every design choice in this directory:

1. **Every write to `/` lands in that slot's upper.** Flip A→B and you are
   looking at slot B's *stale* upper — whatever was written the last time slot B
   ran, possibly years ago. This is why the flasher runs `mkfs.ext4 -F` on the
   inactive upper before writing a slot (migration risk #7).
2. **U-Boot reads `/boot` from the LOWER, not the merged view.** Installing a
   kernel with `apt` on a running unit writes `/boot/Image` into p5/p6, which
   U-Boot never looks at. `/usr/lib/omni/omni-flatten` prints a loud warning when
   it detects an overlay root for exactly this reason. Kernels ship *inside* the
   image.
3. **The lower is remounted read-only before it becomes a `lowerdir`.** The
   stored U-Boot `CONFIG_BOOTARGS` is `rootwait rw console=ttyAML0` — no `ro` —
   so initramfs-tools mounts the slot read-write. Without the remount, the
   "immutable" slot is dirtied on every boot and the two slots stop being
   byte-comparable, which is the whole basis of the Phase 4 single-variable test.

The pristine lower and the raw upper are moved into the running system for
diagnostics:

```
/mnt/omni/lower    the slot's ext4, read-only, exactly as U-Boot sees it
/mnt/omni/upper    the raw overlay partition; contains upper/ and work/
```

Do **not** write to `/mnt/omni/upper/upper` directly — overlayfs does not expect
its upper to change underneath it, and the results are undefined.

`/run/omni/slot.env` is written by the initramfs before `switch_root` and is the
authoritative answer to "which slot am I running from?" (`findmnt -no SOURCE /`
just says `overlay`).

---

## 2. The `/data` relocation table

`/data` is `/dev/mmcblk0p3`: **one partition, shared by both slots.**

> ### ⚠ NOTHING IN `/data` IS A/B PROTECTED
>
> A rollback restores the rootfs slot. It does not restore `/data`. A bad config,
> a corrupt database or a runaway log written to `/data` **survives the
> rollback** and will break the "known-good" slot you just rolled back into.
>
> Rollback is your safety net for *the image*. It is not a safety net for
> anything you put on `/data`. Treat `/data` writes with the same care you would
> treat writes to a production database with no backups — because that is what
> they are.

### Moves to `/data` (shared, survives a flip, **not** protected)

| Item | Mechanism | File in this tree |
|---|---|---|
| Docker images/containers | `"data-root": "/data/docker"` | `etc/docker/daemon.json` |
| containerd content store | `root = "/data/containerd"` | `etc/containerd/config.toml` |
| sshd host keys | `HostKey /data/ssh/…` (with `/etc/ssh` fallback) | `etc/ssh/sshd_config.d/10-omni.conf`, `usr/lib/omni/omni-ssh-hostkeys` |
| SSH authorized keys | second `AuthorizedKeysFile` entry | `etc/ssh/sshd_config.d/10-omni.conf` |
| directory skeleton + modes | tmpfiles | `etc/tmpfiles.d/omni-data.conf` |
| `/root/.ssh`, `/etc/wireguard` | symlinks baked into the image | **not yet added** — see *Deliberately not here* |

Rationale in each case is the same: the data is large, or it is an identity that
must not change when the slot pointer flips. Everything else stays per-slot.

### Stays **per-slot**, never share it

| Item | Why sharing corrupts |
|---|---|
| `/var/lib/dpkg` | the package database describes *this* slot's filesystem. Share it and the first `apt` run on one slot tells the other slot that files exist which it does not have. Unrecoverable on first divergence. |
| `/var/lib/apt` | lists/state keyed to the same dpkg database; same failure, one step removed. |
| `/etc/passwd` (and `shadow`, `group`, `gshadow`) | UIDs are allocated per install. A shared passwd against unshared `/var/lib/dpkg` gives you files owned by a user the other slot has never heard of. |
| `/etc/fstab` | the slots have **different** lower/upper devices. A shared fstab is a shared wrong answer. |
| `/etc/machine-id` | initramfs seed only — systemd PID1 overmounts it before any unit runs. Note systemd-networkd derives its DHCP DUID from it, which is why `etc/systemd/network/20-eth.network` sets `ClientIdentifier=mac` instead. |
| `/etc/ssh/ssh_host_*` | kept as the *fallback* only; the persistent pair lives on `/data`. |

### The bootable minimum lives in the image

An address on the interface and a running sshd are in **this tree**, per slot.
Do **not** reproduce the Yocto firmware's
`/etc/systemd/network/00-eth0.network → /data/…` symlink
(`repo/meta-apollo/recipes-core/systemd-apollo/systemd_%.bbappend:30`). If `/data`
is unmounted or corrupt, the box must still come up with an address; otherwise a
`/data` problem becomes a network problem becomes a truck roll.

---

## 3. What is in this tree

### Boot artefacts

| Path | Purpose |
|---|---|
| `etc/default/omni-boot` | the three U-Boot artefact names. **Ships with compiled defaults and `OMNI_BOOT_VERIFIED=no`; Phase 0 check P4 must overwrite it from the device's `fw_printenv`.** |
| `etc/fw_env.config` | where `fw_printenv`/`fw_setenv` find the single non-redundant 8 KB env at offset 0 of `/dev/mmcblk0boot0`. |
| `usr/lib/omni/omni-flatten` | shared implementation: `cp -f` (never `ln`) the real `vmlinuz-<ver>`, `dtb-<ver>/amlogic/meson-axg-apollo.dtb` and `initrd.img-<ver>` onto the fixed names. Verifies the arm64 `Image` magic and the FDT magic before installing. |
| `etc/kernel/postinst.d/zz-omni-flatten` | Debian kernel hook (`$1`=version, `$2`=image). `zz-` so it runs *after* `initramfs-tools`. |
| `etc/initramfs/post-update.d/99-omni-flatten` | initramfs-tools hook (`$1`=version, `$2`=initrd path); fires on every `update-initramfs -u`. |

### Initramfs

| Path | Purpose |
|---|---|
| `etc/initramfs-tools/scripts/local-bottom/omni-overlay` | the overlay-root init. Port of the Yocto `initrd-apollo/init` with the three mandated fixes (`readlink -f "$ROOT"`, `remount,ro` the lower, `panic` on every failure). |
| `etc/initramfs-tools/initramfs.conf` | `MODULES=list`, `BUSYBOX=y`, `COMPRESS=gzip`, `FSTYPE=ext4`, `RESUME=none`. |
| `etc/initramfs-tools/conf.d/zz-omni-root` | `ROOTFSTYPE=ext4` — see the note below. |
| `etc/initramfs-tools/modules` | meson mmc, `pwrseq_emmc`, ext4, overlay, realtek PHY, stmmac. |

> **Why `ROOTFSTYPE` is not in `initramfs.conf`.**
> `ROOTFSTYPE` is not an `initramfs.conf(5)` variable. It is a `/init` runtime
> variable, exported empty at `init:62` and normally filled from the
> `rootfstype=` kernel parameter at `init:116`. It *happens* to work if set in
> `initramfs.conf`, because `/init` sources `/conf/initramfs.conf` before it
> parses `/proc/cmdline` — but that is an undocumented side effect of a dpkg
> **conffile**, which prompts on every `initramfs-tools` upgrade.
> The documented, upgrade-safe home for runtime variables is
> `/etc/initramfs-tools/conf.d/*`, which `mkinitramfs` copies to `/conf/conf.d/`
> and `/init` sources *after* `initramfs.conf`. Hence
> `etc/initramfs-tools/conf.d/zz-omni-root`. The `zz-` prefix matters: the loop
> is alphabetical and Debian's own tooling writes `conf.d/resume`.
> We cannot pass `rootfstype=` on the command line — that would mean writing the
> U-Boot environment, which this migration never does.
> `FSTYPE=ext4` in `initramfs.conf` is a **different** knob: it is build-time
> only, consumed by `hooks/fsck` to decide which `fsck.<type>` to copy in. With
> no `/` line in `/etc/fstab` (correct for an overlay root), `FSTYPE=auto` would
> find nothing and ship no fsck at all.

### System configuration

| Path | Purpose |
|---|---|
| `etc/fstab` | `/data` (p3, `nofail`), tmpfs `/var/log`, `/tmp`, `/var/tmp`. **No `/` line** (overlay root) and **no cgroup-v1 line** — the Yocto `fstab-logs:8` tmpfs hack simply does not exist here. |
| `etc/systemd/system.conf.d/10-omni-watchdog.conf` | `RuntimeWatchdogSec=10`, carried forward from Yocto. **Only safe after P5.** |
| `etc/systemd/journald.conf.d/10-omni.conf` | `Storage=volatile`, 16 MB cap, warnings mirrored to `ttyAML0`. |
| `etc/systemd/network/20-eth.network` | DHCP + fallbacks, matching `Name=e*` (the NIC enumerates as `end0`, not `eth0`). |
| `etc/systemd/system/serial-getty@ttyAML0.service.d/autologin.conf` | `--autologin root`. Preserves today's passwordless serial console. |
| `etc/ssh/sshd_config.d/10-omni.conf` | keys only, `/data` host keys with `/etc` fallback. |
| `etc/tmpfiles.d/omni-data.conf` | `/data` directory skeleton and modes. |
| `etc/docker/daemon.json` | `/data/docker`, `native.cgroupdriver=systemd`, 4 MB × 3 log rotation. |
| `etc/containerd/config.toml` | `root = "/data/containerd"`. |

### A/B commit and rollback

| Path | Purpose |
|---|---|
| `usr/lib/omni/omni-uboot-env.sh` | sourced library: tool checks, `force_ro` handling derived from `fw_env.config`, read-back assertions, slot detection. |
| `usr/lib/omni/omni-commit` | commits the slot **only** on carrier + default route + a completed outbound TCP connect, in a bounded retry loop. Refuses on a recovery boot or a slot/pointer mismatch. |
| `etc/systemd/system/omni-commit.service` | ordering only in `After=`; the evidence is re-proved in the script. |
| `usr/lib/omni/omni-deadman` + `omni-deadman.service`/`.timer` | `OnBootSec=15min`; reboots if `upgrade_available` is still `1`. |

**Timing invariant, do not break it:**

```
omni-commit tries × interval  (50 × 10 s = 500 s)
    <  omni-commit TimeoutStartSec   (700 s)
    <  omni-deadman OnBootSec        (900 s)
```

Push the commit window past the deadman and the box reboots a slot that was
about to succeed. Shrink it too far and a slow DHCP server costs you the slot.

### Unit enablement

Enablement symlinks are shipped in the tree so the image does not need a
`systemctl enable` pass inside a chroot:

```
etc/systemd/system/multi-user.target.wants/omni-commit.service
etc/systemd/system/multi-user.target.wants/omni-ssh-hostkeys.service
etc/systemd/system/timers.target.wants/omni-deadman.timer
etc/systemd/system/getty.target.wants/serial-getty@ttyAML0.service
```

`omni-deadman.service` is intentionally **not** in any `.wants` — only the timer
starts it. The serial getty is normally instantiated by
`systemd-getty-generator` from `console=ttyAML0`; the static symlink is
belt-and-braces so a `console=` change cannot silently take the console away.

---

## 4. File modes the build script must apply

Git preserves only the executable bit, and mmdebstrap/`mke2fs -d` copies what it
is given. The build script must set these explicitly:

**Mode `0755` (executable):**

```
etc/kernel/postinst.d/zz-omni-flatten
etc/initramfs/post-update.d/99-omni-flatten
etc/initramfs-tools/scripts/local-bottom/omni-overlay
usr/lib/omni/omni-flatten
usr/lib/omni/omni-commit
usr/lib/omni/omni-deadman
usr/lib/omni/omni-ssh-hostkeys
```

An initramfs-tools script that is not executable is silently skipped by
`mkinitramfs` — the image builds, the slot boots, and `/` is the bare lower
mounted read-write. Assert the bit in CI.

**Mode `0644`, owner `root:root` (everything else),** including
`usr/lib/omni/omni-uboot-env.sh` (it is sourced, not executed).

**Mode `0600`:** nothing in this tree. `/data/ssh` gets `0700` from
`etc/tmpfiles.d/omni-data.conf` at runtime.

All files must end up `root:root`; pass `-E root_owner=0:0` to `mke2fs` as the
plan already specifies.

---

## 5. Deliberately not here

* **`/root/.ssh` and `/etc/wireguard` symlinks into `/data`.** The plan lists
  them. They are not shipped yet because a dangling symlink when `/data` fails
  to mount is a worse failure than per-slot state, and the `/data`-side
  `AuthorizedKeysFile` entry already covers SSH access surviving a flip. Add them
  once `/data` reliability is characterised, with the same `nofail` mindset.
* **`/etc/machine-id`.** Must be absent or empty in the image so systemd
  generates one on first boot. Do not ship a fixed one: every unit would share a
  DUID, and `20-eth.network` deliberately does not depend on it.
* **Kernel, DTB, initrd.** Installed into the rootdir by the mmdebstrap
  customize-hook from the Phase 6 debs; the hooks in this tree then flatten them.
* **`syslog-ng`, `/etc/resolv.conf`, `10-enable_rps.conf`.** Yocto-isms not
  carried forward. `resolv.conf` is `systemd-resolved`'s; the RPS tmpfiles rule
  hardcoded `.../net/eth0/...` and would break on the `end0` rename for a benefit
  a single-queue NIC does not need.
* **`armbian-bsp-cli` / `armbian-install`.** Structurally excluded by building
  with mmdebstrap. CI asserts `test ! -e /usr/bin/armbian-install`.

---

## 6. CI assertions this tree expects

```sh
# The three artefact names were captured from the device, not typed from patches
grep -q '^OMNI_BOOT_VERIFIED="yes"' "$ROOT/etc/default/omni-boot"

# Serial console survives
systemd-analyze --root "$ROOT" cat-config \
    systemd/system/serial-getty@ttyAML0.service | grep -q -- '--autologin root'

# No cgroup v1, no "/" line
! grep -q 'cgroup' "$ROOT/etc/fstab"
! grep -qE '^[^#]*[[:space:]]/[[:space:]]' "$ROOT/etc/fstab"

# Hooks and initramfs scripts are executable
for f in etc/kernel/postinst.d/zz-omni-flatten \
         etc/initramfs/post-update.d/99-omni-flatten \
         etc/initramfs-tools/scripts/local-bottom/omni-overlay \
         usr/lib/omni/omni-flatten usr/lib/omni/omni-commit \
         usr/lib/omni/omni-deadman usr/lib/omni/omni-ssh-hostkeys; do
    test -x "$ROOT/$f" || { echo "NOT EXECUTABLE: $f"; exit 1; }
done

# MODULES=list, never dep
grep -qx 'MODULES=list' "$ROOT/etc/initramfs-tools/initramfs.conf"

# The commit guard is not built on After=network-online.target alone
grep -q 'omni-commit' "$ROOT/etc/systemd/system/omni-commit.service"
grep -q 'ExecStart=/usr/lib/omni/omni-commit' "$ROOT/etc/systemd/system/omni-commit.service"

# Armbian's installer is structurally absent
test ! -e "$ROOT/usr/bin/armbian-install"
```

On the running device, after Phase 8:

```sh
stat -fc %T /sys/fs/cgroup            # must be cgroup2fs
findmnt -no FSTYPE /                  # must be overlay
findmnt -no OPTIONS /mnt/omni/lower   # must contain ro
cat /run/omni/slot.env                # must name the slot you think you booted
omni-commit --status                  # upgrade_available, bootcount, running part
```

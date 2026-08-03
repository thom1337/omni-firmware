# Avast Omni firmware

Debian trixie on a mainline LTS kernel, built with Armbian as a kernel factory,
shipped as a Mender A/B slot image. This is the firmware.

It replaced a Yocto (kirkstone) build producing `apollo-image` on kernel
5.4.62. That kernel went EOL in December 2025, the image had no WireGuard and no
nftables, and it mounted cgroup v1 through a tmpfs `fstab` hack that systemd
≥ 256 refuses to boot on. The migration is complete and the Yocto tree has been
removed — see *[The Yocto tree](#the-yocto-tree)* for what that does and does
not mean.

The vendor U-Boot 2018.09 and its Mender A/B contract were **never touched**.
The bootloader loads the kernel, DTB and initramfs from `/boot` *inside the
selected A/B rootfs slot*, so a new kernel ships atomically with its rootfs and
no bootloader is ever reflashed.

---

## The Yocto tree

`repo/`, `Dockerfile`, `Makefile`, `scripts/` and
`.github/workflows/build-apollo-image.yml` were deleted once Debian was running
and committed on hardware. Two things follow, and they are different:

* **The build is gone.** Nothing in this repository can produce an
  `apollo-image` any more. To read or rebuild it, check out the last commit
  that contained it:

  ```
  git show 0e0f8bc:repo/meta-apollo/conf/machine/meson-apollo.conf   # read one file
  git checkout 0e0f8bc -- repo Dockerfile Makefile scripts           # restore the tree
  ```

* **The installed image is not gone.** The Yocto rootfs still sits in the A/B
  slot the device was migrated *away* from, untouched, and
  `tools/omni-rollback.sh` still boots it. Rollback does not depend on anything
  removed here.

The migration documents in `docs/` cite `repo/meta-apollo/...` paths as the
provenance for hardware facts (the U-Boot env layout, the watchdog recovery
path, the `mender_*` artefact names). Those citations still resolve against
`0e0f8bc` with `git show`, and they remain the evidence for *why* the current
design is shaped the way it is.

---

## Layout

### `board/` — what we own, that Armbian consumes

Source of truth for the board definition. Nothing here is edited inside the
`armbian/` submodule; `tools/sync-armbian-board.sh` copies it **one way** into
the pinned checkout before every build.

| File | What it is |
|---|---|
| `meson-axg-apollo.dts` | the device tree. One file replacing eight downstream patches. **Must keep producing `meson-axg-apollo.dtb`** — that name is `mender_dtb_name`, it is global rather than per-slot, and renaming it breaks the slot you were going to roll back into. |
| `avast-omni.csc` | Armbian board config. `BOARDFAMILY="meson-axg"`, `BOOTCONFIG="none"` (the load-bearing line), `MODULES_BLACKLIST="meson_nand"`. |
| `post_family_config__avast-omni.sh` | Armbian extension pinning `KERNEL_MAJOR_MINOR` so a `BRANCH` name cannot silently roll the kernel series forward, and forcing `CONFIG_OVERLAY_FS=y` back on after Armbian's own hooks set it to `=m`. |
| `linux-meson64-omni.config` | the kernel-config **delta** (a fragment, not a `.config`) merged over Armbian's stock meson64 config. `CONFIG_REALTEK_PHY=y` is the single most important line in it. |

### `tools/` — device-side and build-side scripts

All of them have `--help`; all of the destructive ones have `--dry-run`.
Everything that targets the device runs **on the device** (or over ssh), uses
`set -euo pipefail`, checks every precondition before writing anything, and
never assumes a tool exists.

| Script | Purpose |
|---|---|
| `omni-backup.sh` | full backup over ssh — partition table, environment, both eMMC boot partitions, whole user area, md5-verified. Writes nothing to the device. |
| `omni-preflight.sh` | read-only inventory; evaluates gates P1–P4 and P8 automatically and prints the manual procedure for P5–P7. |
| `omni-arm.sh`, `omni-commit.sh`, `omni-rollback.sh` | the Mender bootloader contract as three scripts. The Mender daemon was never installed; its whole contract is four environment writes on install, one on commit and three on rollback. |
| `omni-flash.sh` | install + verify + arm a slot image: quiesce (watchdog **off** — a watchdog reset goes to p7, not to the other slot), wipe the target's overlay upper, write, sha256, `e2fsck -fn`, then one batched environment write. |
| `omni-lib.sh` | shared helpers for the above. |
| `omni-console.py`, `omni-uboot.py`, `omni-push.py`, `omni-dd-push.py` | serial-console drivers: run commands, drive the `=>` prompt, and stream files onto a box whose only link is a 115200 baud tty. Default to `127.0.0.1`; use `--host` for a jumphost. |
| `omni-set-slot.sh`, `omni-tailscale-install.sh` | flip the boot pointer; install Tailscale onto a running slot with state pinned to `/data`. |
| `sync-armbian-board.sh` | one-way `board/` → `armbian/` sync, including the kernel-config merge (Armbian has no fragment mechanism — the override path *replaces* the whole config). |
| `validate-dts.sh` | compile and decompile the DTS against a sparse mainline checkout, classifying `dtc` warnings as ours vs inherited from `meson-axg.dtsi`. |
| `check-kconfig-invariants.sh` | asserts the kernel-config delta against a `.config`, a `linux-image` `.deb` or `/proc/config.gz`. CI gate. |
| `check-image-invariants.sh` | asserts the rootfs/image invariants (feature set, flatten hooks, serial autologin, absence of `armbian-install`). Read-only; also runnable on a live slot with `--rootfs /`. |

### `rootfs/` — the Debian trixie slot image

`mmdebstrap`, not Armbian's image pipeline. That structurally eliminates
`armbian-bsp-cli` and therefore `armbian-install`, which repartitions eMMC and
rewrites bootloaders; CI asserts it is absent.

| Path | What it is |
|---|---|
| `build-rootfs.sh` | the builder: `mmdebstrap` → ext4 slot image with a feature set pinned to what U-Boot 2018.09 can read, plus the sha256/size sidecars `omni-flash.sh` verifies. |
| `build-in-docker.sh` | the same, containerised. |
| `packages.list`, `Dockerfile` | inputs. |
| `overlay/` | everything shipped into the image: the flatten hooks that put real files at the three fixed `/boot` names, the initramfs-tools overlay-root script, the commit/deadman units, serial autologin, the login banner, `/data` relocation of per-slot state. |

The three artefact names U-Boot loads are global, not per-slot, and were
captured verbatim off the device rather than typed from the U-Boot patches —
`overlay/etc/default/omni-boot` records both the values and the capture.

### `armbian/`

A pinned submodule checkout of [armbian/build](https://github.com/armbian/build).
Treat it as read-only. Files are copied *into* it by
`tools/sync-armbian-board.sh`; nothing is edited there and nothing is committed
from there.

---

## CI

| Workflow | What it does |
|---|---|
| [`build-omni-kernel.yml`](.github/workflows/build-omni-kernel.yml) | checks out the pinned `armbian/` SHA, runs `tools/sync-armbian-board.sh`, `./compile.sh kernel BOARD=avast-omni BRANCH=current`, then **fails the build** unless `tools/check-kconfig-invariants.sh --strict` and `tools/validate-dts.sh --strict` both pass. Publishes the `-meson64` debs and the built DTB. ~1.5 hours. |
| [`build-omni-rootfs.yml`](.github/workflows/build-omni-rootfs.yml) | runs `rootfs/build-in-docker.sh` against the kernel debs from the workflow above, then `tools/check-image-invariants.sh` on the mounted result. Publishes `omni-slot.ext4.gz` with its sha256 and byte size, which are the inputs `tools/omni-flash.sh` requires. ~9 minutes. |

Both are path-filtered so an unrelated commit does not start them, and both use
a `cancel-in-progress` concurrency group.

Neither may auto-merge an upstream `armbian/` rebase: Armbian's `BRANCH` names
roll the kernel series forward silently (`oldlts`→6.12, `current`→6.18,
`edge`→7.1 as of 2026-08-02), which is why the submodule is pinned to a SHA and
`KERNEL_MAJOR_MINOR` is pinned again in `board/`.

The rootfs container runs `--privileged` **in CI only** — `mmdebstrap
--mode=unshare` needs `newuidmap` to write a multi-range uid_map, and a runner
container cannot do that with seccomp/apparmor unconfined alone. Runners are
ephemeral single-tenant VMs. Do not copy that flag to a shared host.

---

## Documents

| Document | What it is | Read it when |
|---|---|---|
| [`docs/ARMBIAN-MIGRATION.md`](docs/ARMBIAN-MIGRATION.md) | **the plan.** Phases, gates, risks, rollback model, DTS port design, rootfs design. Authoritative for *why*. | before changing anything structural |
| [`docs/RUNBOOK.md`](docs/RUNBOOK.md) | **the operator guide.** Per phase: preconditions, exact commands, closing evidence, rollback. Contains the recovery ladder and an **IF YOU BRICK IT** section. | while doing it, at 2 a.m., with a serial cable |
| [`docs/HARDWARE.md`](docs/HARDWARE.md) | the device-inventory template. **Still unfilled** — 213 `<<UNFILLED>>` fields. The hardware facts the migration actually depended on were captured and verified per phase and are recorded in `RUNBOOK.md` and `dts-port-audit.md`; this document was never back-filled. | when a hardware fact is in question — and expect to have to capture it |
| [`docs/dts-port-audit.md`](docs/dts-port-audit.md) | node-by-node audit of the downstream 5.4 DTS against the mainline port, every property classified present / deleted / moved-to-dtsi / new | when reviewing or changing the DTS |
| [`board/README.md`](board/README.md) | how Armbian picks the board files up, and the deliberate deviations from the upstream reference boards | when touching `board/` |

---

## Where to start

* **Flashing or updating a device?** [`docs/RUNBOOK.md`](docs/RUNBOOK.md).
* **Something is broken and the box will not boot?**
  [`docs/RUNBOOK.md` § IF YOU BRICK IT](docs/RUNBOOK.md#3-if-you-brick-it).
* **Reviewing the design?** [`docs/ARMBIAN-MIGRATION.md`](docs/ARMBIAN-MIGRATION.md).
* **Looking for the old Yocto build?** [Above](#the-yocto-tree) — it is at
  `0e0f8bc`.

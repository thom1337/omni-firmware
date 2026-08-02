# Avast Omni firmware

This repository holds two things at once:

1. **The shipping firmware** — a Yocto (kirkstone) build producing the
   `apollo-image` rootfs, kernel 5.4.62 and U-Boot 2018.09. This is what is on
   the device today. It is described in *[Building the shipping Yocto
   image](#building-the-shipping-yocto-image)* below.
2. **A migration in progress** — replacing that userland and kernel with
   Debian trixie on a mainline LTS kernel, built via Armbian as a kernel
   factory. See *[The Armbian migration](#the-armbian-migration)*.

> **The Yocto tree is still the shipping firmware.** Nothing in `board/`,
> `tools/`, `rootfs/` or `docs/` is on a device in the field, and none of it
> becomes the product until the Phase 8 gate in
> [`docs/ARMBIAN-MIGRATION.md`](docs/ARMBIAN-MIGRATION.md) is passed. Until
> then, `repo/` is the source of truth for what customers are running, and it
> must keep building.

---

## Building the shipping Yocto image

* install docker and git on a Linux PC (other host OS are not supported)
* clone `omni-firmware-public` repository
  ```
    $ git clone --recurse-submodules https://github.com/avast/omni-firmware.git
  ```
* run image build (takes some time)
  ```
    $ cd omni-firmware && make all
  ```
* symlink to resulting image is in `build/tmp/deploy/images/meson-apollo/apollo-image-6.6.1-prod-meson-apollo.ext4`

### How to build a single package?

  Let's say we want to build `iptables` package containing Avast modification. We can do that the following way:
  ```
    $ make all TARGET="iptables"
  ```

  The resulting package can be found in `build/tmp/deploy/deb/aarch64` along with iptables modules.

### Toolchain/SDK preparation

  ```
    $ make all TARGET="apollo-image -c populate_sdk"
  ```
   * after build is done, SDK installer can be found in `build/tmp/deploy/sdk/apollo-poky-glibc-x86_64-apollo-image-6.6.1-prod-aarch64-meson apollo-toolchain-6.6.1.sh`

CI for this build is [`.github/workflows/build-apollo-image.yml`](.github/workflows/build-apollo-image.yml)
— a ~6 hour job on every push to `master` that uploads the rootfs, the
initramfs, `Image`, `meson-axg-apollo.dtb`, the modules tarball and `u-boot.bin`.

---

## The Armbian migration

### Why

Kernel 5.4.62 (vendor tree) has been EOL since December 2025. The image has no
WireGuard, no nftables, and mounts cgroup v1 through a tmpfs `fstab` hack that
systemd ≥ 256 refuses to boot on. Every package change costs a Yocto rebuild.
The full argument, the phase plan, the risk register and the appendix of
independently verified safety-critical claims are in
**[`docs/ARMBIAN-MIGRATION.md`](docs/ARMBIAN-MIGRATION.md) — that document is
the specification and it is authoritative.**

### The shape of it

Armbian is used **as a kernel factory only** (`BOOTCONFIG="none"` — it never
compiles U-Boot and never writes a bootloader). The rootfs is built separately
with `mmdebstrap`. The vendor U-Boot 2018.09 and its Mender A/B contract are
never touched, because the bootloader loads the kernel, DTB and initramfs from
`/boot` **inside the selected A/B rootfs slot** — so a new kernel ships
atomically with its rootfs, and rollback into the untouched Yocto slot stays
available at every step.

### Documents

| Document | What it is | Read it when |
|---|---|---|
| [`docs/ARMBIAN-MIGRATION.md`](docs/ARMBIAN-MIGRATION.md) | **the plan.** Phases, gates, risks, rollback model, DTS port design, rootfs design. Authoritative. | before anything |
| [`docs/RUNBOOK.md`](docs/RUNBOOK.md) | **the operator guide.** Per phase: preconditions, exact commands, closing evidence, rollback. Contains the recovery ladder and an **IF YOU BRICK IT** section. | while doing it, at 2 a.m., with a serial cable |
| [`docs/HARDWARE.md`](docs/HARDWARE.md) | the Phase 0 artefact — a **template filled on the device**. Every unknown has a labelled blank and the command that produces it. | before Phase 1; it gates the project |
| [`docs/dts-port-audit.md`](docs/dts-port-audit.md) | the Phase 3 artefact — node-by-node audit of the downstream 5.4 DTS against the mainline port, every property classified present / deleted / moved-to-dtsi / new | when reviewing or changing the DTS |
| [`board/README.md`](board/README.md) | how Armbian picks the board files up, and the deliberate deviations from the upstream reference boards | when touching `board/` |

`docs/HARDWARE.md` is a template until somebody fills it in on real hardware.
While `grep -n '<<UNFILLED>>' docs/HARDWARE.md` prints anything, the migration
is not cleared to proceed past Phase 0.

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
| `omni-backup.sh` | full pre-flight backup over ssh — partition table, environment, both eMMC boot partitions, whole user area, md5-verified. Writes nothing to the device. |
| `omni-preflight.sh` | read-only Phase 0 inventory; evaluates gates P1–P4 and P8 automatically and prints the manual procedure for P5–P7. |
| `omni-arm.sh`, `omni-commit.sh`, `omni-rollback.sh` | the Mender bootloader contract as three scripts. The Mender daemon was never installed; its whole contract is four environment writes on install, one on commit and three on rollback. |
| `omni-flash.sh` | install + verify + arm a slot image: quiesce (watchdog **off** — a watchdog reset goes to p7, not to the other slot), wipe the target's overlay upper, write, sha256, `e2fsck -fn`, then one batched environment write. |
| `omni-lib.sh` | shared helpers for the above. |
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
| `overlay/` | everything shipped into the image: the flatten hooks that put real files at the three fixed `/boot` names, the initramfs-tools overlay-root script, the commit/deadman units, serial autologin, `/data` relocation of per-slot state. |

The build **fails closed** while `overlay/etc/default/omni-boot` still says
`OMNI_BOOT_VERIFIED="no"`: the three artefact names U-Boot loads are global and
must be captured verbatim off the device (pre-flight check P4), never typed from
the U-Boot patches.

### CI

| Workflow | Status | What it does |
|---|---|---|
| `.github/workflows/build-apollo-image.yml` | **live** | the existing Yocto build. Keeps working until Phase 8. |
| `.github/workflows/build-omni-kernel.yml` | **Phase 6 — not yet committed** | checks out the pinned `armbian/` SHA, runs `tools/sync-armbian-board.sh`, `./compile.sh kernel BOARD=avast-omni BRANCH=oldlts`, then **fails the build** unless `tools/check-kconfig-invariants.sh --strict` and `tools/validate-dts.sh --strict` both pass. Publishes the four `-meson64` debs and the built DTB. The gate is that a CI-built `Image` passes the Phase 4 hardware gate *unchanged*. |
| `.github/workflows/build-omni-rootfs.yml` | **Phase 7 — not yet committed** | runs `rootfs/build-in-docker.sh` against the kernel debs from the workflow above, then `tools/check-image-invariants.sh --strict` on the result. Publishes `omni-slot.ext4.gz` with its sha256 and byte size, which are the inputs `tools/omni-flash.sh` requires. |

Both new workflows must pin the `armbian/` submodule to a SHA and must never
auto-merge an upstream rebase: Armbian's `BRANCH` names roll the kernel series
forward silently (`oldlts`→6.12, `current`→6.18, `edge`→7.1 as of 2026-08-02).

### `armbian/`

A pinned submodule checkout of [armbian/build](https://github.com/armbian/build).
Treat it as read-only. Files are copied *into* it by
`tools/sync-armbian-board.sh`; nothing is edited there and nothing is committed
from there.

---

## Where to start

* **Doing the migration?** [`docs/RUNBOOK.md`](docs/RUNBOOK.md), from the top.
* **Reviewing the design?** [`docs/ARMBIAN-MIGRATION.md`](docs/ARMBIAN-MIGRATION.md).
* **Something is broken and the box will not boot?**
  [`docs/RUNBOOK.md` § IF YOU BRICK IT](docs/RUNBOOK.md#3-if-you-brick-it).
* **Shipping a fix to customers today?** The Yocto tree above. The migration
  changes nothing about that until Phase 8.

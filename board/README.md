# `board/` — Avast Omni board definition for the Armbian kernel factory

This directory holds the **board-specific source that we own** and that Armbian
consumes. Armbian is used here as a *kernel factory only* (`BOOTCONFIG="none"`,
no U-Boot build, no image pipeline, no `armbian-bsp-cli`), so the only thing
Armbian needs from us is a device tree plus a board config.

Nothing in this directory is edited inside the `armbian/` submodule. The
submodule is a pinned upstream checkout; files are **copied one-way** from here
into it before every build. See [Syncing](#syncing-into-the-armbian-submodule).

## Contents

| File | What it is | Where it is installed inside `armbian/` |
|---|---|---|
| `meson-axg-apollo.dts` | the device tree — this document's main subject | `patch/kernel/archive/meson64-<ver>/dt/`, from where Armbian copies it to `arch/arm64/boot/dts/amlogic/` |
| `avast-omni.csc` | Armbian board config (`BOARDFAMILY="meson-axg"`, `BOOTCONFIG="none"`, `MODULES_BLACKLIST`) | `config/boards/avast-omni.csc` |
| `post_family_config__avast-omni.sh` | Armbian extension that pins `KERNEL_MAJOR_MINOR` so a `BRANCH` name cannot roll the kernel series forward | `userpatches/extensions/` |
| `linux-meson64-omni.config` | kernel-config **delta**, merged over Armbian's stock meson64 config (it is a fragment, not a `.config`) | merged into `userpatches/config/kernel/linux-meson64-<branch>.config` |

The `.csc`, the extension and the config delta are documented in their own
headers; this file covers the DTS and the mechanism that carries all four
across.

## The DTB filename is part of the boot contract

`meson-axg-apollo.dts` builds `meson-axg-apollo.dtb`. That name is **not
cosmetic**:

* U-Boot 2018.09 loads `/boot/${mender_dtb_name}` from inside the selected A/B
  rootfs slot, and `mender_dtb_name` is a **global** environment variable
  (`meson-axg-apollo.dtb`), not a per-slot one.
* Renaming the DTS renames the DTB, which breaks the *other* slot too — the one
  you were going to roll back into.

If the name must ever change, the env variable has to change first, on the
device, in the same maintenance window, with a serial console attached.

## How Armbian picks the DTS up

Armbian's kernel patching for the `meson64` family is driven by
`patch/kernel/archive/meson64-<major>.<minor>/0000.patching_config.yaml`. Two
stanzas matter (verified present and identical in both `meson64-6.12` and
`meson64-6.18`):

```yaml
  # .dts files in these directories will be copied as-is to the build tree
  dts-directories:
    - { source: "dt", target: "arch/arm64/boot/dts/amlogic" }

  # the Makefile in each of these directories will be magically patched to
  # include the dts files copied or patched-in
  auto-patch-dt-makefile:
    - { directory: "arch/arm64/boot/dts/amlogic", config-var: "CONFIG_ARCH_MESON" }
```

So the flow is:

1. We drop `meson-axg-apollo.dts` into
   `armbian/patch/kernel/archive/meson64-6.12/dt/`.
2. Armbian copies it verbatim into `arch/arm64/boot/dts/amlogic/` in the
   unpacked kernel source.
3. Armbian then rewrites `arch/arm64/boot/dts/amlogic/Makefile` itself, adding
   `dtb-$(CONFIG_ARCH_MESON) += meson-axg-apollo.dtb`.

**No patch file, no Makefile hunk, no rebase pain on kernel bumps.** That is the
entire reason the eight downstream `0001..0014` patches collapse into one file.

### Consequence: everything must live in the single `.dts`

`dts-directories` copies **`*.dts` only**. A companion `.dtsi` would *not* be
copied and the build would fail on a missing include. Keep the board
self-contained; the only `#include`s allowed are ones that already exist in the
kernel tree (`meson-axg.dtsi` and `dt-bindings/...`).

## Syncing into the `armbian/` submodule

`tools/sync-armbian-board.sh` does this for all four files. For the DTS
specifically it is one-way, idempotent, and destructive on the target side only:

```sh
ARMBIAN_KVER=6.12          # must match KERNEL_MAJOR_MINOR pinned by the extension
DEST="armbian/patch/kernel/archive/meson64-${ARMBIAN_KVER}/dt"

mkdir -p "$DEST"
rsync -a --delete --include='*.dts' --exclude='*' board/ "$DEST/"
```

Never edit `$DEST` directly and never commit changes made inside the submodule:
`git -C armbian status --porcelain` should be empty except for the copied `dt/`
contents, which are regenerated.

Then:

```sh
cd armbian
./compile.sh kernel BOARD=avast-omni BRANCH=current  # current == 6.18 for meson-axg today
```

`BRANCH` names roll forward silently upstream (`oldlts`→6.12, `current`→6.18,
`edge`→7.1 as of 2026-08-02), which is why the board config must also pin
`KERNEL_MAJOR_MINOR="6.12"` from a `post_family_config` hook. The submodule
itself is pinned to a SHA.

## Verifying the DTS without a full Armbian build

Use `tools/validate-dts.sh` (it fetches a sparse v6.12 kernel checkout into
`.cache/` on first run and can fall back to a container if the host has no
`dtc`):

```sh
tools/validate-dts.sh --strict
```

Or do it by hand against any mainline kernel checkout — seconds, not minutes:

```sh
LINUX=/path/to/linux           # a v6.12 (or v6.18) source tree
cp board/meson-axg-apollo.dts "$LINUX/arch/arm64/boot/dts/amlogic/"
cd "$LINUX"
cpp -nostdinc -Iinclude -Iarch/arm64/boot/dts -Iarch/arm64/boot/dts/amlogic \
    -undef -x assembler-with-cpp \
    -D__DTS__ -o /tmp/apollo.pre arch/arm64/boot/dts/amlogic/meson-axg-apollo.dts
dtc -I dts -O dtb -o /tmp/meson-axg-apollo.dtb -b 0 \
    -i arch/arm64/boot/dts/amlogic /tmp/apollo.pre
```

The expected output is **exactly four warning lines** — two nodes
(`/soc/bus@ff634000/pinctrl@480` and `/soc/bus@ff800000/pinctrl@14`) × two
checks (`unit_address_vs_reg`, `simple_bus_reg`), all of them raised against
`meson-axg.dtsi` itself. They appear identically when compiling stock
`meson-axg-s400.dts`, so they are upstream baseline noise.
`tools/validate-dts.sh` deduplicates them and reports "2 inherited from mainline
dtsi, 0 attributable to meson-axg-apollo.dts". Any warning that names a line in
`meson-axg-apollo.dts` is ours and must be fixed.

To read the result back:

```sh
dtc -I dtb -O dts /tmp/meson-axg-apollo.dtb | less
```

The Phase 3 evidence in `docs/ARMBIAN-MIGRATION.md` is a node-for-node diff of
`dtc -I dtb -O dts` on the old 5.4 DTB versus this one, with every delta
classified *present / deleted / moved-to-dtsi*. That audit lands in
`docs/dts-port-audit.md`.

## Kernel-config options this DTS depends on

The DTS is only half of the port. The authoritative list lives in
`board/linux-meson64-omni.config` and is asserted in CI by
`tools/check-kconfig-invariants.sh`; the entries below are the ones this DTS
specifically would silently no-op without.

| Option | Why | Armbian meson64 stock |
|---|---|---|
| `CONFIG_REALTEK_PHY=y` | RTL8211F; without it phylib falls back to genphy and you get "gigabit that mostly works" | **absent** |
| `CONFIG_MTD_NAND_MESON=n` | `&nfc` is disabled in the DTS, but belt-and-braces: its `"emmc"` reg window *is* `sd_emmc_c`'s | `=m` |
| `CONFIG_KEYBOARD_GPIO_POLLED=y` | the reset button uses `gpio-keys-polled` (see below) | `=y` |
| `CONFIG_LEDS_PWM` / `CONFIG_PWM_MESON` | the three front-panel LEDs | `=m` / `=y` |
| `CONFIG_CPU_THERMAL=y` | the new `thermal-zones` cooling maps | `=y` |
| `CONFIG_PSTORE_RAM` | the `ramoops@f400000` reservation | `=m` |
| `CONFIG_MMC_MESON_GX`, `CONFIG_EXT4_FS`, `CONFIG_OVERLAY_FS` | root | present |
| `CONFIG_PANIC_TIMEOUT=15`, `CONFIG_PANIC_ON_OOPS=y` | mainline defaults `PANIC_TIMEOUT` to 0 = hang forever, which silently disables bootcount rollback | unset |

Plus `MODULES_BLACKLIST="meson_nand"` in the board config.

## Deliberate deviations from upstream reference boards

These are all commented in the DTS itself; summarised here so they are not
"discovered" during a bisect.

* **`gpio-keys-polled`, not `gpio-keys`.** On meson, `gpiod_to_irq()` returns
  `-ENXIO` (the pinctrl driver registers no irqchip), and adding an explicit
  `gpio_intc` interrupt does not help because `gpio_keys` unconditionally
  requests `EDGE_BOTH`, which the AXG gpio-intc rejects with `-EINVAL`. Every
  mainline Amlogic board uses `gpio-keys-polled` for exactly this reason.
* **`pinctrl-0 = <&emmc_pins>` only**, where `meson-axg-s400.dts` and
  `meson-axg-jethome-jethub-j1xx.dtsi` also list `&emmc_ds_pins`. DS is the
  HS400 data strobe; this board only advertises HS200, and muxing an extra pad
  on a device that cannot be recovered remotely is not a free change.
* **No `rx-fifo-depth` / `tx-fifo-depth` on `&ethmac`.** Mainline
  `meson-axg.dtsi` already sets them to the same 4096 / 2048 the downstream
  patch added.
* **`ramoops@f400000`, not `ramoops@f9800000`.** The downstream unit address
  contradicted its own `reg`.
* **LED node names `led-0/1/2`** to satisfy `leds-pwm.yaml`
  (`^led(-[0-9a-f]+)?$`), while the `label` strings stay `apollo:power`,
  `apollo:app1`, `apollo:app2` verbatim, because those are the sysfs paths the
  initramfs writes.

## Open items — decided on hardware, not here

| Item | Where |
|---|---|
| `phy-mode = "rgmii"` vs `"rgmii-rxid"` | Phase 5: compare MDIO page `0xd08` reg 17 bit 8 (TX delay) and reg 21 bit 3 (RX delay) on 5.4 vs 6.12, cold power cycle between boots |
| Does the PHY interrupt actually fire? | Phase 4: 20 cable pulls must each bump the `gpio_intc` line in `/proc/interrupts` |
| Does `scpi_sensors 0` exist on this SCP firmware? | Phase 5: `cat /sys/class/thermal/thermal_zone0/{type,temp}` |
| Is a USB2 port physically routed? | Phase 5: `&usb { status = "okay"; }` on a **throwaway** DTB |
| `mmc-pwrseq-emmc` BOOT_9 correctness | Phase 4: 50 consecutive warm reboots (cold-boot-invisible failure mode) |

Throwaway experiments belong on a DTB loaded from the `=>` prompt, never on a
committed DTS — a power cycle undoes 100 % of that.

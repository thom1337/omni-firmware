# DTS port audit — downstream 5.4 → mainline 6.12

**Phase 3 artefact.** Required evidence for closing Phase 3 in
`docs/ARMBIAN-MIGRATION.md`: *"committed node-for-node diff of `dtc -I dtb -O
dts` old vs new, every delta classified present / deleted / moved-to-dtsi."*

| | |
|---|---|
| **Old** | reconstructed from `repo/meta-apollo/recipes-kernel/linux/files/0001…0014`, applied in numeric order to Linux 5.4.62 |
| **New** | [`board/meson-axg-apollo.dts`](../board/meson-axg-apollo.dts) — present in the tree, audited as written |
| **Mainline base** | `arch/arm64/boot/dts/amlogic/meson-axg.dtsi` @ v6.12 (Armbian `oldlts` for the `meson-axg` family) |
| **Reference boards** | `meson-axg-s400.dts` (ethernet), `meson-axg-jethome-jethub-j1xx.dtsi` (thermal, pwrseq idiom) |
| **Produced DTB name** | `meson-axg-apollo.dtb` — **unchanged, and not negotiable** (`mender_dtb_name` is global, not per-slot) |

Classification vocabulary, used in every table below:

| Class | Meaning |
|---|---|
| **PRESENT** | carried over into the new DTS. The `Δ` column flags a changed *value* or *spelling*. |
| **DELETED** | intentionally not carried over. Every one has a reason in the Note column. |
| **MOVED-TO-DTSI** | no longer stated by the board file because mainline `meson-axg.dtsi` supplies it. The cited file is the source of truth. |
| **NEW** | added by this port; had no counterpart downstream. |

---

## 0. Which patches touch the device tree

| Patch | Touches DTS? | Disposition |
|---|---|---|
| `0001-arm64-dts-meson-axg-add-apollo-evt0-board.patch` | yes — creates the file | **rebased** — becomes `board/meson-axg-apollo.dts` |
| `0002-arm64-dts-apollo-fix-emmc-maximum-rate.patch` | yes | folded in (200 MHz) |
| `0003-arm64-dts-meson-axg-s400-Enable-PHY-interrupt.patch` | yes (despite the s400 name in the subject, it patches the Apollo file) | folded in |
| `0004-arm64-dts-apollo-Drop-the-evt0-suffix.patch` | yes — rename + `compatible`/`model` | folded in |
| `0005-DOWNSTREAM-apollo-leds-Set-initial-brightness-level.patch` | yes, **plus two driver files** | **deleted** — see §3.5 |
| `0006-arm64-dts-apollo-enable-dma-thresh-mode.patch` | yes | **deleted** — see §4.1 |
| `0012-meson-axg-apollo-reserve-memory-for-pstore_ram.patch` | yes | kept, node renamed — see §3.3 |
| `0013-amlogic-remove-unused-target.patch` | Makefile only | **deleted** — Armbian's `auto-patch-dt-makefile` replaces it |
| `0014-meson-axg-apollo-disable-force_thresh_dma_mode.patch` | yes | **deleted** (it deletes a property that is itself deleted) |
| `0007`–`0011`, `0016`–`0020` | no (defconfig / perf / netfilter) | out of scope here; `0009`–`0011` are covered by the kernel-config delta |

> **`0004` shipped a broken tree for eleven months.** It added
> `dtb-$(CONFIG_ARCH_MESON) += meson-axg-apollo.dtb` to the Makefile but left
> the `meson-axg-apollo-evt0.dtb` line behind after renaming the source file
> away; `0013` (Nov 2019) removed it. This is exactly the class of bookkeeping
> the new mechanism removes: Armbian's `dts-directories` +
> `auto-patch-dt-makefile` rules generate the Makefile line, so there is no
> Makefile hunk to get wrong.

---

## 1. The reconstructed old DTS

This file does not exist as a single artefact anywhere — it only ever existed as
5.4 plus eight patches. Reproduced here in full so the audit can be checked
without re-applying anything. To regenerate it yourself:

```sh
cd /path/to/linux-5.4.62
for p in 0001 0002 0003 0004 0005 0006 0012 0013 0014; do
  git apply repo/meta-apollo/recipes-kernel/linux/files/${p}-*.patch
done
cat arch/arm64/boot/dts/amlogic/meson-axg-apollo.dts
```

```dts
// SPDX-License-Identifier: (GPL-2.0+ OR MIT)
/*
 * Copyright (c) 2018 Baylibre SAS. All rights reserved.
 */

/dts-v1/;

#include "meson-axg.dtsi"

/ {
	compatible = "avast,apollo", "amlogic,a113d", "amlogic,meson-axg";
	model = "Avast Apollo Board";

	aliases {
		serial0 = &uart_AO;
		ethernet0 = &ethmac;
	};

	chosen {
		stdout-path = "serial0:115200n8";
	};

	reserved-memory {
		ramoops@f9800000 {
			compatible = "ramoops";
			reg = <0 0x0f400000 0 0x10000>;
			record-size = <0x4000>;
			console-size = <0x0>;
		};
	};

	emmc_pwrseq: emmc-pwrseq {
		compatible = "mmc-pwrseq-emmc";
		reset-gpios = <&gpio BOOT_9 GPIO_ACTIVE_LOW>;
	};

	leds {
		compatible = "pwm-leds";

		app1 {
			label = "apollo:app1";
			pwms = <&pwm_cd 0 7812500 0>;
			brightness = <0>;
			max-brightness = <255>;
		};

		app2 {
			label = "apollo:app2";
			pwms = <&pwm_ab 0 7812500 0>;
			brightness = <0>;
			max-brightness = <255>;
		};

		power {
			label = "apollo:power";
			pwms = <&pwm_ab 1 7812500 0>;
			brightness = <0>;
			max-brightness = <255>;
		};
	};

	memory@0 {
		device_type = "memory";
		reg = <0x0 0x0 0x0 0x20000000>; /* 512MB */
	};

	supply_5v: regulator-supply_5v {
		compatible = "regulator-fixed";
		regulator-name = "5V";
		regulator-min-microvolt = <5000000>;
		regulator-max-microvolt = <5000000>;
		regulator-always-on;
	};

	vcc_3v3: regulator-vcc_3v3 {
		compatible = "regulator-fixed";
		regulator-name = "VCC_3V3";
		regulator-min-microvolt = <3300000>;
		regulator-max-microvolt = <3300000>;
		vin-supply = <&supply_5v>;
		regulator-always-on;
	};

	vddio_boot: regulator-vddio_boot {
		compatible = "regulator-fixed";
		regulator-name = "VDDIO_BOOT";
		regulator-min-microvolt = <1800000>;
		regulator-max-microvolt = <1800000>;
		vin-supply = <&vcc_3v3>;
		regulator-always-on;
	};
};

&ethmac {
	status = "okay";
	pinctrl-0 = <&eth_rgmii_y_pins>;
	pinctrl-names = "default";
	phy-handle = <&eth_phy0>;
	phy-mode = "rgmii";
	snps,pbl = "32"; // default value is 8
	rx-fifo-depth = <4096>; // max hw value
	tx-fifo-depth = <2048>; // max hw value

	mdio {
		compatible = "snps,dwmac-mdio";
		#address-cells = <1>;
		#size-cells = <0>;

		eth_phy0: ethernet-phy@0 {
			/* Realtek RTL8211F (0x001cc916) */
			reg = <0>;
			eee-broken-1000t;
			interrupt-parent = <&gpio_intc>;
			interrupts = <98 IRQ_TYPE_LEVEL_LOW>;
		};
	};
};

&pwm_ab {
	status = "okay";
	pinctrl-0 = <&pwm_a_a_pins>, <&pwm_b_a_pins>;
	pinctrl-names = "default";
};

&pwm_cd {
	status = "okay";
	pinctrl-0 = <&pwm_c_a_pins>;
	pinctrl-names = "default";
};

&sd_emmc_c {
	status = "okay";
	pinctrl-0 = <&emmc_pins>;
	pinctrl-1 = <&emmc_clk_gate_pins>;
	pinctrl-names = "default", "clk-gate";

	bus-width = <8>;
	cap-mmc-highspeed;
	max-frequency = <200000000>;
	non-removable;
	disable-wp;
	mmc-ddr-1_8v;
	mmc-hs200-1_8v;

	mmc-pwrseq = <&emmc_pwrseq>;

	vmmc-supply = <&vcc_3v3>;
	vqmmc-supply = <&vddio_boot>;
};

&uart_AO {
	status = "okay";
	pinctrl-0 = <&uart_ao_a_pins>;
	pinctrl-names = "default";
};
```

**Notable absences downstream**, all of which the new file adds: no reset
button, no thermal management of any kind, no `&nfc` handling (mainline had not
yet added the node), and no explicit `#address-cells` on `reserved-memory`.

---

## 2. Summary

| Class | Count | Where |
|---|---|---|
| PRESENT | 62 properties across 15 nodes | §3, §4, §5 |
| DELETED | 6 properties + 2 kernel source files + 2 Makefile hunks | §3.5, §4.1, §6 |
| MOVED-TO-DTSI | 5 properties | §4.1, §3.3 |
| NEW | 3 whole nodes + 4 properties | §3.6, §3.7, §4.2, §3.5 |

**No property of the old DTS is unaccounted for.** Every line of §1 appears in
exactly one row below.

---

## 3. Root-level nodes

### 3.1 `/` and `/aliases` and `/chosen`

| Property | Old | New | Class | Δ | Note |
|---|---|---|---|---|---|
| `/compatible` | `"avast,apollo", "amlogic,a113d", "amlogic,meson-axg"` | identical | PRESENT | — | The `avast,apollo` string is not matched by any mainline driver; it exists for U-Boot's `fdt_fixup_*` and for humans. Keep it — a `compatible` change is a silent behaviour change in `of_machine_is_compatible()` users. |
| `/model` | `"Avast Apollo Board"` | `"Avast Omni (Apollo)"` | PRESENT | **value** | Cosmetic; surfaces in `/proc/device-tree/model` and in the boot banner. Deliberate: the product is the Omni, the board is Apollo. |
| `/aliases/serial0` | `&uart_AO` | identical | PRESENT | — | Backs `stdout-path`. |
| `/aliases/ethernet0` | `&ethmac` | identical | PRESENT | — | **Load-bearing twice over.** U-Boot's `fdt_fixup_ethernet()` walks `/aliases` for `ethernetN` and injects `${ethaddr}` as `local-mac-address`/`mac-address`; `ethaddr` is the only copy of this unit's MAC. systemd-udevd (net naming scheme ≥ v251, trixie ships 257) reads the *same* alias for DT-based naming, which is why the NIC becomes `end0` on Debian. Handle the rename in userland; never by removing the alias. |
| `/chosen/stdout-path` | `"serial0:115200n8"` | identical | PRESENT | — | |

### 3.2 `/memory@0`

| Property | Old | New | Class | Δ | Note |
|---|---|---|---|---|---|
| `device_type` | `"memory"` | identical | PRESENT | — | |
| `reg` | `<0x0 0x0 0x0 0x20000000>` | identical | PRESENT | — | 512 MiB. `0001` line 85. The A113D SoC has no other DRAM configuration on this board. |

### 3.3 `/reserved-memory` and ramoops

| Property | Old | New | Class | Δ | Note |
|---|---|---|---|---|---|
| `/reserved-memory/#address-cells` | *(inherited, unstated)* | `<2>`, restated | MOVED-TO-DTSI | — | `meson-axg.dtsi` v6.12:139-155 defines the node with `#address-cells = <2>`, `#size-cells = <2>`, `ranges`. dtc merges the two definitions; restating identical values is a no-op that makes the fragment readable standalone. Changing them would silently reinterpret the `reg` below. |
| `/reserved-memory/#size-cells` | *(inherited)* | `<2>`, restated | MOVED-TO-DTSI | — | as above |
| `/reserved-memory/ranges` | *(inherited)* | restated | MOVED-TO-DTSI | — | as above |
| node name `ramoops@f9800000` | `ramoops@f9800000` | `ramoops@f400000` | PRESENT | **name** | The downstream unit-address contradicted its own `reg` (`0x0f400000`) and collided by name with `pcieA@f9800000`. The unit-address is *for* the reg; renaming it is a pure correction with no runtime effect (the `ramoops` driver matches on `compatible`). It **will** show up in a naive DTB diff — expected, and this row is the authority for it. |
| `compatible` | `"ramoops"` | identical | PRESENT | — | Needs `CONFIG_PSTORE_RAM` (Armbian meson64: `=m`). |
| `reg` | `<0 0x0f400000 0 0x10000>` | `<0x0 0x0f400000 0x0 0x10000>` | PRESENT | spelling | Same 64 KiB at 0x0f400000. Clear of `hwrom@0` (0…0x1000000) and `secmon@5000000` (0x5000000…0x5300000), comfortably inside 512 MiB. |
| `record-size` | `<0x4000>` | identical | PRESENT | — | |
| `console-size` | `<0x0>` | identical | PRESENT | — | Console logging into pstore is off; only oops/panic records are kept. |
| *(absent)* `no-map` | — | still absent | PRESENT | — | **Deliberately still absent.** ramoops persists the log with `memcpy` from the linear map; `no-map` would force an ioremap as device memory, where arm64 unaligned/ordering behaviour differs. Also not `reusable` — that is CMA-style and would let the page allocator hand the range out. |

### 3.4 `/emmc-pwrseq`

| Property | Old | New | Class | Δ | Note |
|---|---|---|---|---|---|
| label | `emmc_pwrseq:` | identical | PRESENT | — | Referenced by `&sd_emmc_c`. |
| node name | `emmc-pwrseq` | identical | PRESENT | — | |
| `compatible` | `"mmc-pwrseq-emmc"` | identical | PRESENT | — | Identical to `meson-axg-jethome-jethub-j1xx.dtsi`, which uses the same BOOT_9 line. |
| `reset-gpios` | `<&gpio BOOT_9 GPIO_ACTIVE_LOW>` | identical | PRESENT | — | A pad-numbering error here is **cold-boot-invisible** — it only shows up as an intermittent failure to mount root on a *warm* reboot. That is the entire reason the Phase 4 gate demands 50 consecutive warm `reboot` cycles. |

### 3.5 LEDs — `/leds` → `/led-controller`

The three `label` strings are an ABI: the initramfs and userland write
`/sys/class/leds/apollo:{power,app1,app2}/brightness`, and
`led_compose_name()` copies `props.label` verbatim when no devicename is
supplied (leds-pwm passes `init_data.fwnode` only). Switching to the modern
`function`/`color` properties would **rename those sysfs paths**.

| Property | Old | New | Class | Δ | Note |
|---|---|---|---|---|---|
| node name `leds` | `leds` | `led-controller` | PRESENT | **name** | Mainline convention. The node name is not consumed at runtime. |
| `compatible` | `"pwm-leds"` | identical | PRESENT | — | |
| child names `app1`/`app2`/`power` | those | `led-1`/`led-2`/`led-0` | PRESENT | **name** | `leds-pwm.yaml` constrains children to `^led(-[0-9a-f]+)?$`; `app1` fails `dtbs_check`. The names are unused at runtime whenever `label` is present (`drivers/leds/leds-pwm.c:150-152`). Child *order* also changed (power first) — irrelevant, since sysfs names come from `label`. |
| `label = "apollo:power"` | present | present, **verbatim** | PRESENT | — | ABI. Do not touch. |
| `label = "apollo:app1"` | present | present, **verbatim** | PRESENT | — | ABI. |
| `label = "apollo:app2"` | present | present, **verbatim** | PRESENT | — | ABI. |
| `pwms` (power) | `<&pwm_ab 1 7812500 0>` | identical | PRESENT | — | 7812500 ns = 128 Hz. `#pwm-cells` is 3 on both the 6.12 `amlogic,meson-axg-ee-pwm` binding and the 6.18 `-pwm-v2` rewrite, so the phandle parses either way — but the *achieved* period is an empirical check after any branch bump. |
| `pwms` (app1) | `<&pwm_cd 0 7812500 0>` | identical | PRESENT | — | |
| `pwms` (app2) | `<&pwm_ab 0 7812500 0>` | identical | PRESENT | — | |
| `max-brightness = <255>` ×3 | present | present | PRESENT | — | **Mandatory, not optional**: `led_pwm_set()` does `do_div(duty, cdev.max_brightness)` and leds-pwm defaults it to 0. |
| `brightness = <0>` ×3 | added by `0005` | — | **DELETED** | — | Non-standard property that only worked because `0005` also patched `drivers/leds/leds-pwm.c` and added a field to `include/linux/leds_pwm.h`. **`leds_pwm.h` no longer exists upstream.** Carrying this forward would mean carrying a driver patch forever. |
| `linux,default-trigger = "default-on"` (power) | in `0001`, **removed by `0005`** | — | **DELETED** | — | See the finding below. |
| `default-state = "on"` (power) | — | added | **NEW** | — | The 6.12-correct replacement. `leds-pwm.c:164` (v6.12) calls `led_init_default_state_get()` and seeds `cdev.brightness` with `max-brightness` before the first `led_pwm_set()`, so the power LED is lit from probe instead of glitching off until userland writes to sysfs. `default-brightness = <N>` landed in 6.13 and is therefore **not** usable on the 6.12 pin. |

> **Finding — `0005` did the opposite of what its commit message claims.** The
> message says the LED brightness is set to "B:247 R:0 G:51" to remove a
> boot-time glitch. The applied hunk sets `brightness = <0>` on all three LEDs
> *and deletes* `linux,default-trigger = "default-on"` from the power LED. Net
> effect on the shipping firmware: the power LED is **dark** from probe until
> the initramfs writes `/sys/class/leds/apollo:power/brightness`, which is a
> longer dark window than before the patch. The new DTS restores the pre-`0005`
> intent with `default-state = "on"`. If an operator reports "the power LED now
> comes on earlier than it used to", that is this row, and it is correct.

### 3.6 `gpio-keys-polled` — **NEW**

Whole node is new; the Omni has no button in its device tree today.

| Property | Value | Class | Note |
|---|---|---|---|
| `compatible` | `"gpio-keys-polled"` | NEW | **Not `gpio-keys`, and that is not a style choice.** `pinctrl-meson.c` never populates `gpio_chip.to_irq` and registers no `gpio_irq_chip`, so `gpiod_to_irq()` on any `&gpio`/`&gpio_ao` line returns `-ENXIO` (`gpiolib.c:3655-3673`, v6.12) and plain `gpio-keys` fails to probe with *"Unable to get irq number for GPIO"*. Adding `interrupt-parent`/`interrupts` does not rescue it: `gpio_keys_setup_key()` unconditionally requests `IRQF_TRIGGER_RISING\|FALLING` whenever a gpiod is present (`gpio_keys.c:600`), and `meson8_gpio_irq_set_type()` rejects `EDGE_BOTH` with `-EINVAL` because `axg_params.support_edge_both = false` (`irq-meson-gpio.c:135, :322-324`). Every mainline Amlogic board uses `gpio-keys-polled` for this reason. |
| `poll-interval` | `<100>` | NEW | 100 ms. |
| `button-reset/label` | `"reset"` | NEW | |
| `button-reset/linux,code` | `KEY_RESTART` | NEW | |
| `button-reset/gpios` | `<&gpio_ao GPIOAO_10 GPIO_ACTIVE_LOW>` | NEW | |
| `button-reset/debounce-interval` | `<50>` | NEW | |

Requires `CONFIG_KEYBOARD_GPIO_POLLED=y` (Armbian meson64 stock: `=y`).

**This node does not affect recovery.** U-Boot samples the same pin as a raw
register read (`setexpr button *0xff800028 & 0x400`, patch `0047`) *before*
Linux runs, and diverts to p7. Nothing Linux does here changes that — which
also means adding this node cannot break the recovery path.

### 3.7 `thermal-zones` — **NEW**

The Omni ships with **no thermal management at all** today. Structure and trip
values lifted from `meson-axg-jethome-jethub-j1xx.dtsi:114-157`, the only
mainline AXG board with `thermal-zones`. `meson-axg.dtsi` (v6.12) defines
`scpi_sensors` with `#thermal-sensor-cells = <1>` but no `thermal-zones` node,
so this creates the zone rather than adding trips to an existing one.

| Property | Value | Class | Note |
|---|---|---|---|
| `cpu-thermal/polling-delay-passive` | `<250>` | NEW | ms |
| `cpu-thermal/polling-delay` | `<1000>` | NEW | ms |
| `cpu-thermal/thermal-sensors` | `<&scpi_sensors 0>` | NEW | If this SCP firmware does not export sensor 0, the zone fails to register and logs — it cannot wedge the boot. Verify in Phase 5 with `cat /sys/class/thermal/thermal_zone0/{type,temp}`. |
| `trips/cpu-passive` | 70 °C, hyst 2 °C, `"passive"` | NEW | cpufreq throttling via the cooling maps |
| `trips/cpu-hot` | 80 °C, hyst 2 °C, `"hot"` | NEW | notification only |
| `trips/cpu-critical` | 100 °C, hyst 2 °C, `"critical"` | NEW | orderly shutdown by the thermal core |
| `cooling-maps/map0`, `map1` | `&cpu0…&cpu3` with `THERMAL_NO_LIMIT` | NEW | Needs `CONFIG_CPU_THERMAL` (Armbian meson64: `=y`). |

### 3.8 Fixed regulators

| Property | Old | New | Class | Δ | Note |
|---|---|---|---|---|---|
| node `regulator-supply_5v` | that name | `regulator-supply-5v` | PRESENT | **name** | Underscore → hyphen, mainline node-naming style. Label `supply_5v:` unchanged, so `vin-supply` phandles still resolve. |
| node `regulator-vcc_3v3` | that name | `regulator-vcc-3v3` | PRESENT | **name** | Label `vcc_3v3:` unchanged. |
| node `regulator-vddio_boot` | that name | `regulator-vddio-boot` | PRESENT | **name** | Label `vddio_boot:` unchanged. |
| `compatible = "regulator-fixed"` ×3 | present | present | PRESENT | — | |
| `regulator-name` = `"5V"`, `"VCC_3V3"`, `"VDDIO_BOOT"` | present | present | PRESENT | — | These strings appear in `/sys/class/regulator/*/name` and in log lines; unchanged deliberately. |
| `regulator-min/max-microvolt` ×3 | 5 V / 3.3 V / 1.8 V | identical | PRESENT | — | The 1.8 V `VDDIO_BOOT` is what makes `mmc-ddr-1_8v` / `mmc-hs200-1_8v` legal. |
| `vin-supply` (vcc_3v3 → supply_5v, vddio_boot → vcc_3v3) | present | present | PRESENT | — | Chain 5 V → 3.3 V → 1.8 V. |
| `regulator-always-on` ×3 | present | present | PRESENT | — | Without it, regulator core may disable an unused supply and take the eMMC down with it. |

---

## 4. `&ethmac` — gigabit Ethernet

Byte-for-byte the `meson-axg-s400.dts` node (same RGMII-on-Y pinout, same
RTL8211F at MDIO address 0) — which is what the vendor DTS was a copy of. The
plan is explicit that ethernet must **not** be lifted from JetHub: that is
100 Mbit RMII with an ICPlus PHY.

### 4.1 Properties

| Property | Old | New | Class | Δ | Note |
|---|---|---|---|---|---|
| `status` | `"okay"` | identical | PRESENT | — | |
| `pinctrl-0` | `<&eth_rgmii_y_pins>` | identical | PRESENT | — | |
| `pinctrl-names` | `"default"` | identical | PRESENT | — | |
| `phy-handle` | `<&eth_phy0>` | identical | PRESENT | — | |
| `phy-mode` | `"rgmii"` | `"rgmii"` **(open item)** | PRESENT | — | See §4.3. This is the one property in the file whose final value is not yet decided. |
| `snps,force_thresh_dma_mode = "1"` | added `0006`, removed `0014` | — | **DELETED** | — | Already gone downstream. Listed so the `0006` hunk is fully accounted for. Note it was also written as a *string*. |
| `snps,pbl = "32"` | present | — | **DELETED** | — | Written as a **string**, but stmmac reads it with `of_property_read_u32()` (`stmmac_platform.c`), which fails on a string property and leaves the default in place. **It never took effect.** Deleting it changes nothing at runtime and removes a comment that claims otherwise. |
| `rx-fifo-depth = <4096>` | present | — | **MOVED-TO-DTSI** | — | Mainline `meson-axg.dtsi` v6.12:291-292 carries the identical `rx-fifo-depth = <4096>` on this very node. stmmac reads it into `plat->rx_fifo_size`, which gates TSO. Restating it here creates a second place to get it wrong. |
| `tx-fifo-depth = <2048>` | present | — | **MOVED-TO-DTSI** | — | Same node, same file, same value. |
| `mdio/compatible` | `"snps,dwmac-mdio"` | identical | PRESENT | — | |
| `mdio/#address-cells` | `<1>` | identical | PRESENT | — | |
| `mdio/#size-cells` | `<0>` | identical | PRESENT | — | |
| `eth_phy0` label | present | present | PRESENT | — | |
| `ethernet-phy@0/reg` | `<0>` | identical | PRESENT | — | RTL8211F, `0x001cc916`. Needs `CONFIG_REALTEK_PHY=y` — **absent from Armbian's stock meson64 config**, which enables `ICPLUS_PHY` for JetHub instead. |
| `eee-broken-1000t` | present | identical | PRESENT | — | |
| `interrupt-parent` | `<&gpio_intc>` (from `0003`) | identical | PRESENT | — | |
| `interrupts` | `<98 IRQ_TYPE_LEVEL_LOW>` (from `0003`) | identical | PRESENT | — | hwirq 98 = GPIOY_14: `pinctrl-meson-axg.c:1012` declares `BANK("Y", GPIOY_0, GPIOY_15, 84, 99)`, so `irq_first` 84 + 14 = 98. GPIOY_0…13 are the RGMII bus; GPIOY_14 is the spare pad beside it, consistent with the PHY INTB line. **Phase 4 gate: 20 cable pulls must each bump this line's count in `/proc/interrupts`; a count stuck at 0 means the interrupt is decorative and phylib is polling.** |

### 4.2 `&nfc` — **NEW**

| Property | Value | Class | Note |
|---|---|---|---|
| `&nfc { status = "disabled"; }` | — | **NEW** | Mainline gained `nand-controller@7800` *after* the 5.4 vendor tree forked, and it carries **no `status` property**, i.e. it defaults to `okay`. Its second reg window (`reg-names = "emmc"`) **is** `&sd_emmc_c`'s register block, and its `pinctrl-0 = <&nand_all_pins>` claims `emmc_nand_d0..d7` — the same pads as `&emmc_pins`. Armbian's meson64 config ships `CONFIG_MTD_NAND_MESON=m`, so `meson_nand` exists and *will* bind. There is no NAND on this board. Belt and braces in the config delta: `CONFIG_MTD_NAND_MESON=n` plus `MODULES_BLACKLIST="meson_nand"`. |

This is the one entry in the audit that exists purely because *mainline moved*,
not because the board changed. It is also the most likely cause of a
"sometimes root does not mount" bug if it is ever dropped.

### 4.3 Open item — the RGMII delay

Not a defect in the port; a measurement that has not been taken yet.

5.4's `rtl8211f_config_init()` programmed only the **TX** delay (paged register
`0xd08` reg 17 bit 8) and left the **RX** delay (`0xd08` reg 21 bit 3) at
whatever the PHY strapped or retained. Mainline programs **both** from
`phy-mode`, so `phy-mode = "rgmii"` will actively *clear* an RX delay the
working 5.4 system may have been relying on. The failure mode is not "no link"
— it is asymmetric packet loss that TCP hides inside an aggregate iperf3 number.

Procedure (Phase 5, recorded in `docs/HARDWARE.md` §13):

1. Read `0xd08` regs 17 and 21 on 5.4, PHY powered and linked.
2. Cold power cycle, **mains removed ≥ 10 s** — the paged registers persist
   across a warm reset, so a soft reboot contaminates the comparison.
3. Read the same two registers on 6.12 with this DTS.
4. If 6.12 shows RX delay cleared where 5.4 had it set, change to
   `phy-mode = "rgmii-rxid";` and re-run the **per-direction** iperf3
   comparison.

Do not "fix" this by eyeballing aggregate throughput.

---

## 5. `&sd_emmc_c`, `&pwm_ab`, `&pwm_cd`, `&uart_AO`

### 5.1 `&sd_emmc_c` — root device for both slots, `/data` and recovery

Every property here is a byte-for-byte carry-over of the configuration known to
work on this hardware (`0001` + `0002`).

| Property | Old | New | Class | Δ |
|---|---|---|---|---|
| `status` | `"okay"` | identical | PRESENT | — |
| `pinctrl-0` | `<&emmc_pins>` | identical | PRESENT | — |
| `pinctrl-1` | `<&emmc_clk_gate_pins>` | identical | PRESENT | — |
| `pinctrl-names` | `"default", "clk-gate"` | identical | PRESENT | — |
| `bus-width` | `<8>` | identical | PRESENT | — |
| `cap-mmc-highspeed` | present | present | PRESENT | — |
| `max-frequency` | `<200000000>` (`0002`) | identical | PRESENT | — |
| `non-removable` | present | present | PRESENT | — |
| `disable-wp` | present | present | PRESENT | — |
| `mmc-ddr-1_8v` | present | present | PRESENT | — |
| `mmc-hs200-1_8v` | present | present | PRESENT | — |
| `mmc-pwrseq` | `<&emmc_pwrseq>` | identical | PRESENT | — |
| `vmmc-supply` | `<&vcc_3v3>` | identical | PRESENT | — |
| `vqmmc-supply` | `<&vddio_boot>` | identical | PRESENT | — |

**Deliberate deviation from the reference boards:** `meson-axg-s400.dts` and
`meson-axg-jethome-jethub-j1xx.dtsi` use `pinctrl-0 = <&emmc_pins>,
<&emmc_ds_pins>;`. This board uses `<&emmc_pins>` alone, exactly as downstream
did. `emmc_ds` is the HS400 data strobe; this board only advertises
`mmc-hs200-1_8v`, so DS is never driven, and muxing BOOT_14 to the eMMC function
would be an unverified pad change on a device that cannot be recovered
remotely. Not a regression — a refusal to change something.

`/sys/kernel/debug/mmc0/ios` on the new kernel must match the 5.4 baseline
recorded in `docs/HARDWARE.md` §4 for **timing spec, clock and bus width**.

### 5.2 `&pwm_ab` / `&pwm_cd`

| Property | Old | New | Class |
|---|---|---|---|
| `&pwm_ab { status }` | `"okay"` | identical | PRESENT |
| `&pwm_ab { pinctrl-0 }` | `<&pwm_a_a_pins>, <&pwm_b_a_pins>` | identical | PRESENT |
| `&pwm_ab { pinctrl-names }` | `"default"` | identical | PRESENT |
| `&pwm_cd { status }` | `"okay"` | identical | PRESENT |
| `&pwm_cd { pinctrl-0 }` | `<&pwm_c_a_pins>` | identical | PRESENT |
| `&pwm_cd { pinctrl-names }` | `"default"` | identical | PRESENT |

On 6.12 the dtsi still uses `amlogic,meson-axg-ee-pwm` (old driver, no `clocks`
property). The `amlogic,meson-axg-pwm-v2` conversion with clock parents in the
dtsi is present by 6.18. `#pwm-cells` is 3 on both, so nothing here changes —
but re-measure the 128 Hz LED period after any branch bump.

### 5.3 `&uart_AO` — the only out-of-band access this box has

| Property | Old | New | Class |
|---|---|---|---|
| `status` | `"okay"` | identical | PRESENT |
| `pinctrl-0` | `<&uart_ao_a_pins>` | identical | PRESENT |
| `pinctrl-names` | `"default"` | identical | PRESENT |

---

## 6. Non-DTS content of the patches

| Item | Class | Note |
|---|---|---|
| `drivers/leds/leds-pwm.c` hunk (`0005`) | **DELETED** | Read a non-standard `brightness` fwnode property into `led_data->cdev.brightness`. Replaced by `default-state = "on"`, which mainline supports natively. |
| `include/linux/leds_pwm.h` hunk (`0005`) | **DELETED** | The header itself no longer exists upstream. This alone makes `0005` unportable. |
| `arch/arm64/boot/dts/amlogic/Makefile` hunks (`0001`, `0004`, `0013`) | **DELETED** | Replaced by Armbian's `auto-patch-dt-makefile` rule in `patch/kernel/archive/meson64-<ver>/0000.patching_config.yaml`, which rewrites the Makefile itself from whatever `dts-directories` copied in. |

> **Consequence for the drop mechanism:** `dts-directories` copies `*.dts`
> **only**. A companion `.dtsi` would not be copied and the build would fail on
> a missing include. The board file must stay self-contained; the only
> `#include`s permitted are ones that already exist in the kernel tree
> (`meson-axg.dtsi` and `dt-bindings/...`).

---

## 7. Mandated verification — producing and diffing the DTBs

The plan's Phase 3 evidence is a `dtc -I dtb -O dts` diff, old vs new. Doing it
naively produces thousands of lines of noise, because `meson-axg.dtsi` itself
changed enormously between 5.4 and 6.12. The procedure below separates the two
kinds of delta so the board-owned one is actually reviewable.

### 7.1 Get the two DTBs

```sh
# OLD — off the device, from the running slot. This is the real, shipping DTB.
ssh root@omni 'cat /boot/meson-axg-apollo.dtb' > old-5.4.dtb

# NEW — built from board/meson-axg-apollo.dts without a full Armbian run
tools/validate-dts.sh --strict --out /tmp/dtsval
cp /tmp/dtsval/meson-axg-apollo.dtb new-6.12.dtb
```

> **Do not use `/sys/firmware/fdt` for this comparison.** That is the tree
> U-Boot handed the kernel, i.e. the on-disk DTB *plus* U-Boot's fixups:
> `local-mac-address`/`mac-address` injected into the `ethernet0` node by
> `fdt_fixup_ethernet()`, `/chosen/bootargs`, and
> `linux,initrd-start`/`linux,initrd-end`. Use it for exactly one thing —
> §7.4, proving the MAC injection still happens.

### 7.2 Normalise, then diff

`dtc`'s `-s` flag sorts nodes and properties, which is what makes the diff
stable. Phandle values are allocation order and carry no meaning, so strip them.

```sh
norm() {
  dtc -I dtb -O dts -s "$1" 2>/dev/null \
    | sed -E '/^[[:space:]]*(linux,)?phandle = /d' \
    | sed -E 's/[[:space:]]+$//'
}

norm old-5.4.dtb  > old.dts
norm new-6.12.dtb > new.dts
diff -u old.dts new.dts > full.diff ; echo "full diff: $(wc -l < full.diff) lines"
```

`full.diff` is **informational only**. Expect it to be large and to be dominated
by `meson-axg.dtsi` churn (new clock controllers, new bindings, renamed
`simple-bus` wrappers, `nand-controller@7800` appearing, etc.). Nothing in it
that lives outside a node this document names is ours.

### 7.3 The diff that actually gates Phase 3

Extract only the board-owned subtrees and diff those. `subtree` pulls a node by
its unit name out of a decompiled DTS by brace counting:

```sh
subtree() {   # subtree <file> <node-unit-name>
  awk -v n="$2" '
    !inblk && $0 ~ ("(^|[ \t])" n "[ \t]*\\{[ \t]*$") { inblk=1; depth=0 }
    inblk {
      print
      depth += gsub(/\{/,"{")
      depth -= gsub(/\}/,"}")
      if (depth <= 0) inblk=0
    }' "$1"
}

# Board-owned node unit names. Find the exact spellings once with:
#   grep -nE '^\s*[a-z0-9_-]+(@[0-9a-f]+)?\s*\{' new.dts | less
for n in aliases chosen "memory@0" reserved-memory "ramoops@f400000" \
         emmc-pwrseq led-controller gpio-keys-polled thermal-zones \
         "ethernet@ff3f0000" "mmc@7000" "serial@3000" \
         "pwm@1b000" "pwm@2000" "nand-controller@7800"; do
  { echo "### $n (old)"; subtree old.dts "$n"; } >> ours-old.txt
  { echo "### $n (new)"; subtree new.dts "$n"; } >> ours-new.txt
done

diff -u ours-old.txt ours-new.txt
```

The `ramoops@f9800000` → `ramoops@f400000` rename means the old side will need
the old unit name; run the loop twice or add both names. The `@` addresses for
`ethernet`, `mmc`, `serial` and `pwm` come from `meson-axg.dtsi` and are stable
across 5.4 → 6.12 — but **look them up rather than trusting this list**, with
the `grep` shown in the comment.

**Every line of that diff must map to a row in §3, §4 or §5.** Anything that
does not is an unaudited change: stop, do not proceed to Phase 4, and either add
the row (with a reason) or revert the change.

### 7.4 Spot checks worth doing on the device

```sh
# a) the compiled DTB is the one U-Boot will load, under the captured name
ssh root@omni 'ls -la /boot/$(fw_printenv -n mender_dtb_name)'

# b) U-Boot still injects the MAC (do this AFTER the Phase 4 boot, on 6.12)
ssh root@omni 'od -An -tx1 /proc/device-tree/soc/*/ethernet@*/local-mac-address'
ssh root@omni 'fw_printenv -n ethaddr'          # must match, byte for byte

# c) the three new nodes actually instantiated
ssh root@omni 'ls /sys/class/leds/'             # apollo:power apollo:app1 apollo:app2
ssh root@omni 'ls /sys/class/thermal/'          # thermal_zone0 + cooling devices
ssh root@omni 'cat /proc/bus/input/devices'     # gpio-keys-polled
ssh root@omni 'ls /sys/fs/pstore/ 2>/dev/null'  # ramoops registered
ssh root@omni 'grep -c meson_nand /proc/modules' # must be 0 — &nfc is disabled
```

Check (b) is the one that silently matters: if the alias were dropped or renamed
the MAC injection stops, the box gets a random MAC on every boot, and the DHCP
reservation and the switch port config both stop working — while everything on
the serial console looks perfectly healthy.

### 7.5 Compile-time evidence

```sh
tools/validate-dts.sh --strict
```

Expected: **exactly four `dtc` warning lines**, two nodes
(`/soc/bus@ff634000/pinctrl@480` and `/soc/bus@ff800000/pinctrl@14`) × two
checks (`unit_address_vs_reg`, `simple_bus_reg`) — all raised against
`meson-axg.dtsi` itself, identically reproducible by compiling stock
`meson-axg-s400.dts`. `validate-dts.sh` deduplicates them and reports *"2
inherited from mainline dtsi, 0 attributable to meson-axg-apollo.dts"*.

**Any warning naming a line in `meson-axg-apollo.dts` is ours and must be
fixed**, not waived.

Then the Armbian-side check:

```sh
tools/sync-armbian-board.sh --dry-run && tools/sync-armbian-board.sh
cd armbian && ./compile.sh dts-check BOARD=avast-omni BRANCH=oldlts
```

---

## 8. Sign-off

| Item | Status |
|---|---|
| Old DTS reconstructed and archived (§1) | ☐ |
| `full.diff` (§7.2) produced and archived | ☐ |
| Board-owned diff (§7.3) produced, and **every line maps to a row above** | ☐ |
| `tools/validate-dts.sh --strict` clean (§7.5) | ☐ |
| `./compile.sh dts-check` clean | ☐ |
| `tools/check-kconfig-invariants.sh` passes on the built kernel | ☐ |
| Open item §4.3 (`phy-mode`) carried into `docs/HARDWARE.md` §13 | ☐ |
| Reviewed by | |
| Date | |

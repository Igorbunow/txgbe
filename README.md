# txgbe — Linux kernel module for LR-LINK LRES1002PF-2SFP+ (2×SFP+, 10GbE)

[![downloads](https://img.shields.io/github/downloads/Igorbunow/txgbe/total)](https://github.com/Igorbunow/txgbe/releases)
[![license](https://img.shields.io/badge/License-GPLv2-blue.svg)](./LICENSE)
[![kernel](https://img.shields.io/badge/kernel-3.18%20%E2%86%92%206.18-success)](#kernel-support)
[![ci](https://img.shields.io/github/actions/workflow/status/Igorbunow/txgbe/build.yml?branch=main)](https://github.com/Igorbunow/txgbe/actions)
[![release](https://img.shields.io/github/v/release/Igorbunow/txgbe)](https://github.com/Igorbunow/txgbe/releases)

This repository contains an out-of-tree Linux kernel module (**txgbe**) for the **LR-LINK LRES1002PF-2SFP+**
(dual SFP+, 10GbE) NIC family.

The main goal of this fork is **stable multi-LTS kernel compatibility** (especially for embedded / long-lived
systems) while avoiding regressions when new kernels are added.

---

## Why this fork exists

The vendor driver package was published under GPL, but practical support across multiple kernel branches
tended to break when new kernel versions were added quickly.

This fork focuses on:
- Keeping **existing kernels working** when adding support for new ones.
- Making **minimal, compatibility-focused changes** (no “drive-by refactors”).
- Using the existing **kcompat / feature-detection** approach (avoid “guessing” APIs based on kernel version alone).

---

## Kernel support

Target kernels (must not regress):
- **3.18**
- **4.1**
- **4.4**
- **4.9**
- **4.14**
- **4.19**
- **5.4**
- **5.10**
- **5.15**
- **6.1**
- **6.6**
- **6.12**
- **6.18**

> Note: some distributions backport API changes into “older” kernel versions. For that reason, this project
> prefers feature-detection (kcompat) over purely version-based logic.

### Latest compatibility update (hwmon deprecation on 5.15+)

The driver no longer relies only on legacy `hwmon_device_register()` when newer APIs are available.

Current registration flow:
- try `hwmon_device_register_with_info()` first
- fallback to `hwmon_device_register_with_groups()` if needed
- fallback to legacy `hwmon_device_register()` only if both fail

Implementation notes:
- uses kcompat feature detection (`HAVE_HWMON_DEVICE_REGISTER_WITH_INFO`, `HAVE_HWMON_DEVICE_REGISTER_WITH_GROUPS`)
- adds safe cleanup for hwmon error paths (`IS_ERR_OR_NULL` handling)
- keeps existing driver temperature sysfs attributes (`temp0_input`, `temp0_alarmthresh`, `temp0_dalarmthresh`)

Validation status:
- runtime validated with `insmod` on 5.15.148-tegra (Jetson AGX Orin): module load/unload works, link up/down works, MTU change to 9000 works
- matrix build validated:
  3.18.140, 4.1.52, 4.4.302, 4.9.337, 4.14.336, 4.19.325, 5.4.302, 5.10.250, 5.15.200, 6.1.163, 6.6.124, 6.12.71, 6.18.10

### Upstream LTS reference (what series to pick)

| Branch | Release Date | EOL Date (upstream) |
| ------ | ------------ | ------------------- |
| 2.6.32 | 2009-12-03   | 2016-02-01          |
| 3.0    | 2011-07-22   | 2016-10-01          |
| 3.2    | 2012-01-04   | 2018-05-01          |
| 3.4    | 2012-05-20   | 2016-09-01          |
| 3.10   | 2013-06-30   | 2017-11-01          |
| 3.12   | 2013-11-03   | 2016-04-01          |
| 3.14   | 2014-03-30   | 2016-09-01          |
| 3.16   | 2014-08-03   | 2017-03-01          |
| 3.18   | 2014-12-07   | 2017-06-01          |
| 4.1    | 2015-06-21   | 2017-09-01          |
| 4.4    | 2016-01-10   | 2022-02-01          |
| 4.9    | 2016-12-11   | 2023-01-07          |
| 4.14   | 2017-11-12   | 2024-01-10          |
| 4.19   | 2018-10-22   | 2024-12-05          |
| 5.4    | 2019-11-25   | 2025-12-03          |
| 5.10   | 2020-12-13   | 2026-12-31          |
| 5.15   | 2021-10-31   | 2026-10-31          |
| 6.1    | 2022-12-11   | 2027-12-31          |
| 6.6    | 2023-10-30   | 2026-12-31          |
| 6.12   | 2024-11-17   | 2026-12-31          |
| 6.18   | 2025-11-30   | 2027-12-01          |

---

## Repository layout (high level)

- `src/` — module sources and compatibility layer (`kcompat`)
- `scripts/` — helper scripts (if present)
- `txgbe.7` — documentation/manpage (vendor-provided)
- `LICENSE`, `COPYING` — GPLv2 license text

---

## Build prerequisites

You need:
- A kernel build tree or headers for the target kernel (referred to as `KERNELDIR`)
- `make`, a compiler toolchain (native or cross)
- Sufficient permissions if you plan to install the module system-wide

---

## Kernel headers prep helper (multi-series)

The script `tools/prepare_kernels_arm64.sh` downloads kernel tarballs and prepares headers (via `modules_prepare`) into
`/opt/kernels/<version>/build-<ARCH>` by default. It also supports selecting arbitrary LTS series, using alternate
kernel sources, and keeping compiler-specific build directories.

Key behaviors:
- Resolves latest patch versions per series (from `releases.json`, with CDN fallback when missing).
- Supports alternative download base via `KERNEL_SOURCE_BASE` / `--kernel-source-base`.
- Records compiler metadata in each build dir (`.toolchain-info`) to detect mismatches on subsequent runs.

### Common usage

Prepare the default supported series:

```bash
sudo tools/prepare_kernels_arm64.sh
```

Prepare only selected series:

```bash
sudo tools/prepare_kernels_arm64.sh --kernels-list "4.14 4.19 5.10"
```

Use the latest available patch level for each selected series:

```bash
sudo tools/prepare_kernels_arm64.sh --latest-all --kernels-list "4.4 4.9 4.14"
```

Use a local releases lock file:

```bash
sudo RELEASES_JSON=/etc/kernel-build/releases.json tools/prepare_kernels_arm64.sh
```

Dry-run (show plan only):

```bash
sudo tools/prepare_kernels_arm64.sh --dry-run --kernels-list "4.14 4.19"
```

Print the upstream LTS reference table:

```bash
tools/prepare_kernels_arm64.sh --lts-reference
```

### Compiler-aware rebuild policy

If a build directory already exists, the script checks which compiler prepared it and compares with the currently
selected compiler. The comparison is soft on major version and strict on full version. When it detects a mismatch,
you can choose how to proceed:

- Prompt (default): interactive choice to rebuild or keep.
- `--mismatch-rebuild`: delete the build dir and rebuild non-interactively.
- `--mismatch-skip`: keep the build dir and skip non-interactively.
- `--quiet`: disable prompting; requires one of the non-interactive policies above.

Examples:

```bash
sudo tools/prepare_kernels_arm64.sh --mismatch-rebuild
sudo tools/prepare_kernels_arm64.sh --mismatch-skip
sudo tools/prepare_kernels_arm64.sh --quiet --mismatch-rebuild
```

### Compiler-specific build directories

When you need parallel trees for different toolchains, enable a compiler-specific subdirectory:

```bash
sudo tools/prepare_kernels_arm64.sh --toolchain-subdir
```

This changes the build layout to:

```
/opt/kernels/<version>/build-<ARCH>/<compiler-tag>/
```

### Alternate kernel source base

Use a different CDN/root for tarballs:

```bash
sudo tools/prepare_kernels_arm64.sh --kernel-source-base https://cdn.kernel.org/pub/linux/kernel
```

---

## Build (native, same machine/kernel)

Build against the currently running kernel (typical kbuild approach):

```bash
make -C /lib/modules/$(uname -r)/build M=$PWD/src modules -j"$(nproc)"
````

Output: `src/txgbe.ko`

---

## Cross-build (arm64) — required one-liner

The command below is intentionally formatted exactly as a single line, with generic paths:

```bash
export ARCH=arm64; export CROSS_COMPILE=aarch64-linux-gnu-; export KERNELDIR=/path/to/kernel/tree; make -C $KERNELDIR M=/path/to/txgbe/src modules -j`nproc`
```

---

## Install / load

### Temporary (for quick testing)

```bash
sudo insmod src/txgbe.ko
# or, if installed into module tree:
sudo modprobe txgbe
```

Verify:

```bash
dmesg | tail -n 200
ip link
ethtool -i <iface>
```

### System installation (into the kernel module tree)

```bash
sudo make -C "$KERNELDIR" M="$PWD/src" modules_install
sudo depmod -a
```

---

## Compatibility layer (kcompat) — important

This driver uses a compatibility layer designed to detect kernel features and select the correct
wrappers/backports for each kernel.

General rules:

* Autogenerated compatibility defines are produced during build for the **exact** target kernel headers.
* Do **not** commit autogenerated headers into git.
* Prefer feature flags (HAVE_/NEED_) over version-based guesses.

See `AGENTS.md` and `ARCHITECTURE.md` in this repository for project rules and structure.

---

## Troubleshooting

This driver relies on an autogenerated compatibility header (`kcompat_generated_defs.h`) produced for the
**exact** target kernel headers specified by `KERNELDIR`. Many “mysterious” build failures are caused by
a mismatch between the kernel you compile against and the kernel used to generate `kcompat` defines.

### 1) Symptom: build errors after switching `KERNELDIR`
**Typical errors**
- `error: too few arguments to function ‘netif_napi_add’`
- `error: ‘struct ethtool_rxfh_param’ has no member named ...`
- `error: implicit declaration of function ...`
- `warning treated as error: incompatible pointer type ...`

**Most likely cause**
`kcompat_generated_defs.h` was generated for a *different* kernel tree than the current `KERNELDIR`.

**Fix**
Do a clean rebuild against the new `KERNELDIR`:

```bash
make -C "$KERNELDIR" M="$PWD/src" clean
make -C "$KERNELDIR" M="$PWD/src" modules -j"$(nproc)"
````

If the build system still reuses stale outputs, force a full rebuild:

```bash
make -B -C "$KERNELDIR" M="$PWD/src" modules -j"$(nproc)"
```

---

### 2) Symptom: `kcompat_generated_defs.h` is “stuck” and does not regenerate

**Typical behavior**

* `make kcompat-generated` (or the generator step) does not run even after changing `KERNELDIR`
* You see the same errors across different kernels

**Fix**
Ensure the generated header is removed and rebuilt:

```bash
rm -f src/kcompat_generated_defs.h
make -C "$KERNELDIR" M="$PWD/src" modules -j"$(nproc)"
```

---

### 3) Symptom: generator cannot find kernel config header (`autoconf.h`)

**Typical errors**

* `fatal error: generated/autoconf.h: No such file or directory`
* `fatal error: linux/autoconf.h: No such file or directory`

**Cause**
`KERNELDIR` does not point to a prepared kernel build tree/headers, or the target kernel was not configured.

**Fix**
Point `KERNELDIR` to a proper build directory (headers + generated files).
For full kernel trees, run at least:

```bash
make olddefconfig
make prepare modules_prepare
```

(Exact commands may differ depending on how your distro packages kernel headers.)

---

### 4) Symptom: compile works for one kernel but fails on another with API/signature errors

**Cause**
The driver uses kernel feature detection. If the build is not fully clean, or if the wrong headers are used,
`kcompat` flags may not match the actual target kernel API.

**Fix**

* Rebuild clean for each kernel (see #1).
* Verify you are not mixing headers from one kernel with a different build directory.

---

### 5) How to sanity-check which kernel `kcompat` was generated for

If your `kcompat_generated_defs.h` contains a provenance line (recommended), check it:

```bash
grep -nE "KSRC|KERNEL|Autogenerated|generated" src/kcompat_generated_defs.h | head -n 20
```

If not present, the safest approach is still: delete the generated header and rebuild (see #2).

---

### 6) Symptom: cross-build fails with missing toolchain or wrong `ARCH`

**Typical errors**

* `aarch64-linux-gnu-gcc: command not found`
* `unknown register name ...` / `wrong ELF class ...`

**Fix**

* Confirm your cross toolchain is installed and `CROSS_COMPILE` prefix is correct.
* Confirm `ARCH` matches the target.

Example (arm64):

```bash
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export KERNELDIR=/path/to/kernel/tree
make -C "$KERNELDIR" M="$PWD/src" modules -j"$(nproc)"
```

Example (x86):

```bash
export ARCH=x86
export CROSS_COMPILE=""
export KERNELDIR=/path/to/kernel/tree
make -C "$KERNELDIR" M="$PWD/src" modules -j"$(nproc)"
```

---

### 7) When reporting an issue

Please include:

* target kernel version and distro (or exact kernel source tree)
* your `KERNELDIR`, `ARCH`, `CROSS_COMPILE`
* full build log (first error matters most)
* `dmesg` output if the module loads but the device does not appear

## Original source / provenance

This repository is based on the **vendor-provided driver package** (GPL) from the official LR-LINK website:

* [https://www.lr-link.com.cn/](https://www.lr-link.com.cn/)
* [https://www.lr-link.com/](https://www.lr-link.com/)

If you need vendor support, contact:

* **Wangxun support team** via **[support@trustnetic.com](mailto:support@trustnetic.com)**

> Disclaimer: this GitHub repository is community-maintained and is not an official LR-LINK support channel.

---

## Contributing

PRs are welcome, especially for kernel-compat fixes. Please:

* Keep patches minimal and compatibility-focused (no refactors “just because”).
* Validate builds across the supported kernel matrix.
* Attach build logs for any failing kernel version.

---

## License

GPLv2 — see [`LICENSE`](./LICENSE) and [`COPYING`](./COPYING).

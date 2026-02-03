# Kernel Headers Preparation Utility

This utility prepares **Linux kernel build trees** for **out-of-tree module compilation**
using `modules_prepare`, across **multiple kernel versions** and **multiple architectures**.

It is designed for:
- driver developers
- CI pipelines
- cross-compilation environments
- long-term support of multiple kernel series (including EOL kernels)

The script is **idempotent**, **deterministic by default**, and supports optional
automatic fallback to newer kernel releases when explicitly enabled.

---

## What This Script Does

For each configured kernel version, the script:

1. Downloads the corresponding kernel source tarball from `cdn.kernel.org`
2. Verifies tarball integrity (`tar -tf`)
3. Extracts kernel sources
4. Prepares a build directory (`O=...`) for external modules:
   - imports `.config` if provided
   - runs `defconfig` if needed
   - runs `olddefconfig`
   - runs `modules_prepare`
5. Caches all results and **never re-downloads or rebuilds** unless explicitly requested

The result is a ready-to-use `KERNELDIR` suitable for:
```bash
make -C $KERNELDIR M=/path/to/module modules
````

---

## Directory Layout

By default, all kernels are prepared under:

```
/opt/kernels/<kernel-version>/
 ├── _dl/               # downloaded tarballs
 ├── src/
 │    └── linux-<ver>/  # extracted kernel sources
 └── build-<ARCH>/      # prepared build directory (KERNELDIR)
```

Example:

```
/opt/kernels/5.15.198/build-arm64
```

---

## Requirements

* Debian 12/13 (or compatible)
* Root privileges (writes to `/opt`)
* Tools:

  * `gcc` or cross-compiler
  * `make`, `tar`, `curl`, `jq`
  * kernel build dependencies (`bc`, `bison`, `flex`, `libelf-dev`, etc.)

Example:

```bash
apt install build-essential bc bison flex libelf-dev jq curl
```

---

## Kernel Version Lock File (`releases.json`)

Kernel versions are defined via a **local lock file**:

```json
{
  "kernels": [
    { "series": "4.19", "version": "4.19.325" },
    { "series": "5.4",  "version": "5.4.287" },
    { "series": "5.10", "version": "5.10.221" },
    { "series": "5.15", "version": "5.15.166" },
    { "series": "6.1",  "version": "6.1.78" },
    { "series": "6.6",  "version": "6.6.63" },
    { "series": "6.12", "version": "6.12.14" },
    { "series": "6.18", "version": "6.18.0" }
  ]
}
```

This guarantees **reproducible builds** even when kernel.org APIs change.

---

## Basic Usage

### Prepare kernels for arm64 (cross-build)

```bash
./prepare_kernels_arm64.sh \
  --arch arm64 \
  --cross-compile aarch64-linux-gnu- \
  --releases-json /etc/kernel-build/releases.json
```

### Prepare kernels for native x86_64

```bash
./prepare_kernels_arm64.sh \
  --arch x86_64 \
  --cross-compile "" \
  --releases-json /etc/kernel-build/releases.json
```

---

## Dry Run Mode (Recommended First Step)

Show what **would** be done without modifying the system:

```bash
./prepare_kernels_arm64.sh \
  --arch x86_64 \
  --cross-compile "" \
  --releases-json /etc/kernel-build/releases.json \
  --dry-run
```

Output includes:

* selected kernel versions
* tarball URLs
* local paths
* detected state (downloaded / extracted / prepared)
* planned actions (`skip / download / extract / prepare`)

---

## Architecture Selection

```bash
--arch <arch>
```

Examples:

* `arm64`
* `x86_64`
* `arm`
* `riscv`

The script:

* passes `ARCH=<arch>` to Kbuild
* validates that `.config` matches the selected architecture
* validates that the compiler matches the architecture

---

## Toolchain Selection

```bash
--cross-compile <prefix>
```

Examples:

* `aarch64-linux-gnu-`
* `arm-linux-gnueabihf-`
* `""` (empty = native compiler)

The script:

* verifies the compiler exists
* prints `gcc --version`
* prints `gcc -dumpmachine`
* **fails early** if compiler and ARCH do not match

This prevents errors like:

```
aarch64-linux-gnu-gcc: error: unrecognized argument '-mcmodel=kernel'
```

---

## Importing Kernel `.config` Files (Optional)

```bash
--config-dir /path/to/configs
```

Supported lookup order:

```
<dir>/<ARCH>/<full-version>/.config
<dir>/<ARCH>/<series>/.config
<dir>/<full-version>/.config
<dir>/<series>/.config
```

Example:

```
/opt/kernel-configs/arm64/5.15/.config
```

If no config is found, `defconfig` is used.

The script validates that `.config` matches the selected ARCH.

---

## Updating to Newer Kernel Releases (Optional)

### Use latest available for all series

```bash
--latest-all
```

* Queries kernel.org
* Selects the newest available version per series
* Verifies tarball availability on CDN
* **Does not modify your lock file**

### Use latest only if pinned version is broken

```bash
--latest-on-broken
```

Triggered if:

* tarball does not exist (404)
* tarball is corrupted

Best balance between **stability** and **self-healing CI**.

---

## Forcing Rebuilds (Normally Not Needed)

```bash
--force            # everything
--force-download   # re-download tarballs
--force-extract    # re-extract sources
--force-prepare    # rerun defconfig / modules_prepare
```

---

## Strict Mode

```bash
--strict
```

In strict mode:

* missing tarballs cause immediate failure
* corrupted downloads cause immediate failure
* no silent skips

Recommended for CI validation.

---

## Typical CI Workflow

```bash
# Step 1: dry run
./prepare_kernels_arm64.sh --dry-run ...

# Step 2: real preparation
./prepare_kernels_arm64.sh ...

# Step 3: build module
make -C /opt/kernels/5.15.198/build-arm64 M=$PWD modules
```

---

## Guarantees

* No silent cross-architecture mismatches
* No implicit rebuilds
* Deterministic by default
* Explicit, opt-in “latest” behavior
* Safe for long-lived CI systems

---

## License

This script is intended as an infrastructure utility.
Use, modify, and integrate freely within your projects.


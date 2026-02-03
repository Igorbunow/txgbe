# ARCHITECTURE.md

## Overview
This repository provides the out-of-tree Linux kernel module `txgbe` for WangXun-based
10GbE PCIe NICs (e.g. LR-LINK LRES1002PF-2SFP+). The primary goal is **multi-LTS kernel
compatibility** without regressions.

Supported kernel targets:
- 4.19, 5.4, 5.10, 5.15, 6.1, 6.6, 6.12, 6.18

## Repository layout
- `src/` — driver sources and compatibility layer
  - `txgbe_main.c` — main netdev implementation, PCI probe/remove, datapath glue
  - `txgbe_ethtool.c` — ethtool ops (feature-dependent signatures vary by kernel)
  - `txgbe_lib.c` — queue/vector allocation, NAPI integration (often API-changes)
  - `txgbe_ptp.c` — PTP / HW timestamp support (kernel API varies widely)
  - `kcompat*.h`, `kcompat*.c` — compatibility layer (feature flags + backports)
  - `generated.sh`, `kcompat-generator.sh` — feature detection and generated defs
- `scripts/` — packaging / helper scripts (if present)
- `*.spec`, `kmod-*.spec` — RPM packaging artifacts (vendor-provided)

## Build system
The build is out-of-tree but integrates with kbuild:
- Typical build:
  `make -C "$KERNELDIR" M="$PWD/src" modules`

Key requirement: `src/kcompat_generated_defs.h` must be generated for the **same**
kernel tree/headers used for compilation.

## Compatibility system (kcompat)
### Why it exists
Kernel APIs for networking drivers change between LTS releases (netdev ops, ethtool ops,
XDP helpers, NAPI helpers, PCI/MSI APIs, etc.). To avoid scattering version checks across
driver code, this repo uses a compatibility layer.

### Components
1. **Feature detection**
   - `src/generated.sh` selects the best CONFIG header (`autoconf.h`) and include roots.
   - It runs `src/kcompat-generator.sh`, which scans kernel headers and emits feature flags.
   - Output file: `src/kcompat_generated_defs.h`

2. **Definitions include chain**
   - `kcompat_generated_defs.h` (autogen) -> included by `kcompat_defs.h`
   - `kcompat.h` provides a consolidated interface for driver sources.

3. **Backports and wrappers**
   - `kcompat_impl.h` contains wrapper macros and backported implementations guarded by
     `HAVE_*` / `NEED_*` flags.

### Project policy
- Prefer `HAVE_*` / `NEED_*` checks over `LINUX_VERSION_CODE` logic.
- If kernel-version checks are unavoidable due to distro backports, isolate them in
  `kcompat_impl.h` with clear rationale.

## How to add support for a new kernel version
1. Build against that kernel tree/headers and collect the first error.
2. Ensure `kcompat_generated_defs.h` is regenerated for that kernel (clean build).
3. Decide the smallest fix:
   - Missing feature flag -> update generator rule.
   - Signature mismatch -> add/adjust wrapper in `kcompat_impl.h`.
   - Only if unavoidable -> guard code in driver sources with HAVE_/NEED_ flags.
4. Rebuild the full kernel matrix (all supported versions).
5. Document any new flags or wrappers.

## Regression prevention (must)
- Never validate on only one kernel.
- Keep changes minimal and localized.
- Do not introduce “new features” to satisfy newer kernels unless required to build.
- Keep `kcompat_generated_defs.h` out of git; add it to `.gitignore`.

## Recommended CI (GitHub Actions)
Implement a build matrix that compiles `src/` against a set of kernel header trees (or
container images) corresponding to the supported versions. CI must fail on any build error.

(Implementation details depend on where kernel header trees are sourced from.)


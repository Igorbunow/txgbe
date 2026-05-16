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

## LoongArch / Loongson performance bring-up notes

The Loongson-3A6000 validation exposed several performance-sensitive areas that
are useful on other architectures too, but must remain opt-in unless a platform is
known to need them.

### IRQ, RSS and CPU affinity

The driver allocates MSI-X q_vectors per adapter. On a two-port 10G NIC, legacy
q_vector-to-CPU mapping can put both ports on the same CPU set. This may cap
aggregate throughput even when each port can reach 10G independently.

For an 8-core Loongson-3A6000 system, the validated debug configuration uses:

```text
RSS=4,4
txgbe_force_irq_affinity=1
txgbe_port_affinity_spread=1
```

Expected mapping:

```text
port0 q_vectors -> CPU0..CPU3
port1 q_vectors -> CPU4..CPU7
```

This avoids both ports competing for exactly the same softirq/IRQ CPUs.

### Tx write-back threshold

The original code programmed a high Tx descriptor write-back threshold even for
very low or disabled interrupt throttling modes. On LoongArch this can make Tx
completion behavior more fragile under heavy load. The `txgbe_tx_wthresh_safe`
parameter keeps the old behavior by default on non-LoongArch platforms, while
allowing LoongArch bring-up to use a safer threshold.

Policy:
- Do not make Loongson-specific tuning global without cross-architecture testing.
- Keep runtime parameters available for A/B testing.
- Keep diagnostic logging disabled by default.

### SFP status polling

Some copper SFP/internal PHY polling paths may cause link flaps or misleading link
state transitions on sensitive setups. The `txgbe_sfp_status_poll` parameter allows
that polling to be disabled during diagnostics. It is not a universal fix: disabling
polling may reduce hotplug/status responsiveness.

Use `txgbe_link_diag=1` or `2` only while collecting evidence for link-state bugs.

### Test methodology requirements

Dual-port throughput tests must be deterministic:
- bind each client with `iperf3 -B <source-ip>`;
- use different destination IPs/subnets for each port;
- verify `ip route get <dst> from <src>` before testing;
- check `/proc/interrupts` and `/proc/irq/*/smp_affinity_list`;
- watch `ethtool -S` counters, especially `rx_crc_errors`, `rx_no_buffer_count`,
  `rx_missed_errors`, `tx_timeout_count`, and flow-control counters.

Fast-growing `rx_crc_errors` should be treated as a physical link problem first:
swap SFP modules, cables and remote switch/server ports before changing datapath
logic.


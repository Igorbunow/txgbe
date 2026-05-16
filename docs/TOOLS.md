# Project Tools and Scripts Descriptions

[ English ](TOOLS.md) | [ Русский ](TOOLS_ru.md)

This document describes the purpose and usage of scripts located in the `tools/` directory.

## Root tools/ Directory

### `build_matrix.sh`
Automates building the kernel module against multiple kernel versions. It uses `KERNELDIRS` environment variable to find kernel trees.
- **Usage:** `export KERNELDIRS="/path/to/k1 /path/to/k2"; ./tools/build_matrix.sh`
- **Key Features:** Clean build by default, logs results to `logs/`, continues on error if `KEEP_GOING=1`.

### `build_one.sh`
Helper script to build the module for a single specific kernel.
- **Usage:** `KERNELDIR=/path/to/kernel ./tools/build_one.sh`

### `prepare_kernels_arm64.sh`
A comprehensive utility to download and prepare kernel headers/build trees for multiple architectures and versions.
- **Usage:** See [prepare_kernels.md](prepare_kernels.md) for detailed instructions.
- **Key Features:** Idempotent, supports cross-compilation, manages `releases.json`.

### `txgbe_client_dual_iperf_bound.sh`
Client-side script for deterministic dual-port `iperf3` testing. Binds each iperf instance to a specific source IP and destination.
- **Usage:** Used for performance validation on dual-port NICs.

### `txgbe_server_dual_iperf_bound.sh`
Server-side counterpart for `txgbe_client_dual_iperf_bound.sh`. Starts two `iperf3` servers bound to different IPs.

### `verify_kcompat_switch.sh`
Utility to verify that `kcompat` definitions are correctly regenerated when switching between different kernel versions.

### `first_errors.sh`
A simple helper to extract the first few errors from a build log.

### `releases.json`
Not a script, but a configuration file containing pinned kernel versions for the preparation utility.

---

## tools/test/ Directory

### `txgbe_client_dual_iperf_bound_v2.sh` / `v3.sh`
Evolutionary versions of the dual-port iperf client script with improved logic or parameters.

### `txgbe_loongarch_collect_diag_v2.sh`
Specific diagnostic collection script for Loongson-3A6000 systems. Collects IRQ mappings, ethtool stats, and dmesg.

### `txgbe_loongarch_tune_v2.sh`
Performance tuning script for Loongson systems. Sets RSS, IRQ affinity, and other module parameters.

### `txgbe_server_iperf_config_fixed_v2.sh`
Updated server-side iperf configuration script.

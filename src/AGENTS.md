# Repository Guidelines

## Project Structure & Module Organization
- `src/` holds the Linux kernel driver sources (`txgbe_*.c`, `txgbe_*.h`) plus compatibility layers (`kcompat*.{c,h}`) and build tooling (`Makefile`, `configure`, `common.mk`).
- `scripts/` contains helper utilities such as `scripts/set_irq_affinity`.
- Top-level packaging/manpage files live in the repo root (e.g., `txgbe.7`, `*.spec`).

## Build, Test, and Development Commands
Run commands from `src/`.
- `make` builds the kernel module with standard verbosity.
- `make noisy` builds with `V=1` for detailed output.
- `make clean` removes build artifacts.
- `make sparse` runs the sparse static analyzer (requires sparse installed).
- `make ccc` runs coccicheck (requires coccinelle).
- `make manfile` builds the gzipped manpage from `../txgbe.7`.
- `make help` lists all supported targets and variables.

## Coding Style & Naming Conventions
- Code is C in Linux kernel style; follow existing patterns in `txgbe_*.c`.
- Use tabs for indentation, align wrapped lines to match nearby code, and keep braces consistent with current files.
- Macros and feature flags live in headers like `txgbe.h` and `kcompat*.h`; prefer adding new flags there rather than scattering magic values.

## Testing Guidelines
- There are no unit-test targets in this source snapshot.
- Validate changes by building against the target kernel and using static analysis (`make sparse`, `make ccc`) where available.
- When changing hardware paths or compat code, build for at least one representative kernel version used in deployment.

## Commit & Pull Request Guidelines
- This snapshot does not include a `.git` history, so no commit convention can be inferred.
- Use clear, imperative subjects (e.g., “Fix MSI-X interrupt cleanup”) and include rationale in the body when behavior changes.
- In PRs, include: what changed, kernel version(s) built against, and any relevant hardware/feature coverage (e.g., SR-IOV, XDP).

## Security & Configuration Tips
- Kernel headers for the target kernel must be installed and discoverable by the build system.
- Avoid changing module parameters or sysfs/procfs interfaces without documenting the impact in `txgbe.7`.

#!/usr/bin/env bash
set -euo pipefail

# Prepare Linux kernel trees for external module builds (modules_prepare)
# Target: Debian 13 host, cross-build for arm64 via aarch64-linux-gnu-
# Output layout:
#   /opt/kernels/<full-version>/src
#   /opt/kernels/<full-version>/build-arm64
#
# Needs: curl, xz, tar, jq, make, and basic build deps.
#
# Run as root (or via sudo), since /opt/kernels is used.

ARCH="${ARCH:-arm64}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
BASE_DIR="${BASE_DIR:-/opt/kernels}"
JOBS="${JOBS:-$(nproc)}"

RELEASES_JSON_URL="https://www.kernel.org/releases.json"
# Optional local releases json file (lock-file).
# You can set it via environment: RELEASES_JSON=/etc/kernel-build/releases.json
# or via CLI: --releases-json /etc/kernel-build/releases.json
RELEASES_JSON="${RELEASES_JSON:-}"

# Behavior controls:
#   FORCE_*: re-download / re-extract / re-prepare only on explicit request
FORCE_DOWNLOAD=0
FORCE_EXTRACT=0
FORCE_PREPARE=0
STRICT=0

DEFAULT_KERNEL_SOURCE_BASE="https://cdn.kernel.org/pub/linux/kernel"
ENV_KERNEL_SOURCE_BASE="${KERNEL_SOURCE_BASE:-}"
CLI_KERNEL_SOURCE_BASE=""
KERNEL_SOURCE_BASE="${DEFAULT_KERNEL_SOURCE_BASE}"

# Optional directory with per-kernel configs to import into O= build dir
# Can be set via env CONFIG_DIR=... or CLI --config-dir ...
CONFIG_DIR="${CONFIG_DIR:-}"

# Dry-run mode (default OFF): show plan, do not download/extract/prepare
DRY_RUN="${DRY_RUN:-0}"

# Optional behavior: place prepared headers under subdir named after the toolchain (must be explicitly enabled).
USE_TOOLCHAIN_SUBDIR="${USE_TOOLCHAIN_SUBDIR:-0}"
TOOLCHAIN_SUBDIR_TAG=""

# Behavior when an existing build dir was prepared with a different compiler.
# Values: ask (default), rebuild, skip
MISMATCH_POLICY="${MISMATCH_POLICY:-ask}"
QUIET_MODE="${QUIET_MODE:-0}"

# Optional flag to print the upstream LTS reference table and exit.
PRINT_LTS_REFERENCE="${PRINT_LTS_REFERENCE:-0}"

# Optional "latest" behavior (default OFF):
#  - LATEST_ALL=1          : try to use latest available versions for ALL series
#  - LATEST_ON_BROKEN=1    : try to use latest available only when the pinned one is broken/unavailable
LATEST_ALL="${LATEST_ALL:-0}"
LATEST_ON_BROKEN="${LATEST_ON_BROKEN:-0}"

DEFAULT_SERIES_LIST=("4.19" "5.4" "5.10" "5.15" "6.1" "6.6" "6.12" "6.18")
ENV_TARGET_KERNEL_SERIES="${TARGET_KERNEL_SERIES:-}"
declare -a CLI_SERIES_LIST=()
SERIES_LIST=("${DEFAULT_SERIES_LIST[@]}")

usage() {
  cat <<EOF
Usage: $0 [--arch <arch>] [--cross-compile <prefix>] [--releases-json /path/to/releases.json] [--config-dir /path] [--latest-all] [--latest-on-broken] [--dry-run] [--force] [--strict]

Environment overrides:
  ARCH, CROSS_COMPILE, BASE_DIR, JOBS, RELEASES_JSON, CONFIG_DIR, LATEST_ALL, LATEST_ON_BROKEN, DRY_RUN,
  USE_TOOLCHAIN_SUBDIR, MISMATCH_POLICY, QUIET_MODE,
  KERNEL_SOURCE_BASE, TARGET_KERNEL_SERIES

If RELEASES_JSON is provided and points to an existing file, it will be used
instead of fetching ${RELEASES_JSON_URL}.

Options:
  --arch <arch>           Target kernel ARCH for preparation (e.g. arm64, x86_64, riscv, arm).
  --cross-compile <pfx>   CROSS_COMPILE prefix (e.g. aarch64-linux-gnu-). Use empty string for native.
  --releases-json <path>  Use local JSON lock-file (your format: {"kernels":[...]}).
  --config-dir <path>     Try to import .config from this directory before prepare.
                          Lookup order (first existing wins):
                            <dir>/<ARCH>/<fullver>/.config
                            <dir>/<ARCH>/<series>/.config
                            <dir>/<fullver>/.config
                            <dir>/<series>/.config
                          Example:
                            --config-dir /opt/kernel-configs
                            /opt/kernel-configs/arm64/5.15/.config
  --kernels-list <list>   Pick the kernel series that should be prepared (aliases: --target-series, --series).
                          Supply a space/comma/semicolon delimited list; this is the same format
                          accepted by the TARGET_KERNEL_SERIES environment variable.
  --force                 Re-download tarballs, re-extract sources and re-run modules_prepare.
  --force-download        Only re-download tarballs.
  --force-extract         Only re-extract sources.
  --force-prepare         Only re-run defconfig/olddefconfig/modules_prepare.
  --strict                Fail on missing tarball/HTTP errors (default: skip missing versions).
  --latest-all            (default OFF) For each series, try to use the newest available version
                          according to kernel.org releases.json AND present on CDN.
                          If a series is EOL and missing from kernel.org releases.json, pinned version is kept.
  --latest-on-broken      (default OFF) Use pinned version by default; if tarball is missing/corrupted,
                          attempt to fall back to newest available version for that series (present on CDN).
  --dry-run               (default OFF) Print plan only; do not download, extract, or run make.
  --kernel-source-base <url>  Override the base URL for kernel tarballs (env var KERNEL_SOURCE_BASE is an alternative).
  --lts-reference          Print the full upstream LTS table and exit.
  --mismatch-rebuild       On compiler mismatch, delete the existing build dir and rebuild (non-interactive).
  --mismatch-skip          On compiler mismatch, keep the existing build dir and skip (non-interactive).
  --quiet                  Do not prompt; requires an explicit mismatch policy.
  --toolchain-subdir        Place each prepared tree under a compiler-specific subdirectory (off by default).
  -h, --help              Show this help.

LTS branches by major release: 2.x (2.6.32); 3.x (3.0,3.2,3.4,3.10,3.12,3.14,3.16,3.18); 4.x (4.1,4.4,4.9,4.14,4.19); 5.x (5.4,5.10,5.15); 6.x (6.1,6.6,6.12,6.18)
EOF
}

trim_string() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

split_series_string() {
  local raw="$1"
  local normalized="${raw//,/ }"
  normalized="${normalized//;/ }"
  normalized="${normalized//|/ }"
  normalized="${normalized//:/ }"

  local token
  local trimmed
  local -a tokens=()
  read -ra tokens <<< "${normalized}"
  for token in "${tokens[@]}"; do
    trimmed="$(trim_string "${token}")"
    if [[ -n "${trimmed}" ]]; then
      printf '%s\n' "${trimmed}"
    fi
  done
}

append_series_tokens() {
  local raw="$1"
  local entry
  while IFS= read -r entry; do
    CLI_SERIES_LIST+=("${entry}")
  done < <(split_series_string "${raw}")
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --arch)
        shift
        [[ $# -gt 0 ]] || { echo "ERROR: --arch requires a value" >&2; exit 1; }
        ARCH="$1"
        shift
        ;;
      --cross-compile)
        shift
        [[ $# -gt 0 ]] || { echo "ERROR: --cross-compile requires a value (can be empty "")" >&2; exit 1; }
        CROSS_COMPILE="$1"
        shift
        ;;
      --releases-json)
        shift
        [[ $# -gt 0 ]] || { echo "ERROR: --releases-json requires a path" >&2; exit 1; }
        RELEASES_JSON="$1"
        shift
        ;;
      --config-dir)
        shift
        [[ $# -gt 0 ]] || { echo "ERROR: --config-dir requires a path" >&2; exit 1; }
        CONFIG_DIR="$1"
        shift
        ;;
      --series|--target-series|--kernels-list)
        local flag="$1"
        shift
        [[ $# -gt 0 ]] || { echo "ERROR: ${flag} requires a value" >&2; exit 1; }
        append_series_tokens "$1"
        shift
        ;;
      --latest-all)
        LATEST_ALL=1
        shift
        ;;
      --latest-on-broken)
        LATEST_ON_BROKEN=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --force)
        FORCE_DOWNLOAD=1
        FORCE_EXTRACT=1
        FORCE_PREPARE=1
        shift
        ;;
      --force-download)
        FORCE_DOWNLOAD=1
        shift
        ;;
      --force-extract)
        FORCE_EXTRACT=1
        shift
        ;;
      --force-prepare)
        FORCE_PREPARE=1
        shift
        ;;
      --strict)
        STRICT=1
        shift
        ;;
      --mismatch-rebuild)
        MISMATCH_POLICY="rebuild"
        shift
        ;;
      --mismatch-skip)
        MISMATCH_POLICY="skip"
        shift
        ;;
      --quiet)
        QUIET_MODE=1
        shift
        ;;
      --lts-reference)
        PRINT_LTS_REFERENCE=1
        shift
        ;;
      --toolchain-subdir)
        USE_TOOLCHAIN_SUBDIR=1
        shift
        ;;
      --kernel-source-base)
        shift
        [[ $# -gt 0 ]] || { echo "ERROR: --kernel-source-base requires a value" >&2; exit 1; }
        CLI_KERNEL_SOURCE_BASE="$1"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "ERROR: unknown argument: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
}

finalize_series_list() {
  local resolved=()

  if [[ -n "${ENV_TARGET_KERNEL_SERIES}" ]]; then
    local entry
    while IFS= read -r entry; do
      resolved+=("${entry}")
    done < <(split_series_string "${ENV_TARGET_KERNEL_SERIES}")
  fi

  if [[ ${#CLI_SERIES_LIST[@]} -gt 0 ]]; then
    resolved=("${CLI_SERIES_LIST[@]}")
  fi

  if [[ ${#resolved[@]} -gt 0 ]]; then
    SERIES_LIST=("${resolved[@]}")
  fi
}

finalize_kernel_source_base() {
  if [[ -n "${CLI_KERNEL_SOURCE_BASE}" ]]; then
    KERNEL_SOURCE_BASE="${CLI_KERNEL_SOURCE_BASE}"
  elif [[ -n "${ENV_KERNEL_SOURCE_BASE}" ]]; then
    KERNEL_SOURCE_BASE="${ENV_KERNEL_SOURCE_BASE}"
  else
    KERNEL_SOURCE_BASE="${DEFAULT_KERNEL_SOURCE_BASE}"
  fi

  if [[ -z "${KERNEL_SOURCE_BASE}" ]]; then
    echo "ERROR: kernel source base cannot be empty" >&2
    exit 1
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 1
  }
}

print_gcc_version_line() {
  # Print first line of gcc --version (compact for CI logs)
  local gcc_bin="$1"
  "${gcc_bin}" --version 2>/dev/null | head -n 1 || true
}

version_major() {
  local v="$1"
  v="${v%%[^0-9.]*}"
  echo "${v%%.*}"
}

version_exact_match() {
  local a="$1"
  local b="$2"
  [[ "${a}" == "${b}" ]]
}

expected_dumpmachine_substr() {
  # Return a substring expected to appear in gcc -dumpmachine for given ARCH.
  # Empty means "unknown, skip check".
  case "${ARCH}" in
    arm64)  echo "aarch64" ;;
    arm)    echo "arm" ;;
    x86_64) echo "x86_64" ;;
    riscv)  echo "riscv64" ;;
    *)
      echo ""
      ;;
  esac
}

check_toolchain_arch_match() {
  local gcc_bin="$1"
  local dm
  dm="$("${gcc_bin}" -dumpmachine 2>/dev/null || true)"
  [[ -n "${dm}" ]] && echo "TOOLCHAIN_GCC_DUMPMACHINE=${dm}" >&2

  local expect
  expect="$(expected_dumpmachine_substr)"
  [[ -n "${expect}" ]] || return 0

  if [[ "${dm}" != *"${expect}"* ]]; then
    echo "ERROR: toolchain does not match selected ARCH" >&2
    echo "       ARCH='${ARCH}' expects gcc -dumpmachine to contain '${expect}'" >&2
    echo "       but ${gcc_bin} reports: '${dm}'" >&2
    if [[ "${ARCH}" == "x86_64" ]]; then
      echo "       Hint: for native x86_64 build, use --cross-compile "" (empty) or install an x86_64 compiler." >&2
    else
      echo "       Hint: set --cross-compile to the correct prefix for ARCH=${ARCH} (e.g. arm64 -> aarch64-linux-gnu-)." >&2
    fi
    exit 1
  fi
}

check_toolchain() {
  # If CROSS_COMPILE is set (non-empty), require ${CROSS_COMPILE}gcc
  # Else, require gcc.
  local gcc_bin=""

  if [[ -n "${CROSS_COMPILE}" ]]; then
    gcc_bin="${CROSS_COMPILE}gcc"
  else
    gcc_bin="gcc"
  fi

  if ! command -v "${gcc_bin}" >/dev/null 2>&1; then
    if [[ -n "${CROSS_COMPILE}" ]]; then
      echo "ERROR: cross-compiler not found: ${gcc_bin}" >&2
      echo "       CROSS_COMPILE='${CROSS_COMPILE}' (expected '${CROSS_COMPILE}gcc' in PATH)" >&2
    else
      echo "ERROR: default compiler not found: gcc" >&2
      echo "       CROSS_COMPILE is empty; expected 'gcc' in PATH" >&2
    fi
    exit 1
  fi

  echo "TOOLCHAIN_GCC=${gcc_bin}" >&2
  local vline
  vline="$(print_gcc_version_line "${gcc_bin}")"
  [[ -n "${vline}" ]] && echo "TOOLCHAIN_GCC_VERSION=${vline}" >&2

  # Ensure toolchain matches selected ARCH (prevents x86 flags going to aarch64-gcc, etc.)
  check_toolchain_arch_match "${gcc_bin}"
  compute_toolchain_tag "${gcc_bin}"
}

compute_toolchain_tag() {
  local gcc_bin="$1"
  local dumpver
  dumpver="$("${gcc_bin}" -dumpversion 2>/dev/null || true)"
  if [[ -z "${dumpver}" ]]; then
    dumpver="$(print_gcc_version_line "${gcc_bin}" | awk '{print $NF}')"
  fi
  [[ -n "${dumpver}" ]] || dumpver="unknown"
  local base
  base="$(basename "${gcc_bin}")"
  local tag="${base}-${dumpver}"
  tag="${tag// /_}"
  tag="${tag//[^a-zA-Z0-9._-]/_}"
  TOOLCHAIN_SUBDIR_TAG="${tag}"
}

write_build_metadata() {
  local build_dir="$1"
  local gcc_bin="$2"
  local ver_line
  ver_line="$(print_gcc_version_line "${gcc_bin}")"
  local dumpver
  dumpver="$("${gcc_bin}" -dumpversion 2>/dev/null || true)"
  local dumpmachine
  dumpmachine="$("${gcc_bin}" -dumpmachine 2>/dev/null || true)"

  mkdir -p "${build_dir}"
  {
    echo "TOOLCHAIN_GCC=${gcc_bin}"
    [[ -n "${ver_line}" ]] && echo "TOOLCHAIN_GCC_VERSION=${ver_line}"
    [[ -n "${dumpver}" ]] && echo "TOOLCHAIN_GCC_DUMPVERSION=${dumpver}"
    [[ -n "${dumpmachine}" ]] && echo "TOOLCHAIN_GCC_DUMPMACHINE=${dumpmachine}"
  } > "${build_dir}/.toolchain-info"
}

read_toolchain_metadata() {
  local build_dir="$1"
  local key="$2"
  local file="${build_dir}/.toolchain-info"
  [[ -f "${file}" ]] || return 1
  grep -E "^${key}=" "${file}" | head -n 1 | sed -e "s/^${key}=//"
}

read_compiler_from_compile_h() {
  local build_dir="$1"
  local file="${build_dir}/include/generated/compile.h"
  [[ -f "${file}" ]] || return 1
  grep -E '^#define LINUX_COMPILER ' "${file}" | head -n 1 | sed -e 's/^#define LINUX_COMPILER "//' -e 's/"$//'
}

read_compiler_from_config() {
  local build_dir="$1"
  local file="${build_dir}/.config"
  [[ -f "${file}" ]] || return 1

  local gcc_version
  gcc_version="$(grep -E '^CONFIG_GCC_VERSION=' "${file}" | head -n 1 | sed -e 's/^CONFIG_GCC_VERSION=//')"
  local clang_version
  clang_version="$(grep -E '^CONFIG_CLANG_VERSION=' "${file}" | head -n 1 | sed -e 's/^CONFIG_CLANG_VERSION=//')"

  if [[ -n "${gcc_version}" && "${gcc_version}" != "0" ]]; then
    echo "gcc ${gcc_version}"
    return 0
  fi
  if [[ -n "${clang_version}" && "${clang_version}" != "0" ]]; then
    echo "clang ${clang_version}"
    return 0
  fi
  return 1
}

print_existing_toolchain_info() {
  local build_dir="$1"
  local existing_line
  existing_line="$(read_toolchain_metadata "${build_dir}" "TOOLCHAIN_GCC_VERSION" || true)"
  if [[ -n "${existing_line}" ]]; then
    echo "EXISTING_TOOLCHAIN=${existing_line} (source=.toolchain-info)" >&2
    return 0
  fi
  existing_line="$(read_compiler_from_compile_h "${build_dir}" || true)"
  if [[ -n "${existing_line}" ]]; then
    echo "EXISTING_TOOLCHAIN=${existing_line} (source=compile.h)" >&2
    return 0
  fi
  existing_line="$(read_compiler_from_config "${build_dir}" || true)"
  if [[ -n "${existing_line}" ]]; then
    echo "EXISTING_TOOLCHAIN=${existing_line} (source=.config)" >&2
    return 0
  fi
  local existing_dumpver
  existing_dumpver="$(read_toolchain_metadata "${build_dir}" "TOOLCHAIN_GCC_DUMPVERSION" || true)"
  if [[ -n "${existing_dumpver}" ]]; then
    echo "EXISTING_TOOLCHAIN=${existing_dumpver} (source=.toolchain-info)" >&2
    return 0
  fi
  echo "EXISTING_TOOLCHAIN=FAIL" >&2
  return 1
}

print_toolchain_info_reason() {
  local build_dir="$1"
  local info_file="${build_dir}/.toolchain-info"
  local compile_file="${build_dir}/include/generated/compile.h"
  if [[ ! -f "${info_file}" ]]; then
    echo "EXISTING_TOOLCHAIN_REASON=missing ${info_file}" >&2
  fi
  if [[ ! -f "${compile_file}" ]]; then
    echo "EXISTING_TOOLCHAIN_REASON=missing ${compile_file}" >&2
  fi
}

handle_toolchain_mismatch() {
  local version="$1"
  local build_dir="$2"
  local gcc_bin="$3"
  local current_dumpver
  local current_major
  local existing_dumpver
  local existing_major

  current_dumpver="$("${gcc_bin}" -dumpversion 2>/dev/null || true)"
  existing_dumpver="$(read_toolchain_metadata "${build_dir}" "TOOLCHAIN_GCC_DUMPVERSION" || true)"

  if [[ -z "${existing_dumpver}" ]]; then
    if [[ "${MISMATCH_POLICY}" == "skip" ]]; then
      echo "WARN: missing toolchain metadata in ${build_dir}/.toolchain-info" >&2
      return 2
    fi
    echo "ERROR: missing toolchain metadata in ${build_dir}/.toolchain-info" >&2
    return 3
  fi

  current_major="$(version_major "${current_dumpver}")"
  existing_major="$(version_major "${existing_dumpver}")"

  if [[ -n "${current_major}" && -n "${existing_major}" && "${current_major}" == "${existing_major}" ]]; then
    return 0
  fi

  if version_exact_match "${current_dumpver}" "${existing_dumpver}"; then
    return 0
  fi

  local existing_line
  existing_line="$(read_toolchain_metadata "${build_dir}" "TOOLCHAIN_GCC_VERSION" || true)"
  if [[ -z "${existing_line}" ]]; then
    existing_line="${existing_dumpver}"
  fi

  local current_line
  current_line="$(print_gcc_version_line "${gcc_bin}")"
  if [[ -z "${current_line}" ]]; then
    current_line="${current_dumpver}"
  fi

  echo "WARN: build directory was prepared with a different compiler" >&2
  echo "      Existing: ${existing_line}" >&2
  echo "      Current : ${current_line}" >&2

  if [[ ${QUIET_MODE} -eq 1 && "${MISMATCH_POLICY}" == "ask" ]]; then
    echo "ERROR: --quiet requires --mismatch-rebuild or --mismatch-skip" >&2
    exit 1
  fi

  local decision="${MISMATCH_POLICY}"
  if [[ "${decision}" == "ask" ]]; then
    read -r -p "Delete and rebuild ${build_dir}? [y/N] " reply
    case "${reply}" in
      y|Y|yes|YES)
        decision="rebuild"
        ;;
      *)
        decision="skip"
        ;;
    esac
  fi

  if [[ "${decision}" == "rebuild" ]]; then
    rm -rf "${build_dir}"
    return 1
  fi

  echo "INFO: keeping existing build directory: ${build_dir}" >&2
  return 2
}

build_dir_for_tree() {
  local kroot="$1"
  local base="${kroot}/build-${ARCH}"
  if [[ "${USE_TOOLCHAIN_SUBDIR}" -eq 1 && -n "${TOOLCHAIN_SUBDIR_TAG}" ]]; then
    echo "${base}/${TOOLCHAIN_SUBDIR_TAG}"
  else
    echo "${base}"
  fi
}

expected_arch_config_symbol() {
  # Return the Kconfig symbol expected to be 'y' for the selected ARCH.
  # Empty output means "unknown, skip check".
  case "${ARCH}" in
    arm64)  echo "CONFIG_ARM64" ;;
    x86_64) echo "CONFIG_X86_64" ;;
    arm)    echo "CONFIG_ARM" ;;
    riscv)  echo "CONFIG_RISCV" ;;
    *)
      echo ""
      ;;
  esac
}

check_config_matches_arch() {
  # Verify that .config corresponds to selected ARCH to avoid cases like:
  #   ARCH=arm64 but CONFIG_X86_64=y -> leads to aarch64-gcc seeing -mcmodel=kernel, etc.
  local build_dir="$1"
  local cfg="${build_dir}/.config"

  [[ -f "${cfg}" ]] || return 0

  local sym
  sym="$(expected_arch_config_symbol)"
  [[ -n "${sym}" ]] || return 0

  if ! grep -qE "^${sym}=y$" "${cfg}"; then
    echo "ERROR: .config does not match selected ARCH" >&2
    echo "       ARCH='${ARCH}' expects '${sym}=y' in ${cfg}" >&2
    echo "       This usually means you imported/kept a .config for a different architecture." >&2
    echo "       Fix options:" >&2
    echo "         1) Provide correct .config via --config-dir (matching ARCH=${ARCH})" >&2
    echo "         2) Remove the build dir and rerun, or run with --force-prepare" >&2
    echo "         3) Ensure you didn't set --arch x86_64 with aarch64 CROSS_COMPILE (or vice-versa)" >&2
    exit 1
  fi
}

tmp_fetch_kernelorg_releases_json() {
  # Fetch kernel.org releases.json into a temp file and echo its path.
  # Returns empty string if fetch fails (and not strict).
  local t
  t="$(mktemp)"
  if curl -fsSL "${RELEASES_JSON_URL}" -o "${t}" >/dev/null 2>&1; then
    echo "${t}"
    return 0
  fi
  rm -f "${t}"
  if [[ ${STRICT} -eq 1 ]]; then
    echo "ERROR: failed to fetch ${RELEASES_JSON_URL} for latest resolution" >&2
    exit 1
  fi
  echo ""
  return 0
}

as_root_hint() {
  if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must be run as root (or via sudo) to write into ${BASE_DIR}" >&2
    exit 1
  fi
}

http_exists() {
  # Return 0 if URL exists (HTTP 200/3xx), else 1.
  local url="$1"
  curl -fsI "${url}" >/dev/null 2>&1
}

is_prepared_markers_present() {
  local build_dir="$1"
  [[ -f "${build_dir}/include/generated/autoconf.h" ]] && [[ -f "${build_dir}/include/config/auto.conf" ]]
}

tarball_url_for_version() {
  local version="$1"
  local vdir
  vdir="$(kernel_dir_for_version "${version}")"
  local tb
  tb="$(tarball_name_for_version "${version}")"
  echo "${KERNEL_SOURCE_BASE}/${vdir}/${tb}"
}

print_plan_for_kernel() {
  # Print what would be done for a given resolved version.
  local series="$1"
  local version="$2"

  local kroot="${BASE_DIR}/${version}"
  local tb_dir="${kroot}/_dl"
  local src_root="${kroot}/src"
  local build_dir
  build_dir="$(build_dir_for_tree "${kroot}")"
  local tb_name
  tb_name="$(tarball_name_for_version "${version}")"
  local tb_path="${tb_dir}/${tb_name}"
  local src_dir="${src_root}/$(extract_src_dirname "${version}")"
  local url
  url="$(tarball_url_for_version "${version}")"

  echo "==> DRY-RUN: ${series} -> ${version}"
  echo "    URL      : ${url}"
  echo "    KROOT    : ${kroot}"
  echo "    TARBALL  : ${tb_path}"
  echo "    SRC_DIR  : ${src_dir}"
  echo "    BUILD_DIR: ${build_dir}"

  local tb_state="missing"
  if [[ -f "${tb_path}" ]]; then
    if tarball_validate "${tb_path}"; then
      tb_state="present+valid"
    else
      tb_state="present+corrupt"
    fi
  fi

  local src_state="missing"
  [[ -d "${src_dir}" ]] && src_state="present"

  local prep_state="missing"
  is_prepared_markers_present "${build_dir}" && prep_state="prepared"

  echo "    STATE    : tarball=${tb_state}, sources=${src_state}, build=${prep_state}"

  local action_download="skip"
  local action_extract="skip"
  local action_prepare="skip"

  if [[ ${FORCE_DOWNLOAD} -eq 1 || ! -f "${tb_path}" ]]; then
    action_download="download"
  fi
  if [[ ${FORCE_EXTRACT} -eq 1 || ! -d "${src_dir}" ]]; then
    action_extract="extract"
  fi
  if [[ ${FORCE_PREPARE} -eq 1 || ! $(is_prepared_markers_present "${build_dir}"; echo $?) -eq 0 ]]; then
    action_prepare="prepare"
  fi

  echo "    WOULD DO : ${action_download}, ${action_extract}, ${action_prepare}"
  echo
}

print_lts_reference() {
  cat <<'EOF'
Upstream LTS reference (what series to pick):
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
EOF
}

resolve_latest_available_for_series() {
  # Given kernel.org releases.json file and series "6.6", pick highest version "6.6.*"
  # that is also present on CDN (HEAD OK). Echo version or empty if none found.
  local kernelorg_json="$1"
  local series="$2"
  local series_escaped="${series//./\\.}"

  local candidates
  if [[ -n "${kernelorg_json}" && -f "${kernelorg_json}" ]]; then
    candidates="$(jq -r --arg s "${series}." '
      .releases[]? | select(.version? and (.version | startswith($s))) | .version
    ' "${kernelorg_json}" 2>/dev/null | sort -V)"

    if [[ -n "${candidates}" ]]; then
      # reverse by sorting -V then tac
      local v
      while read -r v; do
        if http_exists "$(tarball_url_for_version "${v}")"; then
          echo "${v}"
          return 0
        fi
      done < <(echo "${candidates}" | tac)
    fi
  fi

  local vdir
  vdir="$(kernel_dir_for_series "${series}")"
  local search_paths=("" "stable-review/" "incr/")
  local pattern="linux-${series_escaped}\\.[0-9]+\\.tar\\.xz"

  for suffix in "${search_paths[@]}"; do
    local search_url="${KERNEL_SOURCE_BASE}/${vdir}/${suffix}"
    local listing
    listing="$(curl -fsSL "${search_url}" 2>/dev/null || true)"
    if [[ -z "${listing}" ]]; then
      continue
    fi
    local candidate
    candidate="$(find_latest_from_listing "${listing}" "${pattern}")"
    if [[ -n "${candidate}" ]]; then
      echo "${candidate}"
      return 0
    fi
  done

  echo ""
}

find_latest_from_listing() {
  local listing="$1"
  local pattern="$2"
  local match
  match="$(printf '%s' "${listing}" \
    | { grep -oE "${pattern}" || true; } \
    | sort -V \
    | tail -n 1)"
  if [[ -n "${match}" ]]; then
    match="${match##linux-}"
    match="${match%.tar.xz}"
    printf '%s' "${match}"
  fi
}

series_from_version() {
  # Input: full version "6.12.14" -> "6.12"
  #        full version "4.19.325" -> "4.19"
  local v="$1"
  echo "${v%.*}"
}

tarball_validate() {
  # Validate that tarball can be listed by tar.
  # Return 0 if OK, 1 if broken.
  local tb_path="$1"
  tar -tf "${tb_path}" >/dev/null 2>&1
}

tarball_ensure_valid() {
  # If tarball exists but is broken:
  #  - strict: exit 1
  #  - non-strict: delete and let caller re-download
  local tb_path="$1"

  if [[ ! -f "${tb_path}" ]]; then
    return 0
  fi
  if tarball_validate "${tb_path}"; then
    return 0
  fi

  if [[ ${STRICT} -eq 1 ]]; then
    echo "ERROR: tarball is corrupted: ${tb_path}" >&2
    exit 1
  fi
  echo "WARN: tarball is corrupted, will re-download: ${tb_path}" >&2
  rm -f "${tb_path}"
  return 0
}

kernel_dir_for_version() {
  # Input: full version like 6.12.68 or 4.19.312
  # Output: v6.x or v4.x, with exceptions for legacy series (v3.0, v2.6).
  local v="$1"
  if [[ "${v}" == 3.0.* ]]; then
    echo "v3.0"
    return 0
  fi
  if [[ "${v}" == 2.6.* ]]; then
    echo "v2.6"
    return 0
  fi
  local major="${v%%.*}"
  echo "v${major}.x"
}

kernel_dir_for_series() {
  # Input: series like 6.12, 4.4, 3.0, 2.6
  # Output: v6.x, v4.x, v3.0, v2.6
  local s="$1"
  if [[ "${s}" == 3.0 || "${s}" == 3.0.* ]]; then
    echo "v3.0"
    return 0
  fi
  if [[ "${s}" == 2.6 || "${s}" == 2.6.* ]]; then
    echo "v2.6"
    return 0
  fi
  local major="${s%%.*}"
  echo "v${major}.x"
}

tarball_name_for_version() {
  # Input: full version like 6.12.68
  # Output: linux-6.12.68.tar.xz
  local v="$1"
  echo "linux-${v}.tar.xz"
}

extract_src_dirname() {
  # tarball extracts into linux-<ver>
  local v="$1"
  echo "linux-${v}"
}

fetch_releases_json() {
  local out="$1"
  if [[ -n "${RELEASES_JSON}" ]]; then
    if [[ ! -f "${RELEASES_JSON}" ]]; then
      echo "ERROR: RELEASES_JSON set but file does not exist: ${RELEASES_JSON}" >&2
      exit 1
    fi
    echo "Using local releases JSON: ${RELEASES_JSON}"
    cp -f "${RELEASES_JSON}" "${out}"
    return 0
  fi

  echo "Fetching ${RELEASES_JSON_URL}"
  curl -fsSL "${RELEASES_JSON_URL}" -o "${out}"
}

get_latest_version_for_series() {
  # Uses releases.json; searches across all release channels (stable/longterm/mainline/etc)
  # and returns the highest semantic version matching "<series>.*"
  local releases_json="$1"
  local series="$2"

  if jq -e '.kernels' "${releases_json}" >/dev/null 2>&1; then
    # Local lock-file format:
    # { "kernels": [ { "series":"4.19", "version":"4.19.325" }, ... ] }
    jq -r --arg s "${series}" '
      .kernels[]
      | select(.series == $s)
      | .version
    ' "${releases_json}" | sort -V | tail -n 1
    return 0
  fi

  # kernel.org releases.json format:
  # { "releases": [ { "version":"6.12.14", ... }, ... ] }
  jq -r --arg s "${series}." '
    .releases[]
    | select(.version | startswith($s))
    | .version
  ' "${releases_json}" | sort -V | tail -n 1
}

download_tarball() {
  local version="$1"
  local dest_dir="$2"

  local tb
  tb="$(tarball_name_for_version "${version}")"
  local url
  url="$(tarball_url_for_version "${version}")"

  mkdir -p "${dest_dir}"

  # If tarball exists but is broken, remove it (unless strict).
  tarball_ensure_valid "${dest_dir}/${tb}"

  if [[ -f "${dest_dir}/${tb}" && ${FORCE_DOWNLOAD} -eq 0 ]]; then
    echo "Tarball already exists (skip): ${dest_dir}/${tb}" >&2
    return 0
  fi

  # If not strict, check existence and skip missing versions instead of failing hard.
  if ! http_exists "${url}"; then
    if [[ ${STRICT} -eq 1 ]]; then
      echo "ERROR: tarball not found (HTTP): ${url}" >&2
      exit 1
    fi
    echo "WARN: tarball not found (skip kernel): ${url}" >&2
    return 2
  fi

  echo "Downloading ${url}" >&2
  curl -fL --retry 3 --retry-delay 2 -o "${dest_dir}/${tb}" "${url}"

  # Validate downloaded tarball; if broken, retry once (non-strict) or fail (strict).
  if ! tarball_validate "${dest_dir}/${tb}"; then
    if [[ ${STRICT} -eq 1 ]]; then
      echo "ERROR: downloaded tarball is corrupted: ${dest_dir}/${tb}" >&2
      exit 1
    fi
    echo "WARN: downloaded tarball corrupted, retrying once: ${dest_dir}/${tb}" >&2
    rm -f "${dest_dir}/${tb}"
    curl -fL --retry 3 --retry-delay 2 -o "${dest_dir}/${tb}" "${url}"
    tarball_validate "${dest_dir}/${tb}" || { echo "ERROR: tarball still corrupted after retry: ${dest_dir}/${tb}" >&2; exit 1; }
  fi
}

download_tarball_with_latest_fallback_if_enabled() {
  # Try downloading pinned version. If missing/broken and LATEST_ON_BROKEN=1,
  # try resolving latest available for that series and download it instead.
  # Echo selected version on success, empty on skip/failure (non-strict).
  local series="$1"
  local pinned_version="$2"
  local dest_dir="$3"
  local kernelorg_json="$4"

  local rc=0
  if download_tarball "${pinned_version}" "${dest_dir}"; then
    echo "${pinned_version}"
    return 0
  else
    rc=$?
  fi

  # download_tarball returns 2 for "skip" due to missing tarball (non-strict).
  if [[ ${LATEST_ON_BROKEN} -eq 1 && (${rc} -eq 2) ]]; then
    local latest
    latest="$(resolve_latest_available_for_series "${kernelorg_json}" "${series}")"
    if [[ -n "${latest}" && "${latest}" != "${pinned_version}" ]]; then
      echo "INFO: pinned ${pinned_version} unavailable; trying latest for ${series}: ${latest}" >&2
      if download_tarball "${latest}" "${dest_dir}"; then
        echo "${latest}"
        return 0
      fi
    else
      echo "WARN: no latest available found for ${series} to replace pinned ${pinned_version}" >&2
    fi
  fi

  # If strict, download_tarball would have exited already.
  echo ""
  return 1
}

ensure_extracted_sources() {
  # Args:
  #   $1 series (e.g. 5.15)
  #   $2 pinned_version (e.g. 5.15.166 or already resolved latest)
  #   $3 kroot (e.g. /opt/kernels/5.15.166)
  #   $4 kernelorg_json (temp file path or empty)
  local series="$1"
  local pinned_version="$2"
  local kroot="$3"
  local kernelorg_json="$4"

  local src_dir="${kroot}/src"
  local tb_dir="${kroot}/_dl"

  mkdir -p "${src_dir}" "${tb_dir}"

  local selected_version=""
  selected_version="$(download_tarball_with_latest_fallback_if_enabled "${series}" "${pinned_version}" "${tb_dir}" "${kernelorg_json}" || true)"
  if [[ -z "${selected_version}" ]]; then
    return 1
  fi

  # Hard guard: ensure selected_version looks like a kernel version x.y.z
  if [[ ! "${selected_version}" =~ ^[0-9]+(\.[0-9]+){2,}$ ]]; then
    echo "ERROR: internal: selected_version is not a version string: '${selected_version}'" >&2
    return 1
  fi

  local tb
  tb="$(tarball_name_for_version "${selected_version}")"

  local extracted
  extracted="$(extract_src_dirname "${selected_version}")"

  if [[ -d "${src_dir}/${extracted}" && ${FORCE_EXTRACT} -eq 0 ]]; then
    echo "Sources already extracted (skip): ${src_dir}/${extracted}" >&2
    return 0
  fi

  echo "Extracting ${tb_dir}/${tb} -> ${src_dir}" >&2
  rm -rf "${src_dir:?}/${extracted}"
  tar -C "${src_dir}" -xf "${tb_dir}/${tb}"

  if [[ ! -d "${src_dir}/${extracted}" ]]; then
    echo "ERROR: expected source directory not found after extraction: ${src_dir}/${extracted}" >&2
    exit 1
  fi
}

find_config_for_kernel() {
  # Try to locate a .config in CONFIG_DIR for given version.
  # Prints path if found, else empty.
  local version="$1"
  local series
  series="$(series_from_version "${version}")"

  if [[ -z "${CONFIG_DIR}" ]]; then
    echo ""
    return 0
  fi

  local candidates=(
    "${CONFIG_DIR}/${ARCH}/${version}/.config"
    "${CONFIG_DIR}/${ARCH}/${series}/.config"
    "${CONFIG_DIR}/${version}/.config"
    "${CONFIG_DIR}/${series}/.config"
  )

  local c
  for c in "${candidates[@]}"; do
    if [[ -f "${c}" ]]; then
      echo "${c}"
      return 0
    fi
  done
  echo ""
}

import_config_if_available() {
  # Import config into build dir if:
  #  - config exists in CONFIG_DIR, and
  #  - build_dir/.config does not exist OR FORCE_PREPARE=1
  local version="$1"
  local build_dir="$2"

  local src_cfg
  src_cfg="$(find_config_for_kernel "${version}")"
  if [[ -z "${src_cfg}" ]]; then
    return 0
  fi

  if [[ -f "${build_dir}/.config" && ${FORCE_PREPARE} -eq 0 ]]; then
    echo "==> Found external .config but build already has one (skip import): ${build_dir}/.config"
    echo "    External: ${src_cfg}"
    return 0
  fi

  echo "==> Importing .config for ${version}"
  echo "    From: ${src_cfg}"
  echo "    To  : ${build_dir}/.config"
  mkdir -p "${build_dir}"
  cp -f "${src_cfg}" "${build_dir}/.config"
}

already_prepared() {
  # Heuristic markers created by Kbuild config/prepare steps.
  local build_dir="$1"
  [[ -f "${build_dir}/include/generated/autoconf.h" ]] && [[ -f "${build_dir}/include/config/auto.conf" ]]
}

prepare_modules() {
  local version="$1"
  local kroot="$2"

  local src_dir="${kroot}/src/$(extract_src_dirname "${version}")"
  local build_dir
  build_dir="$(build_dir_for_tree "${kroot}")"
  local gcc_bin
  if [[ -n "${CROSS_COMPILE}" ]]; then
    gcc_bin="${CROSS_COMPILE}gcc"
  else
    gcc_bin="gcc"
  fi

  if [[ -d "${build_dir}" ]]; then
    print_existing_toolchain_info "${build_dir}" || true
    handle_toolchain_mismatch "${version}" "${build_dir}" "${gcc_bin}" || {
      case $? in
        1) : ;;
        2) return 0 ;;
        *) return 1 ;;
      esac
    }
  fi

  mkdir -p "${build_dir}"
  # If the tree was previously marked read-only, temporarily re-enable writes for preparation.
  # (We will switch it back to read-only at the end of preparation.)
  chmod -R u+w "${build_dir}" "${src_dir}" 2>/dev/null || true


  # If user provided external configs, import them before any config generation.
  import_config_if_available "${version}" "${build_dir}"

  # Sanity-check that imported/existing config matches selected ARCH.
  # Prevents toolchain/arch mismatches (e.g. aarch64-gcc receiving x86_64 flags).
  check_config_matches_arch "${build_dir}"

  if [[ ${FORCE_PREPARE} -eq 0 ]] && already_prepared "${build_dir}"; then
    echo "==> Kernel ${version} already prepared (skip)"
    echo "    BUILD: ${build_dir}"
    return 0
  fi

  echo "==> Preparing kernel ${version}"
  echo "    SRC : ${src_dir}"
  echo "    BUILD: ${build_dir}"
  echo "    ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE}"
  if [[ -n "${CONFIG_DIR}" ]]; then
    echo "    CONFIG_DIR=${CONFIG_DIR}"
  fi

  # Minimal config; for best ABI match you should copy target .config into build_dir/.config beforehand.
  if [[ ! -f "${build_dir}/.config" ]]; then
    make -C "${src_dir}" O="${build_dir}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" defconfig
  fi

  # Bring config up to date with this tree.
  make -C "${src_dir}" O="${build_dir}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" olddefconfig

  # Prepare tree for external module builds.
  make -C "${src_dir}" O="${build_dir}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" -j"${JOBS}" modules_prepare

  write_build_metadata "${build_dir}" "${gcc_bin}"

  # Headers-only hygiene:
  # If vmlinux or Module.symvers leak into the prepared tree, modpost may enable
  # unresolved-symbol checks and fail external module builds even though this is
  # a headers-only environment. Debian headers typically avoid this.
  #
  # Remove these artifacts from BOTH build dir and source dir (source is reachable
  # via 'build/source' symlink and may be consulted by Kbuild).
  echo "    FIX: Removing full-build artifacts (vmlinux/System.map/Module.symvers) from headers-only trees..."
  rm -f "${build_dir}/vmlinux" "${build_dir}/vmlinux.symvers" "${build_dir}/System.map" "${build_dir}/Module.symvers" \
    "${src_dir}/vmlinux"  "${src_dir}/vmlinux.symvers"  "${src_dir}/System.map"  "${src_dir}/Module.symvers" \
    2>/dev/null || true

  # Also remove any vmlinux.* variants at top-level if present
  find "${build_dir}" "${src_dir}" -maxdepth 1 -type f -name 'vmlinux*' -delete 2>/dev/null || true

  # 2. === IMPORTANT: Keep out-of-tree layout (build dir + 'source' symlink) ===
#    Rationale:
#      - For older LTS kernels (e.g. 4.19) Kbuild may not export 'abs_objtree' into
#        external modules. If we force an in-tree/standalone layout (srctree='.', objtree='.')
#        then txgbe's kcompat generator can receive '.' instead of a real kernel path.
#      - The Debian linux-headers packages use the same approach: arch-specific build
#        directory + a 'source' link to the shared source tree.
#
#    Therefore we intentionally KEEP the 'source' symlink and do NOT replace the
#    O=/Makefile shim with the real Makefile.

echo "    FIX: Ensuring out-of-tree headers layout (source symlink preserved)..."

# Ensure the source link exists and points to the extracted source tree.
# Use an absolute link so the tree is relocatable within BASE_DIR.
ln -sfn "${src_dir}" "${build_dir}/source"

# Some build systems drop an empty 'source' file (not a symlink). Ensure it's a symlink.
if [[ ! -L "${build_dir}/source" ]]; then
  rm -f "${build_dir}/source"
  ln -s "${src_dir}" "${build_dir}/source"
fi

# External module builds should never require writing into KERNELDIR. To make this robust:
#   - ensure generated headers/config are present (modules_prepare already did that)
#   - remove vmlinux if it exists, so modpost does not try unresolved symbol checks that
#     depend on a full kernel build (Module.symvers/vmlinux).
rm -f "${build_dir}/vmlinux" "${build_dir}/vmlinux.symvers" "${build_dir}/System.map" "${build_dir}/Module.symvers" 2>/dev/null || true

# Make trees friendly for non-root users who only need read access for module builds.
chmod -R a+rX "${build_dir}" "${src_dir}"

# Optionally enforce read-only headers (good hygiene for build systems). Users can always
# re-run this script with --force (as root) to refresh the prepared tree.
chmod -R a-w "${build_dir}" "${src_dir}" || true

echo "    FIX: Done. KERNELDIR is ready and read-only safe."
}

main() {
  parse_args "$@"
  if [[ ${PRINT_LTS_REFERENCE} -eq 1 ]]; then
    print_lts_reference
    exit 0
  fi
  finalize_kernel_source_base
  finalize_series_list

  as_root_hint

  # Global configuration print (makes runs self-describing for CI/logs)
  echo "=== CONFIGURATION ===" >&2
  echo "ARCH=${ARCH}" >&2
  echo "CROSS_COMPILE=${CROSS_COMPILE}" >&2
  echo "BASE_DIR=${BASE_DIR}" >&2
  echo "JOBS=${JOBS}" >&2
  echo "KERNEL_SOURCE_BASE=${KERNEL_SOURCE_BASE}" >&2
  echo "SERIES_LIST=${SERIES_LIST[*]}" >&2
  echo "USE_TOOLCHAIN_SUBDIR=${USE_TOOLCHAIN_SUBDIR}" >&2
  [[ -n "${TOOLCHAIN_SUBDIR_TAG}" ]] && echo "TOOLCHAIN_SUBDIR_TAG=${TOOLCHAIN_SUBDIR_TAG}" >&2
  [[ -n "${RELEASES_JSON}" ]] && echo "RELEASES_JSON=${RELEASES_JSON}" >&2 || true
  [[ -n "${CONFIG_DIR}" ]] && echo "CONFIG_DIR=${CONFIG_DIR}" >&2 || true
  echo "LATEST_ALL=${LATEST_ALL}  LATEST_ON_BROKEN=${LATEST_ON_BROKEN}  DRY_RUN=${DRY_RUN}  STRICT=${STRICT}" >&2
  echo "FORCE_DOWNLOAD=${FORCE_DOWNLOAD}  FORCE_EXTRACT=${FORCE_EXTRACT}  FORCE_PREPARE=${FORCE_PREPARE}" >&2
  echo "MISMATCH_POLICY=${MISMATCH_POLICY}  QUIET_MODE=${QUIET_MODE}" >&2
  echo "======================" >&2
  echo >&2

  need_cmd curl
  need_cmd jq
  need_cmd tar
  need_cmd make
  need_cmd sort
  need_cmd xz

  # Toolchain sanity check + version print
  check_toolchain

  mkdir -p "${BASE_DIR}"

  # Optional kernel.org releases.json used for "latest" resolution
  KERNELORG_JSON=""
  if [[ ${LATEST_ALL} -eq 1 || ${LATEST_ON_BROKEN} -eq 1 ]]; then
    KERNELORG_JSON="$(tmp_fetch_kernelorg_releases_json)"
    [[ -n "${KERNELORG_JSON}" ]] && echo "INFO: fetched kernel.org releases.json for latest resolution: ${KERNELORG_JSON}"
  fi

  # tmp file must be global-safe for trap under 'set -u'
  TMP_JSON="$(mktemp)"
  trap 'rm -f "${TMP_JSON:-}" "${KERNELORG_JSON:-}"' EXIT

  fetch_releases_json "${TMP_JSON}"

  echo "Resolving latest versions for requested series:"
  declare -A series_to_version=()

  for s in "${SERIES_LIST[@]}"; do
    v="$(get_latest_version_for_series "${TMP_JSON}" "${s}")"
    if [[ -z "${v}" || "${v}" == "null" ]]; then
      if [[ ${LATEST_ALL} -eq 1 ]]; then
        echo "WARN: ${s} is not described in releases.json; trying to discover the latest available version anyway." >&2
        v="$(resolve_latest_available_for_series "${KERNELORG_JSON}" "${s}")"
        if [[ -z "${v}" ]]; then
          echo "ERROR: no versions found for series ${s} even when searching ${KERNEL_SOURCE_BASE}" >&2
          exit 1
        fi
      else
        echo "ERROR: could not find any release for series ${s} in releases.json" >&2
        exit 1
      fi
    elif [[ ${LATEST_ALL} -eq 1 ]]; then
      latest="$(resolve_latest_available_for_series "${KERNELORG_JSON}" "${s}")"
      if [[ -n "${latest}" && "${latest}" != "${v}" ]]; then
        echo "INFO: series ${s}: pinned ${v} -> latest ${latest}" >&2
        v="${latest}"
      else
        # If EOL series isn't present in kernel.org json, keep pinned.
        [[ -z "${latest}" ]] && echo "INFO: series ${s}: no latest found from kernel.org (EOL?), keep pinned ${v}" >&2
      fi
    fi

    series_to_version["${s}"]="${v}"
    echo "  ${s} -> ${v}"
  done

  if [[ ${DRY_RUN} -eq 1 ]]; then
    echo
    echo "DRY-RUN mode enabled: no downloads/extracts/make will be executed."
    echo "Planned actions under ${BASE_DIR}:"
    echo
    for s in "${SERIES_LIST[@]}"; do
      v="${series_to_version[${s}]}"
      kroot="${BASE_DIR}/${v}"
      build_dir="$(build_dir_for_tree "${kroot}")"
      if [[ -d "${build_dir}" ]]; then
        print_existing_toolchain_info "${build_dir}" || true
        print_toolchain_info_reason "${build_dir}" || true
      fi
      print_plan_for_kernel "${s}" "${v}"
    done
    exit 0
  fi

  echo
  echo "Preparing trees under ${BASE_DIR}:"
  for s in "${SERIES_LIST[@]}"; do
    v="${series_to_version[${s}]}"
    kroot="${BASE_DIR}/${v}"

    if ! ensure_extracted_sources "${s}" "${v}" "${kroot}" "${KERNELORG_JSON}"; then
      echo "SKIP: ${v} (sources not available / download skipped)" >&2
      echo
      continue
    fi

    prepare_modules "${v}" "${kroot}" || {
      if [[ ${STRICT} -eq 1 ]]; then
        exit 1
      fi
      echo "WARN: failed to prepare ${v} (skip)" >&2
      echo
      continue
    }

    echo "OK: ${v} prepared at:"
    echo "    KERNELDIR=${kroot}/build-${ARCH}"
    echo
  done

  echo "All done."
  echo "Example build (external module):"
  echo "  export ARCH=${ARCH}"
  echo "  export CROSS_COMPILE=${CROSS_COMPILE}"
  local example_build_dir="${BASE_DIR}/<version>/build-${ARCH}"
  if [[ ${USE_TOOLCHAIN_SUBDIR} -eq 1 && -n "${TOOLCHAIN_SUBDIR_TAG}" ]]; then
    example_build_dir="${example_build_dir}/${TOOLCHAIN_SUBDIR_TAG}"
  fi
  echo "  export KERNELDIR=${example_build_dir}"
  echo "  make -C \"\$KERNELDIR\" M=/path/to/module modules -j\"${JOBS}\""
}

main "$@"

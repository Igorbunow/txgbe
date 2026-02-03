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

# Optional directory with per-kernel configs to import into O= build dir
# Can be set via env CONFIG_DIR=... or CLI --config-dir ...
CONFIG_DIR="${CONFIG_DIR:-}"

# Optional "latest" behavior (default OFF):
#  - LATEST_ALL=1          : try to use latest available versions for ALL series
#  - LATEST_ON_BROKEN=1    : try to use latest available only when the pinned one is broken/unavailable
LATEST_ALL="${LATEST_ALL:-0}"
LATEST_ON_BROKEN="${LATEST_ON_BROKEN:-0}"

CDN_BASE="https://cdn.kernel.org/pub/linux/kernel"

SERIES_LIST=("4.19" "5.4" "5.10" "5.15" "6.1" "6.6" "6.12" "6.18")

usage() {
  cat <<EOF
Usage: $0 [--releases-json /path/to/releases.json] [--config-dir /path] [--latest-all] [--latest-on-broken] [--force] [--strict]

Environment overrides:
  ARCH, CROSS_COMPILE, BASE_DIR, JOBS, RELEASES_JSON, CONFIG_DIR, LATEST_ALL, LATEST_ON_BROKEN

If RELEASES_JSON is provided and points to an existing file, it will be used
instead of fetching ${RELEASES_JSON_URL}.

Options:
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
  -h, --help              Show this help.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
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
      --latest-all)
        LATEST_ALL=1
        shift
        ;;
      --latest-on-broken)
        LATEST_ON_BROKEN=1
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

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 1
  }
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

tarball_url_for_version() {
  local version="$1"
  local vdir
  vdir="$(major_dir_for_version "${version}")"
  local tb
  tb="$(tarball_name_for_version "${version}")"
  echo "${CDN_BASE}/${vdir}/${tb}"
}

resolve_latest_available_for_series() {
  # Given kernel.org releases.json file and series "6.6", pick highest version "6.6.*"
  # that is also present on CDN (HEAD OK). Echo version or empty if none found.
  local kernelorg_json="$1"
  local series="$2"

  if [[ -z "${kernelorg_json}" || ! -f "${kernelorg_json}" ]]; then
    echo ""
    return 0
  fi

  local candidates
  candidates="$(jq -r --arg s "${series}." '
    .releases[]? | select(.version? and (.version | startswith($s))) | .version
  ' "${kernelorg_json}" 2>/dev/null | sort -V)"

  if [[ -z "${candidates}" ]]; then
    echo ""
    return 0
  fi

  # iterate from newest to oldest
  local v
  while read -r v; do
    : # placeholder
  done < /dev/null

  # reverse by sorting -V then tac
  while read -r v; do
    if http_exists "$(tarball_url_for_version "${v}")"; then
      echo "${v}"
      return 0
    fi
  done < <(echo "${candidates}" | tac)

  echo ""
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

major_dir_for_version() {
  # Input: full version like 6.12.68 or 4.19.312
  # Output: v6.x or v4.x
  local v="$1"
  local major="${v%%.*}"
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

  local vdir
  vdir="$(major_dir_for_version "${version}")"
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
  if [[ ! "${selected_version}" =~ ^[0-9]+.[0-9]+.[0-9]+$ ]]; then
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
  local build_dir="${kroot}/build-${ARCH}"

  mkdir -p "${build_dir}"

  # If user provided external configs, import them before any config generation.
  import_config_if_available "${version}" "${build_dir}"

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
}

main() {
  parse_args "$@"

  as_root_hint

  need_cmd curl
  need_cmd jq
  need_cmd tar
  need_cmd make
  need_cmd sort
  need_cmd xz

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
      echo "ERROR: could not find any release for series ${s} in releases.json" >&2
      exit 1
    fi

    if [[ ${LATEST_ALL} -eq 1 ]]; then
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
  echo "  export KERNELDIR=${BASE_DIR}/<version>/build-${ARCH}"
  echo "  make -C \"\$KERNELDIR\" M=/path/to/module modules -j\"${JOBS}\""
}

main "$@"


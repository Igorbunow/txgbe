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

CDN_BASE="https://cdn.kernel.org/pub/linux/kernel"

SERIES_LIST=("4.19" "5.4" "5.10" "5.15" "6.1" "6.6" "6.12" "6.18")

usage() {
  cat <<EOF
Usage: $0 [--releases-json /path/to/releases.json] [--force] [--strict]

Environment overrides:
  ARCH, CROSS_COMPILE, BASE_DIR, JOBS, RELEASES_JSON

If RELEASES_JSON is provided and points to an existing file, it will be used
instead of fetching ${RELEASES_JSON_URL}.

Options:
  --releases-json <path>  Use local JSON lock-file (your format: {"kernels":[...]}).
  --force                 Re-download tarballs, re-extract sources and re-run modules_prepare.
  --force-download        Only re-download tarballs.
  --force-extract         Only re-extract sources.
  --force-prepare         Only re-run defconfig/olddefconfig/modules_prepare.
  --strict                Fail on missing tarball/HTTP errors (default: skip missing versions).
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
  local url="${CDN_BASE}/${vdir}/${tb}"

  mkdir -p "${dest_dir}"
  if [[ -f "${dest_dir}/${tb}" && ${FORCE_DOWNLOAD} -eq 0 ]]; then
    echo "Tarball already exists (skip): ${dest_dir}/${tb}"
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

  echo "Downloading ${url}"
  curl -fL --retry 3 --retry-delay 2 -o "${dest_dir}/${tb}" "${url}"
}

ensure_extracted_sources() {
  local version="$1"
  local kroot="$2"   # /opt/kernels/<ver>
  local src_dir="${kroot}/src"
  local tb_dir="${kroot}/_dl"

  mkdir -p "${src_dir}" "${tb_dir}"

  local tb
  tb="$(tarball_name_for_version "${version}")"

  if ! download_tarball "${version}" "${tb_dir}"; then
    # download_tarball already handled strict/non-strict
    return 1
  fi

  # download_tarball may return 2 to indicate "skip"
  if [[ ! -f "${tb_dir}/${tb}" ]]; then
    return 1
  fi

  local extracted
  extracted="$(extract_src_dirname "${version}")"

  if [[ -d "${src_dir}/${extracted}" && ${FORCE_EXTRACT} -eq 0 ]]; then
    echo "Sources already extracted (skip): ${src_dir}/${extracted}"
    return 0
  fi

  echo "Extracting ${tb_dir}/${tb} -> ${src_dir}"
  rm -rf "${src_dir:?}/${extracted}"
  tar -C "${src_dir}" -xf "${tb_dir}/${tb}"

  if [[ ! -d "${src_dir}/${extracted}" ]]; then
    echo "ERROR: expected source directory not found after extraction: ${src_dir}/${extracted}" >&2
    exit 1
  fi
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

  if [[ ${FORCE_PREPARE} -eq 0 ]] && already_prepared "${build_dir}"; then
    echo "==> Kernel ${version} already prepared (skip)"
    echo "    BUILD: ${build_dir}"
    return 0
  fi

  echo "==> Preparing kernel ${version}"
  echo "    SRC : ${src_dir}"
  echo "    BUILD: ${build_dir}"
  echo "    ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE}"

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

  # tmp file must be global-safe for trap under 'set -u'
  TMP_JSON="$(mktemp)"
  trap 'rm -f "${TMP_JSON:-}"' EXIT

  fetch_releases_json "${TMP_JSON}"

  echo "Resolving latest versions for requested series:"
  declare -A series_to_version=()

  for s in "${SERIES_LIST[@]}"; do
    v="$(get_latest_version_for_series "${TMP_JSON}" "${s}")"
    if [[ -z "${v}" || "${v}" == "null" ]]; then
      echo "ERROR: could not find any release for series ${s} in releases.json" >&2
      exit 1
    fi
    series_to_version["${s}"]="${v}"
    echo "  ${s} -> ${v}"
  done

  echo
  echo "Preparing trees under ${BASE_DIR}:"
  for s in "${SERIES_LIST[@]}"; do
    v="${series_to_version[${s}]}"
    kroot="${BASE_DIR}/${v}"

    if ! ensure_extracted_sources "${v}" "${kroot}"; then
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


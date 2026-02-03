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
CDN_BASE="https://cdn.kernel.org/pub/linux/kernel"

SERIES_LIST=("4.19" "5.4" "5.10" "5.15" "6.1" "6.6" "6.12" "6.18")

usage() {
  cat <<EOF
Usage: $0 [--releases-json /path/to/releases.json]

Environment overrides:
  ARCH, CROSS_COMPILE, BASE_DIR, JOBS, RELEASES_JSON

If RELEASES_JSON is provided and points to an existing file, it will be used
instead of fetching ${RELEASES_JSON_URL}.
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
  if [[ -f "${dest_dir}/${tb}" ]]; then
    echo "Tarball already exists: ${dest_dir}/${tb}"
    return 0
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

  download_tarball "${version}" "${tb_dir}"

  local extracted
  extracted="$(extract_src_dirname "${version}")"

  if [[ -d "${src_dir}/${extracted}" ]]; then
    echo "Sources already extracted: ${src_dir}/${extracted}"
    return 0
  fi

  echo "Extracting ${tb_dir}/${tb} -> ${src_dir}"
  tar -C "${src_dir}" -xf "${tb_dir}/${tb}"

  if [[ ! -d "${src_dir}/${extracted}" ]]; then
    echo "ERROR: expected source directory not found after extraction: ${src_dir}/${extracted}" >&2
    exit 1
  fi
}

prepare_modules() {
  local version="$1"
  local kroot="$2"

  local src_dir="${kroot}/src/$(extract_src_dirname "${version}")"
  local build_dir="${kroot}/build-${ARCH}"

  mkdir -p "${build_dir}"

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

  local tmp_json
  tmp_json="$(mktemp)"
  trap 'rm -f "${tmp_json}"' EXIT

  fetch_releases_json "${tmp_json}"

  echo "Resolving latest versions for requested series:"
  declare -A series_to_version=()

  for s in "${SERIES_LIST[@]}"; do
    v="$(get_latest_version_for_series "${tmp_json}" "${s}")"
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

    ensure_extracted_sources "${v}" "${kroot}"
    prepare_modules "${v}" "${kroot}"

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


#!/usr/bin/env bash
set -Eeuo pipefail

# Build txgbe against multiple kernel trees (matrix build).
#
# Usage:
#   KERNELDIRS="/path/k419 /path/k54 /path/k510 ..." tools/build_matrix.sh
#
# Optional:
#   KEEP_GOING=1   continue after failures (default: 1)
#   CLEAN_FIRST=1  run module clean before each build (default: 1)
#   LOGDIR=logs    where to store logs (default: logs)
#
# Environment propagated to kbuild:
#   ARCH, CROSS_COMPILE, LLVM, CC, KCFLAGS, EXTRA_CFLAGS, V, JOBS

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

: "${KERNELDIRS:?Set KERNELDIRS="/path/to/kernelA /path/to/kernelB ..."}"

KEEP_GOING="${KEEP_GOING:-1}"
CLEAN_FIRST_DEFAULT="${CLEAN_FIRST:-1}"
LOGDIR="${LOGDIR:-${REPO_ROOT}/logs}"

mkdir -p "${LOGDIR}"

build_one="${SCRIPT_DIR}/build_one.sh"

fail_count=0
declare -a failed=()


get_kernelrelease() {
  local kdir="$1"
  # Do NOT call 'make kernelrelease' here: it may attempt to create .tmp_* in kdir,
  # which must be read-only in our build system.
  #
  # Prefer files produced by modules_prepare / headers packages.
  if [[ -f "${kdir}/include/config/kernel.release" ]]; then
    cat "${kdir}/include/config/kernel.release"
    return 0
  fi
  if [[ -f "${kdir}/include/generated/utsrelease.h" ]]; then
    # Example: #define UTS_RELEASE "6.12.68"
    sed -n 's/^[[:space:]]*#define[[:space:]]+UTS_RELEASE[[:space:]]+"(.*)".*/\1/p' \
      "${kdir}/include/generated/utsrelease.h" | head -n1
    return 0
  fi
  # Last resort: directory name
  basename "${kdir}"
}


echo "==> Matrix build start"
echo "    KERNELDIRS: ${KERNELDIRS}"
echo "    LOGDIR:     ${LOGDIR}"
echo "    KEEP_GOING: ${KEEP_GOING}"
echo "    CLEAN_FIRST(default): ${CLEAN_FIRST_DEFAULT}"
echo ""

for kdir in ${KERNELDIRS}; do
  if [[ ! -d "${kdir}" ]]; then
    echo "!! Skipping missing directory: ${kdir}" >&2
    fail_count=$((fail_count + 1))
    failed+=("${kdir}:missing")
    [[ "${KEEP_GOING}" == "1" ]] && continue
    exit 2
  fi

  rel="$(get_kernelrelease "${kdir}")"
  safe_rel="$(echo "${rel}" | tr '/ ' '__')"
  log="${LOGDIR}/build-${safe_rel}.log"

  echo "============================================================"
  echo "==> Building for: ${rel}"
  echo "    KERNELDIR: ${kdir}"
  echo "    Log:       ${log}"
  echo "============================================================"

  # We want to capture *all* output, but also keep an exit code.
  set +e
  CLEAN_FIRST="${CLEAN_FIRST_DEFAULT}" "${build_one}" "${kdir}" >"${log}" 2>&1
  rc=$?
  set -e

  if [[ "${rc}" -ne 0 ]]; then
    echo "!! FAIL: ${rel} (rc=${rc})"
    fail_count=$((fail_count + 1))
    failed+=("${rel}:${rc}:${log}")
    if [[ "${KEEP_GOING}" != "1" ]]; then
      echo "Stopping on first failure (KEEP_GOING != 1)."
      exit "${rc}"
    fi
  else
    echo "OK: ${rel}"
  fi
  echo ""
done

echo "==> Matrix build done"
if [[ "${fail_count}" -ne 0 ]]; then
  echo "==> Failures: ${fail_count}"
  for f in "${failed[@]}"; do
    echo "    ${f}"
  done
  exit 1
fi

echo "==> All builds succeeded"
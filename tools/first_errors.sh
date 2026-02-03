#!/usr/bin/env bash
set -Eeuo pipefail

# Extract first compilation errors from a build log.
#
# Usage:
#   tools/first_errors.sh logs/build-*.log

if [[ "$#" -lt 1 ]]; then
  echo "Usage: $0 <logfile> [more logfiles...]" >&2
  exit 2
fi

for log in "$ @"; do
  echo "============================================================"
  echo "LOG: ${log}"
  echo "------------------------------------------------------------"
  if [[ ! -f "${log}" ]]; then
    echo "Missing file."
    continue
  fi

  # Typical patterns: "error:", "fatal error:", "implicit declaration"
  # Print first ~40 matching lines with some context.
  awk '
    BEGIN { shown=0 }
    /fatal error:| error:|implicit declaration of function/ {
      if (shown < 40) {
        print
        shown++
      }
    }
  ' "${log}" || true

  echo ""
done
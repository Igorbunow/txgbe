#!/bin/bash
# SPDX-License-Identifier: GPL-2.0

# This helper normalizes the various kernel header/source layouts into the
# KSRC/CONFFILE inputs expected by kcompat-generator.sh.
#
# The build system may pass:
#  - a kernel build output directory ("objtree")
#  - a kernel source directory
#  - a distro headers directory which contains "build" and/or "source" symlinks
#
# We prefer:
#  - CONFFILE from the *build* directory (include/generated/autoconf.h)
#  - KSRC from the *source* directory (must contain include/linux/kernel.h)

set -euo pipefail

# shellcheck disable=SC2086
KSRC_PARAM="$1"
KOBJ_PARAM="${2-}"

if [ -z "$KSRC_PARAM" ]; then
    echo "Error: Please provide the kernel directory (KERNELDIR/KSRC) as the first argument." >&2
    exit 1
fi

die_prepare_hint() {
    cat >&2 <<'EOF'
Error: cannot find kernel configuration header (autoconf.h).

Hints:
  - If you are using a full kernel source tree, run:
        make olddefconfig && make modules_prepare
  - If you are using distro kernel headers, ensure the headers package is installed
    and pass the corresponding KERNELDIR (often /lib/modules/<ver>/build).
EOF
    exit 1
}

realpath_f() {
    # Portable "realpath": prefer readlink -f, fallback to realpath.
    local p="$1"
    readlink -f "$p" 2>/dev/null || realpath "$p" 2>/dev/null || echo "$p"
}

is_kernel_tree() {
    [ -e "$1/Makefile" ] && [ -d "$1/include" ]
}

find_conffile_in() {
    local d="$1"
    if [ -e "$d/include/generated/autoconf.h" ]; then
        echo "$d/include/generated/autoconf.h"
        return 0
    fi
    if [ -e "$d/include/linux/autoconf.h" ]; then
        echo "$d/include/linux/autoconf.h"
        return 0
    fi
    return 1
}

find_existing_path() {
    local paths=("$@")
    for path in "${paths[@]}"; do
        if [ -e "$path" ]; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

find_source_root() {
    local build_dir="$1"

    # Prefer "source" symlink commonly provided by kernel header packages and O= builds.
    if [ -e "$build_dir/source" ]; then
        local src
        src="$(realpath_f "$build_dir/source")"
        if [ -e "$src/include/linux/kernel.h" ]; then
            echo "$src"
            return 0
        fi
    fi

    # If build_dir itself looks like a source tree, use it.
    if [ -e "$build_dir/include/linux/kernel.h" ]; then
        echo "$build_dir"
        return 0
    fi

    # Some layouts provide "KBUILD_SRC"-style sibling named "source" at the parent.
    if [ -e "$(dirname "$build_dir")/source/include/linux/kernel.h" ]; then
        echo "$(realpath_f "$(dirname "$build_dir")/source")"
        return 0
    fi

    # Fallback: use the directory inferred from CONFFILE.
    if [ -e "$build_dir/include/linux/kernel.h" ]; then
        echo "$build_dir"
        return 0
    fi

    return 1
}

KSRC_PARAM="$(realpath_f "$KSRC_PARAM")"

# Resolve "build" symlink if caller passed /lib/modules/<ver> instead of /lib/modules/<ver>/build.
if [ -e "$KSRC_PARAM/build" ] && is_kernel_tree "$(realpath_f "$KSRC_PARAM/build")"; then
    KSRC_PARAM="$(realpath_f "$KSRC_PARAM/build")"
fi

BUILD_DIR="$KSRC_PARAM"

CONFIG_PATHS=()
if [ -n "${KOBJ_PARAM}" ]; then
    CONFIG_PATHS+=(
        "${KOBJ_PARAM}/include/generated/autoconf.h"
        "${KOBJ_PARAM}/include/linux/autoconf.h"
    )
fi
CONFIG_PATHS+=(
    "${KSRC_PARAM}/include/generated/autoconf.h"
    "${KSRC_PARAM}/include/linux/autoconf.h"
)

CONFFILE=$(find_existing_path "${CONFIG_PATHS[@]}")

if [ -z "$CONFFILE" ]; then
    die_prepare_hint
fi

KSRC=""
if ! KSRC="$(find_source_root "$BUILD_DIR")"; then
    # As a last resort, assume the include directory that contains autoconf.h
    # is also the include root.
    KSRC="$(realpath_f "$BUILD_DIR")"
fi

KSRC="$KSRC" OUT=kcompat_generated_defs.h CONFFILE="$CONFFILE" bash kcompat-generator.sh

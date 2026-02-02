#!/bin/bash

# shellcheck disable=SC2086
KSRC_PARAM="$1"

if [ -z "$KSRC_PARAM" ]; then
    echo "Error: Please provide the KSRC parameter."
    exit 1
fi

find_existing_path() {
    for path in "$@"; do
        if [ -e "$path" ]; then
            echo "$path"
            return
        fi
    done
}

CONFIG_PATHS=(
    "${KSRC_PARAM}/include/generated/autoconf.h"
    "${KSRC_PARAM}/include/linux/autoconf.h"
)

CONFFILE=$(find_existing_path "${CONFIG_PATHS[@]}")

PARENT_DIR=$(dirname "$KSRC_PARAM")
VERSION_ROOT=$(basename "$KSRC_PARAM")
VERSION_ROOT=${VERSION_ROOT%-common}
VERSION_ROOT=${VERSION_ROOT%-amd64}
VERSION_ROOT=${VERSION_ROOT%-generic}

if [ -z "$CONFFILE" ]; then
    if [ -d "$PARENT_DIR" ]; then
        found=0
        for candidate in "$PARENT_DIR/${VERSION_ROOT}"*; do
            [ -e "$candidate" ] || continue
            for cfg in "$candidate/include/generated/autoconf.h" "$candidate/include/linux/autoconf.h"; do
                if [ -e "$cfg" ]; then
                    CONFFILE="$cfg"
                    found=1
                    break
                fi
            done
            [ "$found" -eq 1 ] && break
        done

        if [ "$found" -eq 0 ]; then
            if [ -n "$VERSION_ROOT" ]; then
                CONFFILE=$(find "$PARENT_DIR" -maxdepth 5 \
                    \( -path "*/${VERSION_ROOT}*/include/generated/autoconf.h" -o \
                       -path "*/${VERSION_ROOT}*/include/linux/autoconf.h" \) \
                    -print -quit)
            fi
        fi

        if [ -z "$CONFFILE" ]; then
            CONFFILE=$(find "$PARENT_DIR" -maxdepth 5 \
                \( -path "*/include/generated/autoconf.h" -o \
                   -path "*/include/linux/autoconf.h" \) \
                -print -quit)
        fi
    fi
fi

if [ -z "$CONFFILE" ]; then
    echo "No configuration file found."
    exit 1
fi

CONFIG_ROOT=$(dirname "$(dirname "$(dirname "$CONFFILE")")")

INCLUDE_ROOT="$KSRC_PARAM"
if [ ! -e "$INCLUDE_ROOT/include/linux/kernel.h" ] && [ -d "$PARENT_DIR" ]; then
    for candidate in "$PARENT_DIR/${VERSION_ROOT}"*; do
        [ -e "$candidate/include/linux/kernel.h" ] || continue
        INCLUDE_ROOT="$candidate"
        break
    done

    if [ ! -e "$INCLUDE_ROOT/include/linux/kernel.h" ]; then
        for pattern in "*/${VERSION_ROOT}*/include/linux/kernel.h" "*/include/linux/kernel.h"; do
            FOUND_INCLUDE=$(find "$PARENT_DIR" -maxdepth 5 -path "$pattern" -print -quit)
            if [ -n "$FOUND_INCLUDE" ]; then
                INCLUDE_ROOT=$(dirname "$(dirname "$FOUND_INCLUDE")")
                break
            fi
        done
    fi
fi

if [ ! -e "$INCLUDE_ROOT/include/linux/kernel.h" ]; then
    INCLUDE_ROOT="$CONFIG_ROOT"
fi

KSRC="$INCLUDE_ROOT" OUT=kcompat_generated_defs.h CONFFILE="$CONFFILE" bash kcompat-generator.sh

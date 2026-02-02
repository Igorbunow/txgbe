#!/bin/bash

KSRC="$1"

if [ -z "$1" ]; then
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
    "${KSRC}/include/generated/autoconf.h"
    "${KSRC}/include/linux/autoconf.h"
)

CONFFILE=$(find_existing_path "${CONFIG_PATHS[@]}")

if [ -z "$CONFFILE" ]; then
    echo "No configuration file found."
    exit 1
fi

KSRC="$KSRC" OUT=kcompat_generated_defs.h CONFFILE="$CONFFILE" bash kcompat-generator.sh

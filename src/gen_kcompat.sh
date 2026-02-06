#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Helper to generate kcompat_generated_defs.h in a robust, make-safe way.
# We keep this logic out of Makefile recipes to avoid fragile multi-line shell
# constructs and $-expansion issues.
#
# Arguments:
#   1: KERNELRELEASE
#   2: SRCTREE (kernel source tree, may be absolute)
#   3: OBJTREE (kernel object tree, may be "." depending on headers layout)
#   4: KBUILD_PWD (kernel build directory: make's $(CURDIR) when invoked by Kbuild)
#   5: MOD_SRC (module source dir: $(src))
#   6: MOD_OBJ (module object dir: $(obj))
#   7: GEN_NAME (kcompat_generated_defs.h)
#   8: OUT_PATH (full destination path for generated header)
set -eu

krel="$1"
srctree="$2"
objtree="$3"
kbuild_pwd="$4"
mod_src="$5"
mod_obj="$6"
gen_name="$7"
out_path="$8"

realpath_f() {
  # Portable "realpath": prefer readlink -f, fallback to realpath.
  local p="$1"
  readlink -f "$p" 2>/dev/null || realpath "$p" 2>/dev/null || echo "$p"
}

objtree_real="$objtree"
case "$objtree_real" in
  ""|"."|"./") objtree_real="$kbuild_pwd" ;;
esac

echo "Generating ${gen_name} for ${krel} from SRCTREE=${srctree} OBJTREE=${objtree_real}"

# Run generator from module source directory (expected by upstream script).
(
  cd "$mod_src"
  # Silence generator output (matches previous behavior).
  ./generated.sh "$srctree" "$objtree_real" >/dev/null
)

# If Kbuild uses separate obj dir, generator may have dropped the file into source dir.
src_file="${mod_src}/${gen_name}"

mod_src_real="$(realpath_f "$mod_src")"
mod_obj_real="$(realpath_f "$mod_obj")"
out_path_real="$(realpath_f "$out_path")"
src_file_real="$(realpath_f "$src_file")"

if [ "$mod_src_real" != "$mod_obj_real" ] && [ -f "$src_file" ]; then
  if [ "$src_file_real" = "$out_path_real" ]; then
    # Avoid "cp: same file" when paths differ only by "." or symlinks.
    true
  else
    # Copy+remove when source and destination are distinct paths.
    cp -f "$src_file" "$out_path"
    rm -f "$src_file"
  fi
fi

if [ ! -f "$out_path" ]; then
  echo "ERROR: expected output file not found: $out_path" >&2
  exit 1
fi

exit 0

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

if [ "$mod_src" != "$mod_obj" ] && [ -f "$src_file" ]; then
  # Copy+remove is safe even when paths end up equal (no 'mv: same file' issue).
  cp -f "$src_file" "$out_path"
  rm -f "$src_file"
fi

if [ ! -f "$out_path" ]; then
  echo "ERROR: expected output file not found: $out_path" >&2
  exit 1
fi

exit 0

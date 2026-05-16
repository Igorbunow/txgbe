# Verbose Build with Temps

[ English ](verbose_build.md) | [ Русский ](verbose_build_ru.md)

To perform a verbose build and save all intermediate compilation results (e.g., for macro debugging or checking flags), use the following commands:

```bash
# Clean previous build
make -C /lib/modules/$(uname -r)/build M="$PWD/src" clean

# Build with V=1 (verbose) and save temporary files (.i, .s)
make -C /lib/modules/$(uname -r)/build M="$PWD/src" modules \
  V=1 KCFLAGS="-save-temps=obj" -j1 2>&1 | tee build_verbose_save_temps.log
```

**Benefits:**
- `V=1`: prints the full compilation commands executed by kbuild.
- `-save-temps=obj`: saves preprocessed files (`.i`) and assembly code (`.s`) in the `src/` directory.
- `tee ...`: records the entire build output to a log file for further analysis.

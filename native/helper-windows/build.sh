#!/bin/sh
# Builds the Zeyvola Windows helper (x64) with Zig 0.17 (MIT), on macOS, Linux or Windows. The
# steps are in build.zig: Zig sources only, no C runtime, no compiler-rt, no third-party bindings,
# import libraries generated from imports/*.def. Output: bin/zeyvola-win.exe (unsigned).
set -eu
cd "$(dirname "$0")"
# zig: $ZIG, else tools/.cache/zig/zig, else the one on PATH.
if [ -z "${ZIG:-}" ]; then
  if [ -x ../../tools/.cache/zig/zig ]; then ZIG=../../tools/.cache/zig/zig; else ZIG=zig; fi
fi
"$ZIG" build --prefix .
ls -l bin/zeyvola-win.exe

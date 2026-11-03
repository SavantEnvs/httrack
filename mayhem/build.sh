#!/usr/bin/env bash
#
# mayhem/build.sh — build httrack's libFuzzer harnesses (fuzz/) sanitized, plus a normal-flags
# build of the project for mayhem/test.sh. Runs in /mayhem as `mayhem`; idempotent and offline.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
HARNESSES="arc cachendx charset codepage entities filters header htsparse idna meta singlefile sitemap unescape url"

# 0) The generated build system (configure, Makefile.in, ...) is gitignored upstream: regenerate it.
sh ./bootstrap

# 1) Sanitized fuzz build, out of tree (mayhem/.gitignore covers the build dirs).
FB="$SRC/mayhem/build-fuzz"
mkdir -p "$FB"
# 1a) lsan_off: ASan/UBSan stay on, only leak detection goes (SPEC §6.2 item 15).
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.c" -o "$FB/lsan_off.o"
# 1b) the project itself, instrumented + DWARF 3, plus the harnesses linked with libFuzzer.
cd "$FB"
if [ ! -f Makefile ]; then
  CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -O1" LDFLAGS="$SANITIZER_FLAGS" \
    sh "$SRC/configure" --enable-fuzzers --disable-shared --disable-https --disable-online-unit-tests
fi
THREADS_LIBS="$(sed -n 's/^THREADS_LIBS = //p' fuzz/Makefile)"
DEFAULT_LDFLAGS="$(sed -n 's/^DEFAULT_LDFLAGS = //p' fuzz/Makefile)"
LDADD_FUZZ="$FB/lsan_off.o $FB/src/libhttrack.la $THREADS_LIBS"
make -j"$MAYHEM_JOBS" -C src libhttrack.la
for h in $HARNESSES; do
  rm -f "fuzz/fuzz-$h"
  make -C fuzz "fuzz-$h" LDADD="$LDADD_FUZZ"
  cp "fuzz/fuzz-$h" "$SRC/fuzz-$h"
done

# 1c) Standalone run-once reproducers: same objects, LLVM's driver instead of libFuzzer.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$FB/standalone_main.o"
for h in $HARNESSES; do
  rm -f "fuzz/fuzz-$h"
  make -C fuzz "fuzz-$h" LDADD="$FB/standalone_main.o $LDADD_FUZZ" \
    AM_LDFLAGS="$DEFAULT_LDFLAGS -static-libtool-libs"
  cp "fuzz/fuzz-$h" "$SRC/fuzz-$h-standalone"
done

# 2) The test suite: the project with its NORMAL flags, built so test.sh only runs it.
TB="$SRC/mayhem/build-test"
mkdir -p "$TB"
cd "$TB"
if [ ! -f Makefile ]; then
  env -u CFLAGS -u LDFLAGS CFLAGS="-O2 $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" \
    sh "$SRC/configure" --disable-https --disable-online-unit-tests
fi
make -j"$MAYHEM_JOBS"
make -j"$MAYHEM_JOBS" -C tests check TESTS=

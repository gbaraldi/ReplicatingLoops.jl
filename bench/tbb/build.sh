#!/bin/sh
# Build against the oneTBB from Julia's oneTBB_jll artifact (or set TBB_ROOT).
set -e
cd "$(dirname "$0")"
TBB_ROOT=${TBB_ROOT:-$(julia --startup-file=no -e 'using Pkg; Pkg.activate(temp=true; io=devnull); Pkg.add("oneTBB_jll"; io=devnull); using oneTBB_jll; print(dirname(dirname(oneTBB_jll.libtbb_path)))')}
clang++ -O3 -march=native -std=c++17 -I"$TBB_ROOT/include" bench_tbb.cpp \
    -L"$TBB_ROOT/lib" -Wl,-rpath,"$TBB_ROOT/lib" -ltbb -o bench_tbb
echo "built bench_tbb against $TBB_ROOT"

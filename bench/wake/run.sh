#!/bin/sh
# Wake-up measurements behind the "where the time goes" part of the summary.
# Writes bench/results/wake/{tri,spawn,futex}.csv. Needs oneTBB (TBB_ROOT, or
# found through oneTBB_jll as in ../tbb/build.sh), perf and strace.
set -e
cd "$(dirname "$0")"
PKG=$(cd ../.. && pwd)
OUT=$PKG/bench/results/wake
mkdir -p "$OUT" build
TBB_ROOT=${TBB_ROOT:-$(julia --startup-file=no -e 'using Pkg; Pkg.activate(temp=true; io=devnull); Pkg.add("oneTBB_jll"; io=devnull); using oneTBB_jll; print(dirname(dirname(oneTBB_jll.libtbb_path)))')}
for p in tri_tbb tbb_strace axpy1m_tbb; do
    clang++ -O3 -march=native -std=c++17 -I"$TBB_ROOT/include" $p.cpp -L"$TBB_ROOT/lib" -Wl,-rpath,"$TBB_ROOT/lib" -ltbb -o build/$p
done
export OPENBLAS_NUM_THREADS=1

# Triangle loops with threads awake and asleep, oneTBB with N + 1 threads.
echo "impl,threads,n,serial_us,awake_us,asleep_us" > "$OUT/tri.csv"
for n in 300 3000; do
    for t in 8 32 63; do
        build/tri_tbb $((t + 1)) $n >> "$OUT/tri.csv"
        julia +1.13 -t$t,1 --project="$PKG" tri_jl.jl $n >> "$OUT/tri.csv"
    done
done

# One cold @spawn, split with perf context-switch records (8 threads).
echo "condition,spawner_us,to_cpu_us,julia_us,total_us" > "$OUT/spawn.csv"
JULIA_THREAD_SLEEP_THRESHOLD=infinite julia +1.13 -t8,1 spawn_spinning.jl >> "$OUT/spawn.csv"
# 150 µs three times: whether the core reaches deep sleep in that time varies.
for run in "0.00015 1" "0.00015 2" "0.00015 3" "0.0005" "0.002"; do
    set -- $run
    gap=$1
    JULIA_THREAD_SLEEP_THRESHOLD=0 perf record -q -e dummy --switch-events -k mono -o build/sw.data -- \
        julia +1.13 -t8,1 spawn_split.jl build/spawns.csv $gap > /dev/null 2>&1
    perf script -i build/sw.data --show-switch-events -F tid,time --ns 2>/dev/null | grep 'SWITCH IN' > build/switches.txt
    us=$(python3 -c "print(round($gap * 1e6))")
    label="asleep ${us} us"; [ -n "$2" ] && label="$label (run $2)"
    python3 split.py build/spawns.csv build/switches.txt "$label" >> "$OUT/spawn.csv"
done

# 1M-element axpy back to back and after 2 ms / 50 ms idle (32 threads), with
# Julia's threads allowed to sleep and never sleeping.
echo "impl,mode,us,speedup" > "$OUT/axpy1m.csv"
build/axpy1m_tbb 33 >> "$OUT/axpy1m.csv"
julia +1.13 -t32,1 --project="$PKG/bench" axpy1m.jl >> "$OUT/axpy1m.csv"
JULIA_THREAD_SLEEP_THRESHOLD=infinite julia +1.13 -t32,1 --project="$PKG/bench" axpy1m.jl " (Julia threads never sleep)" >> "$OUT/axpy1m.csv"

# futex wake calls per cold triangle loop, 9 threads each.
echo "impl,threads,futex_wakes" > "$OUT/futex.csv"
strace -f -tt -e trace=futex,write -o build/tbb.strace build/tbb_strace 9 2> /dev/null
python3 count_futex.py build/tbb.strace oneTBB 9 >> "$OUT/futex.csv"
strace -f -tt -e trace=futex,write -o build/jl.strace julia +1.13 -t8,1 --project="$PKG" jl_strace.jl 2> /dev/null
python3 count_futex.py build/jl.strace pforeach 9 >> "$OUT/futex.csv"
echo "wrote $OUT/tri.csv spawn.csv axpy1m.csv futex.csv"

# Derived files for the summary dashboard
python3 derive.py "$OUT"

#!/bin/sh
# Final profiles of pforeach (Julia 1.13, -t32,1): wall clock per task, CPU by
# category, cache fills by source, and contended cache lines (perf c2c, AMD IBS).
# Writes bench/results/profile/*.txt. Needs perf with perf_event_paranoid <= 1.
cd "$(dirname "$0")/../.."
OUT=bench/results/profile
TMP=${TMPDIR:-/tmp}/rl-profile
mkdir -p $OUT $TMP
export OPENBLAS_NUM_THREADS=1
J="julia +1.13 -t32,1 --project=bench bench/profile/workload.jl"
WL="axpy1m axpy1m_cold tri300 spin32 nested small"
: > $OUT/walltime.txt; : > $OUT/cpu.txt; : > $OUT/fills.txt
CTL=$TMP/ctl
rm -f $CTL; mkfifo $CTL
export PERF_CTL=$CTL
for w in $WL; do
    echo "== $w" >> $OUT/walltime.txt
    PERF_CTL= $J $w 5 walltime >> $OUT/walltime.txt 2>&1
    ENABLE_JITPROFILING=1 perf record -q -k 1 -F 2000 --control fifo:$CTL -D -1 -o $TMP/$w.data -- $J $w 5 > /dev/null 2>&1
    perf inject --jit -i $TMP/$w.data -o $TMP/$w.jit.data 2> /dev/null
    python3 bench/profile/categorize.py $TMP/$w.jit.data $w >> $OUT/cpu.txt
    echo "== $w" >> $OUT/fills.txt
    perf stat -x, --control fifo:$CTL -D -1 -e ls_dmnd_fills_from_sys.local_l2,ls_dmnd_fills_from_sys.local_ccx,ls_dmnd_fills_from_sys.near_cache,ls_dmnd_fills_from_sys.far_cache,ls_dmnd_fills_from_sys.dram_io_near,ls_dmnd_fills_from_sys.dram_io_far,instructions,cycles \
        -- $J $w 5 2>> $OUT/fills.txt >> $OUT/fills.txt
done
for w in axpy1m tri300 nested; do
    PERF_CTL= perf c2c record -o $TMP/c2c-$w.data -- $J $w 3 > /dev/null 2>&1
    perf inject --jit -i $TMP/c2c-$w.data -o $TMP/c2c-$w.jit.data 2> /dev/null
    perf c2c report -i $TMP/c2c-$w.jit.data --stdio --stats > $OUT/c2c-$w-stats.txt 2>&1
    perf c2c report -i $TMP/c2c-$w.jit.data --stdio -N --full-symbols 2>/dev/null > $TMP/c2c-$w-full.txt
    head -400 $TMP/c2c-$w-full.txt > $OUT/c2c-$w.txt
done
python3 bench/profile/to_csv.py $TMP
echo "wrote $OUT"

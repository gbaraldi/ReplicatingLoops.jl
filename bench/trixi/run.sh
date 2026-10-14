#!/bin/sh
# Trixi.jl with Polyester against Trixi.jl with ReplicatingLoops: two copies of
# the same Trixi commit, one patched (trixi_pforeach.patch), each in its own
# environment, run at 1, 8 and 32 threads. Writes bench/results/trixi.csv.
set -e
cd "$(dirname "$0")/../.."
PKG=$(pwd)
W=${TMPDIR:-/tmp}/rl-trixi
rm -rf $W && mkdir -p $W && cd $W
git clone -q https://github.com/trixi-framework/Trixi.jl trixi-poly
git -C trixi-poly checkout -q 9e22ce69ed      # main on 14 Oct 2026, 0.17.16-DEV
cp -r trixi-poly trixi-pfor
patch -s -p1 -d trixi-pfor < $PKG/bench/trixi/trixi_pforeach.patch
julia +1.13 --project=env-poly -e "using Pkg; Pkg.develop(path=\"$W/trixi-poly\"); Pkg.add(\"OrdinaryDiffEqLowStorageRK\")"
julia +1.13 --project=env-pfor -e "using Pkg; Pkg.develop(path=\"$PKG\"); Pkg.develop(path=\"$W/trixi-pfor\"); Pkg.add(\"OrdinaryDiffEqLowStorageRK\")"
export OPENBLAS_NUM_THREADS=1
echo "variant,threads,elixir,level,elements,rhs_min_us,rhs_median_us,step_us" > $PKG/bench/results/trixi.csv
for run in "1 poly" "1 pfor" "8 poly" "8 pfor" "32 poly" "32 pfor" "8 pfor" "8 poly" "32 pfor" "32 poly"; do
    set -- $run
    if [ $1 = 1 ]; then TF="-t1,0"; else TF="-t$1,1"; fi
    julia +1.13 $TF --project=env-$2 $PKG/bench/trixi/trixi_bench.jl $2 | tail -n +2 >> $PKG/bench/results/trixi.csv
done

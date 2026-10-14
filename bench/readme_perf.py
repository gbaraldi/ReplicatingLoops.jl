# Regenerate the "## Performance" section of README.md from the result CSVs:
#   bench/results/scaling/{scaling.csv,tables.md}, bench/results/wake/*.csv,
#   bench/results/compare/compare.csv, bench/results/optimizations.csv
#   python3 bench/readme_perf.py
import csv, os, re

R = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
B = f"{R}/bench/results"
rd = lambda p: list(csv.DictReader(open(f"{B}/{p}")))
scal = {r["key"]: r for r in rd("scaling/scaling.csv")}
tri = {r["key"]: r for r in rd("wake/tri_summary.csv")}
spawn = rd("wake/spawn.csv")
futex = {r["impl"]: r for r in rd("wake/futex.csv")}
gaps = {r["key"]: r for r in rd("wake/gaps.csv")}
comp = {r["key"]: r for r in rd("compare/compare.csv")}
opt = rd("optimizations.csv")

x = lambda k: f"{float(scal[k]['speedup']):.3g}×"
cx = lambda k: f"{float(comp[k]['speedup']):.3g}×"
g = lambda impl, lang, mode, sleep="allowed": f"{float(gaps[f'{impl}|{lang}|{sleep}|{mode}']['us']):.3g} µs"

tables = open(f"{B}/scaling/tables.md").read()
tables = re.sub(r"### nthreads default=(\d+) interactive=1 caller pool=interactive julia=1.13.0;.*?oneTBB 2022.0 threads=(\d+)",
                lambda m: f"#### `-t{m.group(1)},1` (oneTBB {m.group(2)} threads)", tables)

s2000 = next(r for r in spawn if r["condition"] == "asleep 2000 us")
short = min(float(r["julia_us"]) for r in spawn if r["condition"].startswith("asleep 150 us"))
spin = next(r for r in spawn if r["condition"] == "threads spinning")


def trirow(impl, t):
    a, b = tri[f"{impl}-{t}-300"], tri[f"{impl}-{t}-3000"]
    f = lambda r, c: f"{float(r[c]):.3g}×"
    return f"| {impl} | {t} | {f(a, 'awake_speedup')} | {f(a, 'asleep_speedup')} | {f(b, 'awake_speedup')} | {f(b, 'asleep_speedup')} |"


GAP_ROWS = [("Polyester", "1.13"), ("oneTBB affinity", "C++"), ("oneTBB", "C++"),
            ("ParkedWorkers", "nightly"), ("parallel_for (vc branch)", "nightly"),
            ("pforeach affinity", "1.13"), ("pforeach", "1.13")]
MODES = ["back to back", "after 2 ms idle", "after 50 ms idle"]


def gaprow(impl, lang):
    cells = [g(impl, lang, m) for m in MODES]
    nev = [g(impl, lang, m, "never") if f"{impl}|{lang}|never|{m}" in gaps else "–" for m in MODES]
    return f"| {impl} | {lang} | " + " | ".join(cells) + " | " + " | ".join(nev) + " |"


CMP_W = [("axpy", 1000), ("axpy", 100000), ("axpy", 1000000), ("axpy", 10000000), ("axpy_cold", 1000000),
         ("tri", 30), ("tri", 300), ("tri", 3000)]
CMP_I = ["pfor", "pfor_aff", "parked", "branch", "threads"]


def cmprow(w, n, t):
    vals = {i: float(comp[f"{w}-{n}-{i}-{t}"]["speedup"]) for i in CMP_I if f"{w}-{n}-{i}-{t}" in comp}
    best = max(vals.values())
    cells = [(f"**{vals[i]:.3g}×**" if vals[i] == best else f"{vals[i]:.3g}×") if i in vals else "–" for i in CMP_I]
    return f"| {w} {n:,} | " + " | ".join(cells) + " |"


sec = f"""## Performance

The charts, with every number linked to its data, are on the
[performance dashboard](https://claude.ai/artifact/4TcpEYtgj34RLyRoDsK9cH). The
numbers below are from Julia 1.13.0 (nightly where marked) and oneTBB 2022.0
on a 2-socket AMD EPYC 9354 (64 cores) shared with other users, run on 14 Oct
2026 (load average 10–30, so rows at 32 and 63 threads are noisier). Speedup
is each language's own serial loop divided by the parallel loop, from the
same run.

### Summary

- **Short loops stay near serial speed.** A 10,000-element `axpy` runs at
  {x('axpy-small-pfor-63')} of serial speed with 63 threads, where oneTBB gets
  {x('axpy-small-tbb-63')} and `@threads` {x('axpy-small-threads-63')}: the caller runs it alone.
- **Large even loops over the same arrays scale furthest with affinity:**
  {x('axpy-large-pfor_aff-32')} at 32 threads on 10M-element `axpy`, against {x('axpy-large-batch-32')} for
  Polyester and {x('axpy-large-tbb_affinity-32')} for oneTBB's affinity partitioner. At 63 threads,
  {x('axpy-large-pfor_aff-63')} against {x('axpy-large-tbb_affinity-63')} (Polyester drops to {x('axpy-large-batch-63')}: its 64 spinning
  workers compete with other users' processes on this machine).
- **Large uneven loops scale like oneTBB:** {x('tri-large-pfor-63')} against {x('tri-large-tbb-63')} at 63
  threads on the 3,000-element triangle.
- **Medium loops depend on how fast helpers start.** Back to back,
  Polyester's always-spinning workers reach {x('axpy-medium-batch-32')} on 1M-element `axpy` at
  32 threads, against {x('axpy-medium-pfor_aff-32')} for `pforeach` with affinity and {x('axpy-medium-tbb_affinity-32')} for oneTBB
  with affinity. On the 300-element triangle at 32 threads, oneTBB reaches
  {x('tri-medium-tbb-32')} and `pforeach` {x('tri-medium-pfor-32')}.

### Where the time goes: starting helpers

Starting one helper on an idle thread (8 threads, median of 1,500 spawns,
`bench/wake/`, split with `perf record --switch-events`):

| Idle before the spawn | Spawner's `@spawn` | Until the thread gets a core | Julia on the woken thread | Total |
|---|---|---|---|---|
""" + "\n".join(
    f"| {r['condition']} | {r['spawner_us']} µs | {(r['to_cpu_us'] + ' µs') if r['to_cpu_us'] else '–'} | {(r['julia_us'] + ' µs') if r['julia_us'] else '–'} | {r['total_us']} µs |"
    for r in spawn) + f"""

- **The hardware is the largest part.** A bare C `futex` wake takes about
  40 µs to get a thread running from 1 ms idle: cores drop into C2 (800 µs
  nominal exit latency) and the `schedutil` governor lowers their clock.
- **Julia's own path on the woken thread** takes {short:.3g} µs after a short sleep
  and {s2000['julia_us']} µs after a long one: the same code, run with cold caches at a low
  clock. With threads spinning, a whole spawn takes {spin['total_us']} µs.
- **oneTBB wakes threads the same way**, one futex wake per thread and never a
  broadcast, in a binary tree where a woken worker wakes two more as soon as
  it runs ({futex['oneTBB']['futex_wakes']} wake calls per cold loop with 9 threads). `pforeach` starts helpers
  cooperatively from a shared counter instead (see How it works), and each
  woken Julia thread makes one extra wake call on its lock ({futex['pforeach']['futex_wakes']} per cold loop).
  After running out of work, oneTBB's workers also spin for up to 1 ms, so
  back-to-back loops find them awake.

The triangle with threads awake (loops back to back) and asleep (2 ms pause
before each loop), speedup over each library's own serial loop:

| Library | Threads | 300 awake | 300 asleep | 3,000 awake | 3,000 asleep |
|---|---|---|---|---|---|
""" + "\n".join(trirow(i, t) for t in (9, 33, 64) for i in ("pforeach", "oneTBB")) + """

1M-element `axpy` at 32 threads, back to back and after the threads have been
idle; the last three columns run with `JULIA_THREAD_SLEEP_THRESHOLD=infinite`,
so that Julia's threads never sleep (`bench/wake/axpy1m.jl`,
`bench/compare/axpy1m_parked.jl`):

| Library | Julia | Back to back | After 2 ms idle | After 50 ms idle | Never sleep: back to back | 2 ms | 50 ms |
|---|---|---|---|---|---|---|---|
""" + "\n".join(gaprow(i, l) for i, l in GAP_ROWS) + """

- **Polyester's lead comes from its workers spinning**: they spin for 2^20
  pauses (tens of ms) after a loop. After 50 ms idle, when they are asleep,
  Polyester is as slow as the others.
- **Back to back, `pforeach` does not pay for wake-ups**: with Julia's threads
  never sleeping it runs the same. The gap to the spinning designs is the cost
  of starting helpers as new tasks through Julia's scheduler every loop.
- **After 50 ms idle everyone is several times slower** than after 2 ms, more
  than one wake explains: cores in deep sleep lose their caches, so the data
  comes back from memory.

### Parked-worker designs

[ParkedWorkers.jl](https://github.com/vchuravy/ParkedWorkers.jl) and the
`Threads.parallel_for` of Julia's
[`vc/parallel-for`](https://github.com/JuliaLang/julia/compare/master...vchuravy:julia:vc/parallel-for)
branch share one design: a persistent sticky worker task per thread that spins
for 100 µs after a loop, then parks in `wait()`, is woken in a binary tree and
runs one contiguous chunk per thread. Both run on Julia nightly
(`bench/compare/`; the branch's file is evaluated into `Base.Threads`). Speedup
at 32 threads, best in bold:

| Workload | `pforeach` | `pforeach` affinity | ParkedWorkers.jl | `parallel_for` (branch) | `@threads` |
|---|---|---|---|---|---|
""" + "\n".join(cmprow(w, n, 32) for w, n in CMP_W) + f"""

- **They win medium loops back to back**, where their workers are still
  spinning: {cx('axpy-1000000-branch-32')} for the branch against {cx('axpy-1000000-pfor_aff-32')} for `pforeach` with affinity on
  1M-element `axpy`. With the threads asleep first (2 ms), `pforeach` with
  affinity matches them: {cx('axpy_cold-1000000-pfor_aff-32')} against {cx('axpy_cold-1000000-branch-32')} for the branch.
- **`pforeach` wins short loops**, which they always split across every
  thread ({cx('axpy-1000-pfor-32')} against {cx('axpy-1000-branch-32')} on 1,000 elements), **and large uneven
  loops**, where one fixed chunk per thread leaves the last thread with most
  of the work ({cx('tri-3000-pfor-32')} against {cx('tri-3000-branch-32')} on the 3,000-element triangle).
- At 63 threads, on this loaded machine, fixed chunks also stall on busy
  cores: on 10M-element `axpy`, {cx('axpy-10000000-pfor_aff-63')} for `pforeach` with affinity against
  {cx('axpy-10000000-branch-63')} for the branch.

### What made it faster

Found by tracing every chunk of every task and by profiling with `perf` and
Julia's JIT profiling support (`ENABLE_JITPROFILING=1`); before and after each
change on the same machine.

| Change | Measured on | Threads | Before | After | Kept |
|---|---|---|---|---|---|
""" + "\n".join(f"| {r['change']} | {r['measure']} | {r['threads']} | {r['before']} {r['unit']} | {r['after']} {r['unit']} | {r['kept']} |" for r in opt) + f"""

### Remaining gaps

- **Helper start-up on medium loops.** Each helper is a new task started
  through Julia's scheduler, and a woken thread runs {short:.2g}–{float(s2000["julia_us"]):.3g} µs of Julia before
  the task does. Passing wakes on in C before the woken thread returns to
  Julia code, a futex per thread instead of a lock and condition variable,
  and a call that wakes several threads at once would all help; so would
  running helpers on parked workers like the designs above.
- **Medium even loops repeated back to back**, where Polyester's and the
  parked designs' workers are still spinning. Helpers that waited for the next
  loop closed part of this, but were left out: loops that follow each other
  with no work in between are rare.

### Scaling tables

From `bench/bench.jl` and `bench/tbb/bench_tbb.cpp`. `-tN,1` gives Julia N
default threads plus the interactive thread the main task runs on; `pforeach`
and oneTBB also run on the calling thread (N + 1 threads), `@threads`,
Polyester and OhMyThreads use N. `axpy_cold` sleeps 2 ms before each loop;
`tri` gives element `i` a cost proportional to `i`; C++ uses glibc's `sin`,
which is slower than Julia's, so compare `tri` by speedup. Bold marks the
fastest parallel version in each row. All 7 thread counts are in
`bench/results/scaling/`.

""" + tables + """
To rerun:

```
julia +1.13 --project=bench -e 'using Pkg; Pkg.instantiate()'
julia +1.13 -t8,1 --project=bench bench/bench.jl > bench/results/scaling/t8.txt
bench/tbb/build.sh            # uses oneTBB_jll, or set TBB_ROOT
bench/tbb/bench_tbb 9 serial tbb tbb_affinity > bench/results/scaling/tbb-t8.txt
julia bench/scaling_csv.jl > bench/results/scaling/scaling.csv   # all thread counts
bench/wake/run.sh             # wake-up measurements; needs perf and strace
python3 bench/readme_perf.py  # this section
```

"""
p = f"{R}/README.md"
s = open(p).read()
a, b = s.index("## Performance"), s.index("## References")
open(p, "w").write(s[:a] + sec + s[b:])
print("README performance section regenerated")

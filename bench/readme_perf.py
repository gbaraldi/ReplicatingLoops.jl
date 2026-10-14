# Regenerate the "## Performance" section of README.md from the result CSVs:
#   bench/results/scaling/{scaling.csv,tables.md}, bench/results/wake/*.csv,
#   bench/results/compare/compare.csv, bench/results/{fewlong,optimizations}.csv
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
attr = {r["key"]: r for r in rd("attribution.csv")}
pcpu = rd("profile/cpu.csv")
pwall = rd("profile/walltime.csv")
pfill = {r["key"]: r for r in rd("profile/fills.csv")}
pc2c = rd("profile/c2c.csv")
same = rd("sameness.csv")
few = {r["key"]: r for r in rd("fewlong.csv")}

x = lambda k: f"{float(scal[k]['speedup']):.3g}×"


def us_(ns):
    ns = float(ns)
    return f"{ns / 1e3:.3g} µs" if ns < 1e6 else f"{ns / 1e6:.3g} ms"


xt = lambda k: f"{x(k)} ({us_(scal[k]['ns'])})"   # speedup and time
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
            ("pforeach", "1.13")]
MODES = ["back to back", "after 2 ms idle", "after 50 ms idle"]


def gaprow(impl, lang):
    cells = [g(impl, lang, m) for m in MODES]
    nev = [g(impl, lang, m, "never") if f"{impl}|{lang}|never|{m}" in gaps else "–" for m in MODES]
    return f"| {impl} | {lang} | " + " | ".join(cells) + " | " + " | ".join(nev) + " |"


FEW_T = sorted({int(r["threads"]) for r in few.values()})
FEW_N = lambda t: sorted({int(r["n"]) for r in few.values() if int(r["threads"]) == t})


def fewrow(t, n, c):
    k = lambda i: few.get(f"{i}-{t}-{n}-{c}")
    cell = lambda r: f"{float(r['us']) / 1000:.2f} ms ({float(r['over_ideal']):.2f}×)" if r else "–"
    return f"| {t} | {n} × {c} µs | {cell(k('pfor'))} | {cell(k('threads'))} | {cell(k('batch'))} |"


PW = ["axpy1m", "tri300", "nested", "small"]
CPU_CATS = ["loop body", "ReplicatingLoops scheduler", "Julia scheduler (Base)", "Julia runtime (C)", "kernel", "clock reads (vdso)"]
CPU_LABEL = {"loop body": "loop body", "ReplicatingLoops scheduler": "`pforeach`'s scheduler",
             "Julia scheduler (Base)": "Julia's task scheduler (mostly idle threads)",
             "Julia runtime (C)": "Julia runtime in C (wake-ups, task switches)", "kernel": "kernel",
             "clock reads (vdso)": "reading the clock"}
WL_LABEL = {"axpy1m": "1M `axpy`", "tri300": "triangle 300", "nested": "nested 64 × 2,000", "small": "64 elements"}
PW_HEAD = [WL_LABEL[w] for w in PW]


def cpu(w, c):
    r = next((r for r in pcpu if r["workload"] == w and r["category"] == c), None)
    return f"{float(r['percent']):.0f}%" if r else "–"


def cpusym(w, sym):
    for r in pcpu:
        if r["workload"] == w:
            m = re.search(re.escape(sym) + r" ([\d.]+)%", r["top_symbols"])
            if m:
                return f"{float(m.group(1)):.0f}%"
    return "–"


cpurow = lambda c: f"| {CPU_LABEL[c]} | " + " | ".join(cpu(w, c) for w in PW) + " |"
WALL_ROWS = [("loop body", "the loop body"), ("spawn_wanted!", "starting helpers (`@spawn`)"),
             ("skip_empty", "finding a block with work (`skip_empty`)"), ("bclaim!", "claiming iterations"),
             ("finish!", "reporting done (`finish!`)"), ("wait_done", "caller waiting for helpers")]


def wall(w, where):
    r = next((r for r in pwall if r["workload"] == w and r["where"] == where), None)
    return f"{float(r['percent']):.0f}%" if r else "–"


wallrow = lambda x: f"| {x[1]} | " + " | ".join(wall(w, x[0]) for w in PW[:3]) + " |"
fills = lambda w, src: f"{int(pfill[f'{w}|{src}']['fills_per_loop']):,}"


def c2cshare(w, prefix):
    v = sum(float(r["hitm_percent"]) for r in pc2c if r["workload"] == w and r["function"].startswith(prefix))
    return f"{v:.0f}%"


def c2cours(w):
    v = sum(float(r["hitm_percent"]) for r in pc2c if r["workload"] == w and r["in_package"] == "True")
    return f"{v:.1f}%"


def sameval(t, n):
    r = next((r for r in same if int(r["threads"]) == t and int(r["n"]) == n), None)
    return f"{100 * float(r['same_thread_median']):.0f}%" if r else "–"


fewus = lambda t, n, c: float(few[f"pfor-{t}-{n}-{c}"]["us"])
fewx = lambda t, n, c: f"{float(few[f'pfor-{t}-{n}-{c}']['over_ideal']):.2f}×"
tbb_tri_us = float(scal["tri-medium-pfor-32"]["serial_ns"]) / 1e3 / float(tri["oneTBB-33-300"]["awake_speedup"])

ATTR = [("tri-300-back_to_back", "300-element triangle, back to back"),
        ("tri-300-after_2_ms_idle", "300-element triangle, after 2 ms idle"),
        ("axpy-1000000-back_to_back", "1M-element `axpy`, back to back"),
        ("axpy-1000000-after_2_ms_idle", "1M-element `axpy`, after 2 ms idle"),
        ("axpy-300000-back_to_back", "300k-element `axpy`, back to back")]


def attrrow(k, label):
    r = attr[k]
    return f"| {label} | " + " | ".join(f"{r[c]} µs" for c in ("normal_us", "never_sleep_us", "running_helpers_us", "all_join_us")) + " |"


attrdiff = lambda k, a, b: f"{float(attr[k][a]) - float(attr[k][b]):.0f} µs"


CMP_W = [("axpy", 1000), ("axpy", 100000), ("axpy", 1000000), ("axpy", 10000000), ("axpy_cold", 1000000),
         ("tri", 30), ("tri", 300), ("tri", 3000)]
CMP_I = ["pfor", "parked", "branch", "threads"]


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

Each Julia library is measured in the same process as its serial loop, so
their speedups share a baseline; oneTBB's are against C++'s own serial loop.
Times are in parentheses.

- **Short loops stay near serial speed.** A 10,000-element `axpy` runs at
  {xt('axpy-small-pfor-63')} of serial speed with 63 threads, where oneTBB gets
  {xt('axpy-small-tbb-63')} and `@threads` {xt('axpy-small-threads-63')}: the caller runs it alone.
- **Large even loops over the same arrays:** {xt('axpy-large-pfor-32')} at 32 threads on 10M-element
  `axpy`, against {xt('axpy-large-batch-32')} for Polyester and {xt('axpy-large-tbb_affinity-32')} for oneTBB's
  affinity partitioner.
- **Large uneven loops:** {xt('tri-large-pfor-63')} against {xt('tri-large-tbb-63')} for oneTBB at 63
  threads on the 3,000-element triangle.
- **Medium loops depend on how fast helpers start.** Back to back,
  Polyester's always-spinning workers reach {xt('axpy-medium-batch-32')} on 1M-element `axpy` at
  32 threads, against {xt('axpy-medium-pfor-32')} for `pforeach` and {xt('axpy-medium-tbb_affinity-32')} for oneTBB
  with affinity. On the 300-element triangle at 32 threads, oneTBB reaches
  {x('tri-medium-tbb-32')} and `pforeach` {x('tri-medium-pfor-32')}.
- **At 63 threads, spinning workers suffer most from other processes** on
  this shared machine: Polyester takes {us_(scal['axpy-small-batch-63']['ns'])} for a 10,000-element `axpy` and
  {us_(scal['axpy-large-batch-63']['ns'])} for 10M elements. That is interference, not a fair comparison.

### Where the time goes: starting helpers

Starting one helper on an idle thread (8 threads, median of 1,500 spawns,
`bench/wake/`, split with `perf record --switch-events`):

| Idle before the spawn | Spawner's `@spawn` | Until the thread gets a core | Julia on the woken thread | Total |
|---|---|---|---|---|
""" + "\n".join(
    f"| {r['condition']} | {r['spawner_us']} µs | {(r['to_cpu_us'] + ' µs') if r['to_cpu_us'] else '–'} | {(r['julia_us'] + ' µs') if r['julia_us'] else '–'} | {r['total_us']} µs |"
    for r in spawn) + f"""

- **The hardware is the largest part.** A bare C `futex` wake takes about
  40 µs to get a thread running from 1 ms idle, most likely because idle
  cores drop into C2 (800 µs nominal exit latency on this machine) and the
  `schedutil` governor lowers their clock; we did not measure those per wake.
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
""" + "\n".join(gaprow(i, l) for i, l in GAP_ROWS) + f"""

- **Polyester's lead comes from its workers spinning**: they spin for 2^20
  pauses (tens of ms) after a loop. After 50 ms idle, when they are asleep,
  it takes {g('Polyester', '1.13', 'after 50 ms idle')}, 8 times its back-to-back time.
- **The parked designs were bimodal** (medians of three runs shown; every
  run is in `bench/results/compare/axpy1m-nightly-runs.csv`): back to back
  they took either about 12 µs or about 220 µs, close to the serial time, as
  if one worker never got to run, and which one they got changed from run to
  run, with threads sleeping or not. One fixed chunk per thread makes a loop
  wait for its slowest thread, and on this shared machine some core was
  usually busy with another user's process. The speedup table below, from a
  separate run, has them fast.
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

| Workload | `pforeach` | ParkedWorkers.jl | `parallel_for` (branch) | `@threads` |
|---|---|---|---|---|
""" + "\n".join(cmprow(w, n, 32) for w, n in CMP_W) + f"""

- **They win medium loops back to back**, where their workers are still
  spinning: {cx('axpy-1000000-branch-32')} for the branch against {cx('axpy-1000000-pfor-32')} for `pforeach` on
  1M-element `axpy`. With the threads asleep first (2 ms), {cx('axpy_cold-1000000-pfor-32')} for
  `pforeach` against {cx('axpy_cold-1000000-branch-32')} for the branch.
- **`pforeach` wins short loops**, which they always split across every
  thread ({cx('axpy-1000-pfor-32')} against {cx('axpy-1000-branch-32')} on 1,000 elements), **and large uneven
  loops**, where one fixed chunk per thread leaves the last thread with most
  of the work ({cx('tri-3000-pfor-32')} against {cx('tri-3000-branch-32')} on the 3,000-element triangle).
- At 63 threads, on this loaded machine, fixed chunks also stall on busy
  cores: on 10M-element `axpy`, {cx('axpy-10000000-pfor-63')} for `pforeach` against
  {cx('axpy-10000000-branch-63')} for the branch.

### Few long iterations

`n` iterations that each spin for a fixed time (`bench/fewlong.jl`). Each
library is compared with its own ideal, `cld(n, tasks)` iterations' time:
`pforeach` runs on the caller too, so it has one more task than `@threads`
and Polyester (9 at 8 threads, 33 at 32), and 9 or 33 iterations fit in one
round for it. Time, and multiple of that library's ideal:

| Threads | n × iteration | `pforeach` | `@threads :dynamic` | Polyester |
|---|---|---|---|---|
""" + "\n".join(fewrow(t, n, c) for t in FEW_T for c in (1000, 100) for n in FEW_N(t)) + f"""

- **Up to as many iterations as threads,** `pforeach` starts one helper right
  away, which brings in the others if the caller's first iteration is still
  running after 20 µs (see How it works); without it, these loops took twice
  the ideal. Bringing in 32 helpers that way takes about
  {fewus(32, 32, 100) - 100:.0f} µs, so 32 iterations of 100 µs take {fewx(32, 32, 100)} the ideal at 32 threads.
  33 iterations at 32 threads fit in one round only if every default thread
  is free besides the caller's; with other processes on this machine one
  often was not, and the loop took two rounds ({fewus(32, 33, 1000) / 1000:.2f} ms for 1 ms iterations).
- **With more iterations than threads,** the first iteration still runs on
  the caller alone, so the loop takes up to one iteration longer than ideal.
  After it, the remaining iterations take 50–90 µs longer than ideal at
  32 threads: the time for helpers to start.

### Where the remaining time goes: Julia or `pforeach`

To tell Julia's costs from the scheduler's own, the same scheduler ran with
Julia's threads never sleeping (no OS wake-up), with helpers handed to tasks
that are already running and spinning (no `@spawn`, no wake-up), and with
those running tasks joining every loop as soon as it is cut into blocks (no
policy for when and how many helpers to start). 32 threads,
`bench/attribution/`:

| Loop | Normal | Threads never sleep | Helpers already running | All join at the split |
|---|---|---|---|---|
""" + "\n".join(attrrow(k, label) for k, label in ATTR) + f"""

- **Julia's part** is the difference between the first and third columns:
  {attrdiff('tri-300-back_to_back', 'normal_us', 'running_helpers_us')} on the 300-element triangle and {attrdiff('axpy-1000000-back_to_back', 'normal_us', 'running_helpers_us')} on 1M-element `axpy`
  back to back, and {attrdiff('axpy-1000000-after_2_ms_idle', 'normal_us', 'running_helpers_us')} on `axpy` after 2 ms idle, where most of it is
  the OS waking threads.
- **The policy's part** is the next step: {attrdiff('tri-300-back_to_back', 'running_helpers_us', 'all_join_us')} and {attrdiff('axpy-1000000-back_to_back', 'running_helpers_us', 'all_join_us')}. The number
  of helpers wanted grows in steps as the timing comes in, helpers are
  handed out one at a time, and each new helper starts others before its own
  first chunk.
- **The rest is the scheduler itself.** Even with every thread already there,
  the triangle takes {attr['tri-300-back_to_back']['all_join_us']} µs, against {tbb_tri_us:.0f} µs for Julia's serial loop at oneTBB's
  speedup with its workers awake ({tri['oneTBB-33-300']['awake_speedup']}×; C++'s `sin` is slower, so its own
  times are not comparable): its first iterations are cheap, so the caller's timing
  predicts too little work and it runs alone for about 10 µs, in a chunk it
  cannot stop to start helpers. On `axpy`, 32 helpers joining at once all
  update one counter.

### What made it faster

Found by tracing every chunk of every task and by profiling with `perf` and
Julia's JIT profiling support (`ENABLE_JITPROFILING=1`); before and after each
change on the same machine.

| Change | Measured on | Threads | Before | After | Kept |
|---|---|---|---|---|---|
""" + "\n".join(f"| {r['change']} | {r['measure']} | {r['threads']} | {r['before']} {r['unit']} | {r['after']} {r['unit']} | {r['kept']} |" for r in opt) + f"""

### Profiles

`bench/profile/run_profiles.sh`, 32 threads, each loop run back to back for
5 s. CPU time by category, from `perf` with Julia's JIT symbols, over all
threads (idle threads included):

| Category | """ + " | ".join(PW_HEAD) + """ |
|---|""" + "---|" * len(PW) + """
""" + "\n".join(cpurow(c) for c in CPU_CATS) + f"""

Wall-clock time of the tasks that ran `pforeach` code (the caller and the
helpers), from Julia's wall-time profiler, by the innermost package function
on the stack:

| Where | """ + " | ".join(PW_HEAD[:3]) + """ |
|---|---|---|---|
""" + "\n".join(wallrow(x) for x in WALL_ROWS) + f"""

- **Idle threads looking for work** are about half of all CPU time: Julia's
  scheduler threads spin in `multiq_deletemin` before they sleep. They also
  cause almost all cache-line contention: in `perf c2c` (AMD IBS),
  {c2cshare('axpy1m', 'multiq')} of the loads that hit a line modified in another core's cache
  were in Julia's multiqueue on 1M-element `axpy` ({c2cshare('tri300', 'multiq')} on the triangle,
  {c2cshare('nested', 'multiq')} on nested loops), and {c2cours('axpy1m')}, {c2cours('tri300')} and {c2cours('nested')} in `pforeach`'s own
  functions. (`perf c2c` could not decode the data source of most IBS samples
  on this machine, so these shares are of the samples it could.)
- **Starting helpers** is where `pforeach`'s tasks spend the most time after
  the loop body: {wall('axpy1m', 'spawn_wanted!')} of their wall-clock time on 1M-element `axpy` is inside
  `@spawn`, and `ijl_wakeup_threadpool`, which looks at every thread's state
  to find one to wake, takes {cpusym('nested', 'ijl_wakeup_threadpool')} of all CPU time with nested loops.
- **The scheduler's own code** takes {cpu('axpy1m', 'ReplicatingLoops scheduler')} of CPU time on 1M-element `axpy` and
  {cpu('tri300', 'ReplicatingLoops scheduler')} on the triangle, mostly in `skip_empty` and `claim_block!`, where
  `perf annotate` puts the time on loading a block's counter: cache misses,
  though `perf c2c` did not catch other cores writing those lines. With
  64-element loops, reading the clock (twice per chunk) is
  {cpu('small', 'clock reads (vdso)')} of CPU time.
- **Data from other cores:** per call of a 1M-element `axpy`, the cores'
  loads missed their L1 and were filled from another core's cache
  {fills('axpy1m', 'near_cache')} times on the same socket and {fills('axpy1m', 'far_cache')} times on the other one, against
  {fills('axpy1m', 'local_l2')} from their own L2 (where the hardware prefetcher also brings
  streaming data). In consecutive calls, {sameval(32, 1000000)} of its iterations ran on the same
  thread as the time before (`bench/sameness.jl`).
- **Julia emits atomic adds as a compare-and-swap loop.** `@atomic x += 1`
  and `Base.unsafe_modify!(p, +, 1)` compile to a load, a call to `+`, and a
  `lock cmpxchg` retried until it succeeds, on every version from 1.10 to
  nightly; from 1.13 `Threads.atomic_add!` does too (up to 1.12 it was one
  `lock xadd`). With 32 threads adding to one counter that is 384 ns per add
  against 250 ns for `lock xadd` (an `llvmcall`). Using `lock xadd` for the
  block counters made no measurable difference here, since they are rarely
  contended.
- Julia's wall-time profiler crashed (segfault) on the nested workload.

### Remaining gaps

- **Julia: starting a task on another thread.** Each helper is a new task;
  the `@spawn` costs its spawner 2–6 µs (most of it looking at every thread
  to find a sleeping one), and a sleeping thread takes 20–70 µs to run it,
  {short:.2g}–{float(s2000["julia_us"]):.3g} µs of which is Julia's own code on the woken thread. Passing wakes on in C
  before the woken thread returns to Julia code, a futex per thread instead
  of a lock and condition variable, and a call that wakes several threads at
  once would all help; so would running helpers on parked workers like the
  designs above.
- **Julia: idle threads.** They spin in the multiqueue looking for work,
  which is half the CPU time and almost all the cache-line contention in
  these runs.
- **`pforeach`: ramping up.** See "Where the remaining time goes": the
  number of helpers grows in steps, and loops whose early iterations are
  cheap (the triangle) run on the caller alone for about 10 µs.
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
julia +1.13 -t32,1 --project=bench bench/fewlong.jl > bench/results/fewlong.csv
python3 bench/readme_perf.py  # this section
```

"""
p = f"{R}/README.md"
s = open(p).read()
a, b = s.index("## Performance"), s.index("## References")
open(p, "w").write(s[:a] + sec + s[b:])
print("README performance section regenerated")

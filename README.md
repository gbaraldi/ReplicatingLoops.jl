# ReplicatingLoops.jl

Parallel `for` loops that start on the calling task right away and only bring
in more threads when the loop turns out to be long enough to need them.

```julia
using ReplicatingLoops

pforeach(eachindex(y)) do i
    y[i] = a * x[i] + y[i]
end

@pfor for i in eachindex(y)
    y[i] = a * x[i] + y[i]
end

@pfor ntasks = 4 for (i, xi) in enumerate(x)
    y[i] = 2xi
end

# Reductions, as with Polyester's `@batch reduction=...`:
total = 0.0
biggest = -Inf
@pfor reduction = ((+, total), (max, biggest)) for v in x
    v < 0 && continue
    total += v
    biggest = max(biggest, v)
end
```

`pforeach(f, xs; ntasks)` calls `f(x)` for every element of `xs` (any
`AbstractArray`; other iterables are `collect`ed). `ntasks` caps how many tasks
work on the loop, the caller included. It defaults to the number of threads in
the default pool, plus one when the caller runs outside it (the main task runs
on the interactive thread by default on Julia 1.12 and later).

`@pfor` runs the loop body inside a real `for` loop over each chunk, so
`continue` works and the loop variable is local to the loop. With
`reduction = (op, v)` (or several as a tuple of pairs) for `op` one of `+`,
`*`, `max`, `min`, `&`, `|` (or a function with one of those names), each chunk
starts `v` from `op`'s neutral element, and afterwards `v` holds `op` of its
value before the loop and every chunk's result.

## How it works

Most parallel loops create one task per chunk up front and then wait for them.
That costs tens of microseconds even when the loop itself takes one, and the
waiting threads have to be woken one by one.

Here the caller starts running iterations immediately and times them:

- **Timing.** The caller starts with one iteration and grows its chunks 4x
  until it has run for 1 µs, then takes the time per iteration from the last
  of those chunks alone. (Timing all of them overestimated it 3–4x: the first
  chunks are mostly the timer and cache misses, and the inflated estimate
  started 32 helpers for a 25 µs loop.) After that, every task re-estimates it
  from each chunk that ran for at least 1 µs, so loops whose cost changes
  along the way are tracked, while a short chunk, whose time is mostly
  overhead, cannot throw the estimate off.
- **Spawning.** Every 5 µs of work, a task raises the number of helpers
  wanted to what the predicted remaining work (time per iteration ×
  iterations left) would keep busy at 10 µs each. A loop predicted to take
  40 µs or more does not wait for the first 5 µs: a helper takes about 20 µs
  to start, so it would still get its share. Shorter loops wait and look
  again with a better estimate; sharing them gains little and scatters their
  data over other cores' caches, which made the next call of a
  100k-element loop twice as slow as running it alone. Each new helper also
  asks for two more while work is left, so the count can double like a tree
  even when early iterations made the work look small. Every task, the caller
  included, starts helpers from a shared counter until as many as wanted have
  been started, then takes its next chunk. When a new helper takes long to get
  running (a sleeping core takes 50–70 µs), the tasks already running start
  many before it arrives; when it is quick, new helpers take over starting the
  rest. This follows the greedy broadcast that Karp et al. (1993) showed to be
  optimal in the LogP model, where a message takes much longer to arrive than
  to send, as a wake-up does here; the fixed fan-out of two used before (as in
  oneTBB) was 1.5x slower after 2 ms idle (`optimizations.csv`). A loop
  stops starting helpers while 8 of them (plus 2 per running helper) have been
  started but are not running yet: on a machine with no idle thread they would
  only find the loop done, and starting them without that limit cut throughput
  3× in a stress test with twice as many loops as threads.
- **Blocks.** Just before it starts the first helper, the caller cuts the
  loop into equal blocks, counting the iterations it already ran as handed
  out. Block 1 belongs to the caller's thread, the others to default-pool
  threads in order. Every task works through the block of the thread it runs
  on first, then helps with the others, in chunks of the same size. A loop
  that runs repeatedly over the same arrays tends to get the same blocks on
  the same threads every call, so each piece is still in that core's cache.
  Blocks live in one array, each counter on its own cache line, so claiming
  iterations never touches a counter shared by all tasks.
- **How many blocks.** One per 10 µs of predicted work, rounded up to a power
  of two, and one per thread once that is more than half the threads. Cutting
  exactly by predicted work moved the block boundaries from call to call as
  the timing varied, and a 1M-element loop then spent 4x the CPU time in its
  chunks (1.2 ms instead of 0.3 ms, from per-chunk traces), most likely in
  cache misses; always cutting one block per thread made small loops walk
  through many tiny blocks (nested loops ran 1.7x slower).
- **Chunks.** Sized to about 20 µs of work and at most twice the previous
  chunk. Once helpers are running, a chunk is also at most half of an even
  share of what is left, so chunks shrink near the end and the last ones
  finish close together.
- **Few long iterations.** The caller learns nothing until its first
  iteration ends, so a loop of as many 1 ms iterations as threads would take
  2 ms. A loop with no more elements than threads therefore also starts one
  helper right away, which waits up to 20 µs for the caller's first iteration
  to end; if it has not, it starts the others, like a tree, and takes
  iterations too. Starting that helper costs the caller a `@spawn`, which
  would make short loops of a few cheap elements about 15x slower (0.5 to
  7–11 µs), so each loop body type remembers, in a 256-entry table, whether
  its first iteration took 20 µs or more the last time, and only a new body
  or one that was slow last time gets the helper.
- **Yielding.** Julia's tasks only switch when one yields, so a long loop
  would keep every other task in the default pool waiting until it ends.
  After each millisecond of work, a task yields if another task is waiting for
  a thread of its pool (checked through Julia's scheduler internals, about
  50 ns). While a 26 ms loop kept every thread busy, a task in the default pool
  waited 0.4 ms to start instead of 23 ms. Yielding unconditionally would cost
  8–10% on loops of 1 ms iterations, since resuming can mean waking a thread.
- **Waiting.** When nothing is left to take, the caller spins for up to 20 µs
  for the other tasks to finish their last chunks, then blocks. Helpers never
  wait: a helper that finds no work left just returns. The caller never waits
  for a helper that has not started yet.
- **Errors.** If `f` throws, no more iterations are handed out, and once the
  running chunks finish the caller throws a `CompositeException` holding the
  first error. If the caller is interrupted while it waits (for example ^C),
  it also stops handing out iterations and waits for the running chunks before
  rethrowing, with ^C deferred meanwhile, so no iteration runs after `pforeach`
  returns.
- **Compilation.** The scheduling code does not depend on the loop body's type:
  it calls the body once per chunk through a dynamic call, and it is compiled
  into the package image. A new loop body only compiles its own inner loop and
  the small `pforeach` entry (10–17 ms for a small closure), not the scheduler
  (which took about 120 ms per body before). The entry is specialized so that
  a short loop does not look up the body's type at run time (540 to 250 ns for
  64 elements).
- **No pinning.** Helpers are ordinary tasks; each takes the block of the
  thread it lands on, or, if that thread has no block, the one matching the
  order it was started in. In consecutive calls (`bench/sameness.jl`,
  `bench/results/sameness.csv`), 99% of the iterations of a loop of 10,000
  half-microsecond iterations ran on the same thread as the time before,
  84–85% for 100,000 cheap iterations and 56–70% for 1M, where the
  caller stops alone and how much is stolen vary from call to call. An
  earlier test found pinning helpers to their block's thread no better.
  Pinning Julia's threads to cores
  (`JULIA_EXCLUSIVE=1`) made loops slower on this shared machine, because a
  thread pinned to a busy core cannot move away.

An earlier version also had a mode without blocks, where every task took
chunks from one shared counter. In an A/B of the two on that version
(`bench/results/modes.csv`, `bench/modes/`), blocks were 1.4–1.8x faster on
loops streaming 800 MB from memory, 1.5–1.7x on 300k–1M elements at 32 and
63 threads, and 1.1–1.4x on nested loops, and 7–12% slower on mid-size
uneven loops and on 100k elements at 32 threads, so the shared-counter mode
was removed.

## Trade-offs

- **Ramp-up.** Each helper costs its spawner a `@spawn` of 2–6 µs, most of it
  waking a sleeping thread, and the woken thread takes another 20–70 µs to
  run it. Libraries whose workers keep spinning between loops, such as
  Polyester and oneTBB, bring in all threads faster when loops run back to
  back. After the first iteration of a few-long-iterations loop, the rest
  takes 50–90 µs longer than ideal for the same reason.
- **Uneven blocks.** Equal blocks hold unequal work when iterations get more
  expensive along the loop; tasks that finish early help with the others, but
  a helper's first chunk is sized from the caller's timing of the cheap early
  iterations, which can make it long.
- **Mixed loop bodies.** The few-long-iterations helper follows each body
  type's last call, so a body whose cost varies a lot from call to call
  sometimes starts it needlessly or misses it.
- **Helpers that start too late.** When no thread is free, a loop's helpers
  may still be queued when the loop returns; they start later, find nothing
  to do and exit, holding the loop's memory until then. A global limit on
  queued helpers prevented that, but made loops run back to back 20–60%
  slower (the late helpers of one loop count against the next), so there is
  none.
- **The caller does work.** Iterations also run on the calling task, which is
  the interactive thread when called from the REPL or a script's main task.
- **First call.** A new loop body is compiled on its first chunk, on the
  caller. Short first calls may finish before any helper joins.
- Reductions only through `@pfor`; `pforeach` itself has none.
- **Loops back to back.** Helpers are started anew for every loop and exit
  when it ends, so a series of parallel loops with little serial work between
  them pays the start-up each time; see the Trixi.jl results below.

## Performance

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
  0.651× (2.38 µs) of serial speed with 63 threads, where oneTBB gets
  0.0512× (32.1 µs) and `@threads` 0.00318× (486 µs): the caller runs it alone.
- **Large even loops over the same arrays:** 35.5× (116 µs) at 32 threads on 10M-element
  `axpy`, against 33.4× (123 µs) for Polyester and 14.3× (258 µs) for oneTBB's
  affinity partitioner.
- **Large uneven loops:** 60.1× (621 µs) against 55.3× (1.1 ms) for oneTBB at 63
  threads on the 3,000-element triangle.
- **Medium loops depend on how fast helpers start.** Back to back,
  Polyester's always-spinning workers reach 12× (17.2 µs) on 1M-element `axpy` at
  32 threads, against 3.91× (53 µs) for `pforeach` and 4.29× (51.8 µs) for oneTBB
  with affinity. On the 300-element triangle at 32 threads, oneTBB reaches
  11.9× and `pforeach` 4.73×.
- **At 63 threads, spinning workers suffer most from other processes** on
  this shared machine: Polyester takes 3 ms for a 10,000-element `axpy` and
  3.91 ms for 10M elements. That is interference, not a fair comparison.

### Where the time goes: starting helpers

Starting one helper on an idle thread (8 threads, median of 1,500 spawns,
`bench/wake/`, split with `perf record --switch-events`):

| Idle before the spawn | Spawner's `@spawn` | Until the thread gets a core | Julia on the woken thread | Total |
|---|---|---|---|---|
| threads spinning | 2.2 µs | – | – | 3.7 µs |
| asleep 150 us (run 1) | 4.3 µs | 49.1 µs | 15.0 µs | 64.2 µs |
| asleep 150 us (run 2) | 4.0 µs | 48.6 µs | 15.0 µs | 63.9 µs |
| asleep 150 us (run 3) | 4.3 µs | 48.9 µs | 14.7 µs | 64.2 µs |
| asleep 500 us | 4.0 µs | 50.7 µs | 16.3 µs | 67.1 µs |
| asleep 2000 us | 4.3 µs | 53.3 µs | 17.9 µs | 71.9 µs |

- **The hardware is the largest part.** A bare C `futex` wake takes about
  40 µs to get a thread running from 1 ms idle, most likely because idle
  cores drop into C2 (800 µs nominal exit latency on this machine) and the
  `schedutil` governor lowers their clock; we did not measure those per wake.
- **Julia's own path on the woken thread** takes 14.7 µs after a short sleep
  and 17.9 µs after a long one: the same code, run with cold caches at a low
  clock. With threads spinning, a whole spawn takes 3.7 µs.
- **oneTBB wakes threads the same way**, one futex wake per thread and never a
  broadcast, in a binary tree where a woken worker wakes two more as soon as
  it runs (8 wake calls per cold loop with 9 threads). `pforeach` starts helpers
  cooperatively from a shared counter instead (see How it works), and each
  woken Julia thread makes one extra wake call on its lock (15 per cold loop).
  After running out of work, oneTBB's workers also spin for up to 1 ms, so
  back-to-back loops find them awake.

The triangle with threads awake (loops back to back) and asleep (2 ms pause
before each loop), speedup over each library's own serial loop:

| Library | Threads | 300 awake | 300 asleep | 3,000 awake | 3,000 asleep |
|---|---|---|---|---|---|
| pforeach | 9 | 5.19× | 3.73× | 10.8× | 10.7× |
| oneTBB | 9 | 6.64× | 5.21× | 8.95× | 8.91× |
| pforeach | 33 | 5.64× | 3.88× | 39.9× | 38.9× |
| oneTBB | 33 | 13.8× | 6.31× | 32.2× | 31.4× |
| pforeach | 64 | 4.26× | 3.29× | 66.2× | 64.9× |
| oneTBB | 64 | 15.6× | 5.4× | 56.1× | 53× |

1M-element `axpy` at 32 threads, back to back and after the threads have been
idle; the last three columns run with `JULIA_THREAD_SLEEP_THRESHOLD=infinite`,
so that Julia's threads never sleep (`bench/wake/axpy1m.jl`,
`bench/compare/axpy1m_parked.jl`):

| Library | Julia | Back to back | After 2 ms idle | After 50 ms idle | Never sleep: back to back | 2 ms | 50 ms |
|---|---|---|---|---|---|---|---|
| Polyester | 1.13 | 18.2 µs | 18 µs | 147 µs | 18.2 µs | 18.7 µs | 61.8 µs |
| oneTBB affinity | C++ | 54 µs | 102 µs | 237 µs | – | – | – |
| oneTBB | C++ | 88.9 µs | 114 µs | 217 µs | – | – | – |
| ParkedWorkers | nightly | 220 µs | 220 µs | 314 µs | 220 µs | 220 µs | 331 µs |
| parallel_for (vc branch) | nightly | 12.2 µs | 70.5 µs | 239 µs | 221 µs | 221 µs | 298 µs |
| pforeach | 1.13 | 53.9 µs | 71.6 µs | 211 µs | 53 µs | 50 µs | 96.7 µs |

- **Polyester's lead comes from its workers spinning**: they spin for 2^20
  pauses (tens of ms) after a loop. After 50 ms idle, when they are asleep,
  it takes 147 µs, 8 times its back-to-back time.
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
| axpy 1,000 | **0.158×** | 0.00697× | 0.018× | 0.000529× |
| axpy 100,000 | 0.817× | 1.46× | **2.83×** | 0.124× |
| axpy 1,000,000 | 3.62× | 12× | **16×** | 1.22× |
| axpy 10,000,000 | 31.5× | **50×** | **50×** | 3.85× |
| axpy_cold 1,000,000 | **2.83×** | 2.35× | 2.7× | 1.73× |
| tri 30 | **0.857×** | 0.191× | 0.45× | 0.0166× |
| tri 300 | 4.59× | 13.6× | **14.5×** | 1.74× |
| tri 3,000 | **30.7×** | 16.1× | 16.3× | 10.8× |

- **They win medium loops back to back**, where their workers are still
  spinning: 16× for the branch against 3.62× for `pforeach` on
  1M-element `axpy`. With the threads asleep first (2 ms), 2.83× for
  `pforeach` against 2.7× for the branch.
- **`pforeach` wins short loops**, which they always split across every
  thread (0.158× against 0.018× on 1,000 elements), **and large uneven
  loops**, where one fixed chunk per thread leaves the last thread with most
  of the work (30.7× against 16.3× on the 3,000-element triangle).
- At 63 threads, on this loaded machine, fixed chunks also stall on busy
  cores: on 10M-element `axpy`, 24.8× for `pforeach` against
  8.08× for the branch.

### Few long iterations

`n` iterations that each spin for a fixed time (`bench/fewlong.jl`). Each
library is compared with its own ideal, `cld(n, tasks)` iterations' time:
`pforeach` runs on the caller too, so it has one more task than `@threads`
and Polyester (9 at 8 threads, 33 at 32), and 9 or 33 iterations fit in one
round for it. Time, and multiple of that library's ideal:

| Threads | n × iteration | `pforeach` | `@threads :dynamic` | Polyester |
|---|---|---|---|---|
| 8 | 2 × 1000 µs | 1.02 ms (1.02×) | 1.02 ms (1.02×) | 1.00 ms (1.00×) |
| 8 | 4 × 1000 µs | 1.04 ms (1.04×) | 1.01 ms (1.02×) | 1.00 ms (1.00×) |
| 8 | 8 × 1000 µs | 1.04 ms (1.04×) | 1.02 ms (1.02×) | 1.00 ms (1.00×) |
| 8 | 9 × 1000 µs | 1.04 ms (1.04×) | 2.02 ms (1.01×) | 2.00 ms (1.00×) |
| 8 | 16 × 1000 µs | 3.03 ms (1.51×) | 2.02 ms (1.01×) | 2.00 ms (1.00×) |
| 8 | 32 × 1000 µs | 5.03 ms (1.26×) | 4.02 ms (1.01×) | 4.00 ms (1.00×) |
| 8 | 2 × 100 µs | 0.12 ms (1.21×) | 0.11 ms (1.06×) | 0.10 ms (1.01×) |
| 8 | 4 × 100 µs | 0.14 ms (1.35×) | 0.11 ms (1.09×) | 0.10 ms (1.01×) |
| 8 | 8 × 100 µs | 0.14 ms (1.40×) | 0.11 ms (1.14×) | 0.10 ms (1.01×) |
| 8 | 9 × 100 µs | 0.14 ms (1.40×) | 0.21 ms (1.06×) | 0.20 ms (1.00×) |
| 8 | 16 × 100 µs | 0.32 ms (1.62×) | 0.21 ms (1.07×) | 0.20 ms (1.01×) |
| 8 | 32 × 100 µs | 0.52 ms (1.30×) | 0.41 ms (1.04×) | 0.40 ms (1.00×) |
| 32 | 2 × 1000 µs | 1.02 ms (1.02×) | 1.02 ms (1.02×) | 1.00 ms (1.00×) |
| 32 | 4 × 1000 µs | 1.03 ms (1.03×) | 1.02 ms (1.02×) | 1.00 ms (1.00×) |
| 32 | 8 × 1000 µs | 1.04 ms (1.04×) | 1.03 ms (1.03×) | 1.00 ms (1.00×) |
| 32 | 16 × 1000 µs | 1.06 ms (1.06×) | 1.09 ms (1.09×) | 1.01 ms (1.01×) |
| 32 | 32 × 1000 µs | 1.08 ms (1.08×) | 1.14 ms (1.14×) | 1.01 ms (1.01×) |
| 32 | 33 × 1000 µs | 2.01 ms (2.01×) | 2.02 ms (1.01×) | 2.00 ms (1.00×) |
| 32 | 64 × 1000 µs | 3.08 ms (1.54×) | 2.15 ms (1.07×) | 2.01 ms (1.01×) |
| 32 | 128 × 1000 µs | 5.08 ms (1.27×) | 4.15 ms (1.04×) | 4.01 ms (1.00×) |
| 32 | 2 × 100 µs | 0.12 ms (1.22×) | 0.19 ms (1.94×) | 0.10 ms (1.01×) |
| 32 | 4 × 100 µs | 0.13 ms (1.32×) | 0.18 ms (1.84×) | 0.10 ms (1.02×) |
| 32 | 8 × 100 µs | 0.15 ms (1.47×) | 0.18 ms (1.84×) | 0.10 ms (1.02×) |
| 32 | 16 × 100 µs | 0.15 ms (1.52×) | 0.18 ms (1.85×) | 0.11 ms (1.07×) |
| 32 | 32 × 100 µs | 0.21 ms (2.07×) | 0.23 ms (2.33×) | 0.11 ms (1.13×) |
| 32 | 33 × 100 µs | 0.25 ms (2.47×) | 0.23 ms (1.18×) | 0.20 ms (1.01×) |
| 32 | 64 × 100 µs | 0.44 ms (2.18×) | 0.31 ms (1.55×) | 0.21 ms (1.06×) |
| 32 | 128 × 100 µs | 0.55 ms (1.38×) | 0.53 ms (1.32×) | 0.41 ms (1.03×) |

- **Up to as many iterations as threads,** `pforeach` starts one helper right
  away, which brings in the others if the caller's first iteration is still
  running after 20 µs (see How it works); without it, these loops took twice
  the ideal. Bringing in 32 helpers that way takes about
  107 µs, so 32 iterations of 100 µs take 2.07× the ideal at 32 threads.
  33 iterations at 32 threads fit in one round only if every default thread
  is free besides the caller's; with other processes on this machine one
  often was not, and the loop took two rounds (2.01 ms for 1 ms iterations).
- **With more iterations than threads,** the first iteration still runs on
  the caller alone, so the loop takes up to one iteration longer than ideal.
  After it, the remaining iterations take 50–90 µs longer than ideal at
  32 threads: the time for helpers to start.

### Polyester's users: Trixi.jl

73 packages in the General registry depend on Polyester directly
(`bench/trixi/polyester_dependents.jl`), among them OrdinaryDiffEqCore,
FastBroadcast, RecursiveFactorization, LuxLib, Trixi.jl and TrixiParticles.jl.
Of the 18 whose source has `@batch` loops (`bench/results/polyester_users.csv`),
Trixi.jl has by far the most: 408, almost all through its `@threaded` macro,
50 of them reductions. To compare on real code, `bench/trixi/` runs the
same Trixi commit twice: as it is, and with its `@batch` (and so `@threaded`)
turned into `@pfor` by a six-line patch, with no change to its loops. Time of
one right-hand-side evaluation, which runs all of a time step's parallel loops
except the integrator's (best of 200, best of two runs; the time integrator
is not threaded in either):

| Elixir | Elements | Serial | Polyester, 8 threads | `pforeach`, 8 | Polyester, 32 | `pforeach`, 32 |
|---|---|---|---|---|---|---|
| 2D Euler, source terms | 1,024 | 692 µs | 124 µs | 214 µs | 85 µs | 365 µs |
| 2D Euler, source terms | 4,096 | 2,772 µs | 394 µs | 469 µs | 153 µs | 428 µs |
| 2D Euler, source terms | 16,384 | 11,523 µs | 1,467 µs | 1,486 µs | 426 µs | 767 µs |
| 3D Taylor-Green vortex | 512 | 3,467 µs | 678 µs | 740 µs | 258 µs | 472 µs |
| 3D Taylor-Green vortex | 4,096 | 29,802 µs | 4,130 µs | 3,875 µs | 1,309 µs | 1,518 µs |
| 2D Sedov blast, subcell limiter | 1,024 | 2,674 µs | 428 µs | 541 µs | 167 µs | 353 µs |

- **Polyester is faster on Trixi**, by up to 4.3x at 32 threads on small meshes;
  `pforeach` is ahead only on the largest 3D case at 8 threads. Each
  right-hand side runs only 6–7 parallel loops over 512–32,768 elements
  (`bench/trixi/count_loops.jl`), back to back with little
  serial work between them: Polyester's workers are still spinning from the
  previous loop, while `pforeach` starts its helpers again for every loop.
  The difference per loop is about 13 µs at 8 threads and 40 µs at
  32: the start-up measured in "Where the remaining time goes" below.
- **For this kind of code, loops back to back are the real case.** Closing
  the gap needs helpers that outlive a loop, as Polyester's and the
  parked-worker designs' do.
- `@pfor` handles all of Trixi's loops, including the 50 reductions and the
  ones that use `continue`, unchanged. On one thread the patched Trixi is
  5% slower or less.

### Where the remaining time goes: Julia or `pforeach`

To tell Julia's costs from the scheduler's own, the same scheduler ran with
Julia's threads never sleeping (no OS wake-up), with helpers handed to tasks
that are already running and spinning (no `@spawn`, no wake-up), and with
those running tasks joining every loop as soon as it is cut into blocks (no
policy for when and how many helpers to start). 32 threads,
`bench/attribution/`:

| Loop | Normal | Threads never sleep | Helpers already running | All join at the split |
|---|---|---|---|---|
| 300-element triangle, back to back | 60.1 µs | 60.5 µs | 48.2 µs | 36.9 µs |
| 300-element triangle, after 2 ms idle | 69.8 µs | 51.1 µs | 41.3 µs | 28.2 µs |
| 1M-element `axpy`, back to back | 52.9 µs | 51.3 µs | 39.8 µs | 28.9 µs |
| 1M-element `axpy`, after 2 ms idle | 76.4 µs | 50.5 µs | 40.1 µs | 27.6 µs |
| 300k-element `axpy`, back to back | 62.3 µs | 61.2 µs | 43.5 µs | 26.4 µs |

- **Julia's part** is the difference between the first and third columns:
  12 µs on the 300-element triangle and 13 µs on 1M-element `axpy`
  back to back, and 36 µs on `axpy` after 2 ms idle, where most of it is
  the OS waking threads.
- **The policy's part** is the next step: 11 µs and 11 µs. The number
  of helpers wanted grows in steps as the timing comes in, helpers are
  handed out one at a time, and each new helper starts others before its own
  first chunk.
- **The rest is the scheduler itself.** Even with every thread already there,
  the triangle takes 36.9 µs, against 21 µs for Julia's serial loop at oneTBB's
  speedup with its workers awake (13.8×; C++'s `sin` is slower, so its own
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
| Scheduler code no longer specialized on the loop body, and precompiled | first call of a new loop body (helpers must compile) | 8 | 128.7 ms | 18.6 ms | yes |
| No shared counter updated on every chunk claim (blocks) | 1M-element axpy, blocks, back to back | 32 | 177.5 µs | 91 µs | yes |
| Steals take at least 1 µs; timing only from chunks of at least 1 µs; skip empty blocks | 1M-element axpy, blocks, back to back | 32 | 109.5 µs | 89.5 µs | yes |
| Blocks in one flat array instead of one object per block | 1M-element axpy, blocks, back to back (warm helpers on) | 32 | 67 µs | 47 µs | yes |
| New helpers ask for two more whenever 10 µs of work is left | 300-element triangle, shared-counter mode (since removed) | 32 | 65.5 µs | 55.5 µs | yes |
| Helpers wait 50 µs for the next loop (warm helpers) | 1M-element axpy, blocks, back to back | 32 | 68.5 µs | 42 µs | no: back-to-back loops are not a realistic case |
| Helpers started greedily from a shared counter by every task (cooperative wake-up) | 1M-element axpy, blocks, after 2 ms idle (1.13) | 32 | 100.3 µs | 68.8 µs | yes |
| At most 8 helpers (plus 2 per running one) started but not yet running | stress test: loops finished in 30 s, 2 loops per thread at once (nightly) | 63 | 51142 loops | 137899 loops | yes |
| First time per iteration from the last warm-up chunk alone, not all of them | first estimate on 1M-element axpy (true cost 0.2 ns per iteration) | 32 | 0.84 ns | 0.30 ns | yes |
| Blocks: one per 10 µs of predicted work rounded up to a power of two, one per thread past half (was: exactly one per 10 µs) | 1M-element axpy, back to back | 32 | 89.5 µs | 64.7 µs | yes |
| Always one block per thread | nested loops, 64 × 2,000 elements | 32 | 275.1 µs | 474.6 µs | no: small loops walk through many tiny blocks |
| Cut blocks and start helpers as soon as there is an estimate (no 5 µs wait) | 100k-element axpy, back to back | 32 | 25.5 µs | 48.3 µs | no: replaced by the 40 µs rule below |
| Start helpers without waiting 5 µs when the predicted work is 40 µs or more | 1M-element axpy, back to back | 32 | 64.7 µs | 57.0 µs | yes |
| Helpers time a short first chunk; steals sized by the time per iteration last measured in that block | 1,000-element triangle | 32 | 157 µs | 153.5 µs | no: 300k-element axpy went from 65 to 78–82 µs |
| Work left estimated from a shared count of emptied blocks | 300k-element axpy, back to back | 32 | 68.7 µs | 99.2 µs | no |
| Loops with no more elements than threads start a helper that brings in the others if the first iteration runs 20 µs | 32 iterations of 1 ms | 32 | 2080 µs | 1047 µs | yes |
| That helper for every such loop | stress test: loops finished in 20 s, 2 loops per thread at once | 63 | 38837 loops | 7420 loops | no: short loops of a few elements went from 0.5 to 7–11 µs |
| That helper only for loop bodies whose first iteration took 20 µs or more last time, or that never ran | stress test: loops finished in 20 s, 2 loops per thread at once | 63 | 7420 loops | 34060 loops | yes |
| One heartbeat task per process watching such loops instead of a helper per loop | stress test: loops finished in 20 s, 2 loops per thread at once | 63 | 34060 loops | 8599 loops | no: short loops 0.5 to 1.3–2.9 µs, and help arrives one wake-up later |
| Steal as many iterations as from one's own block, not about half of what is left there | 1M-element axpy, back to back | 32 | 52.8 µs | 52.1 µs | yes: no measurable difference at 8 or 32 threads, and simpler |
| Remove the rule that each new helper asks for two more | 1,000-element triangle | 32 | 149.3 µs | 335.7 µs | no |
| Remove the per-chunk cap at half an even share of what is left | 1,000-element triangle | 32 | 149.3 µs | 575.8 µs | no |
| Block at once instead of spinning 20 µs for the last chunks | 1,000-element triangle | 32 | 149.3 µs | 182.2 µs | no: also 5–11% slower on 300k–10M-element axpy |
| Remove the 2x limit on chunk growth | 300-element triangle | 32 | 61.6 µs | 288.4 µs | no: concurrent small loops gain (167 to 237 per ms) only because they stop starting helpers |
| A global limit on queued helpers, one per thread | 300k-element axpy, back to back | 32 | 61.1 µs | 79.3 µs | no: concurrent loops 160 to 234 per ms, but single loops 20–60% slower |
| Before the first helper, chunks of at most 2.5 µs of predicted work | 300-element triangle | 32 | 61.1 µs | 61.3 µs | no |
| pforeach entry specialized on the loop body (the scheduler still is not) | 64-element loop of cheap iterations | 32 | 540 ns | 253 ns | yes: and a new body compiles in 14 instead of 17 ms |
| Block claims with one lock xadd instead of the compare-and-swap loop Julia emits for atomic + | 1M-element axpy, back to back | 32 | 53.6 µs | 53.9 µs | no: no measurable difference; the claims are rarely contended |
| After each 1 ms of work, yield if another task is waiting for a thread | time a default-pool task waits to start while a 26 ms loop uses every thread | 32 | 22606 µs | 425 µs | yes |
| After each 1 ms of work, always yield | 32 iterations of 1 ms | 32 | 1069 µs | 1400 µs | no: resuming can wake another thread |

### Profiles

`bench/profile/run_profiles.sh`, 32 threads, each loop run back to back for
5 s. CPU time by category, from `perf` with Julia's JIT symbols, over all
threads (idle threads included):

| Category | 1M `axpy` | triangle 300 | nested 64 × 2,000 | 64 elements |
|---|---|---|---|---|
| loop body | 21% | 20% | 23% | 3% |
| `pforeach`'s scheduler | 12% | 14% | 13% | 8% |
| Julia's task scheduler (mostly idle threads) | 47% | 50% | 28% | 45% |
| Julia runtime in C (wake-ups, task switches) | 13% | 11% | 25% | 16% |
| kernel | 1% | 1% | 2% | 8% |
| reading the clock | 3% | 3% | 6% | 15% |

Wall-clock time of the tasks that ran `pforeach` code (the caller and the
helpers), from Julia's wall-time profiler, by the innermost package function
on the stack:

| Where | 1M `axpy` | triangle 300 | nested 64 × 2,000 |
|---|---|---|---|
| the loop body | 35% | 28% | – |
| starting helpers (`@spawn`) | 20% | 20% | – |
| finding a block with work (`skip_empty`) | 13% | 16% | – |
| claiming iterations | 7% | 15% | – |
| reporting done (`finish!`) | 8% | 6% | – |
| caller waiting for helpers | 1% | 1% | – |

- **Idle threads looking for work** are about half of all CPU time: Julia's
  scheduler threads spin in `multiq_deletemin` before they sleep. They also
  cause almost all cache-line contention: in `perf c2c` (AMD IBS),
  99% of the loads that hit a line modified in another core's cache
  were in Julia's multiqueue on 1M-element `axpy` (99% on the triangle,
  86% on nested loops), and 0.0%, 0.0% and 0.6% in `pforeach`'s own
  functions. (`perf c2c` could not decode the data source of most IBS samples
  on this machine, so these shares are of the samples it could.)
- **Starting helpers** is where `pforeach`'s tasks spend the most time after
  the loop body: 20% of their wall-clock time on 1M-element `axpy` is inside
  `@spawn`, and `ijl_wakeup_threadpool`, which looks at every thread's state
  to find one to wake, takes 14% of all CPU time with nested loops.
- **The scheduler's own code** takes 12% of CPU time on 1M-element `axpy` and
  14% on the triangle, mostly in `skip_empty` and `claim_block!`, where
  `perf annotate` puts the time on loading a block's counter: cache misses,
  though `perf c2c` did not catch other cores writing those lines. With
  64-element loops, reading the clock (twice per chunk) is
  15% of CPU time.
- **Data from other cores:** per call of a 1M-element `axpy`, the cores'
  loads missed their L1 and were filled from another core's cache
  7,862 times on the same socket and 5,187 times on the other one, against
  236,053 from their own L2 (where the hardware prefetcher also brings
  streaming data). In consecutive calls, 56% of its iterations ran on the same
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
  15–17.9 µs of which is Julia's own code on the woken thread. Passing wakes on in C
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

### nthreads default=8 interactive=1 caller pool=interactive julia=1.13.0; oneTBB 2023.1 threads=9

| workload | n | serial | `@threads` | Polyester | OhMyThreads | C++ serial | oneTBB | oneTBB affinity | `pforeach` |
|---|---|---|---|---|---|---|---|---|---|
| axpy | 1000 | 92 ns | 25.2 µs | 2.7 µs | 24.6 µs | 130 ns | 19.3 µs | 26.2 µs | **463 ns** |
| axpy | 10000 | 1.55 µs | 26.4 µs | 2.79 µs | 27.2 µs | 1.64 µs | 35.6 µs | 37.0 µs | **2.37 µs** |
| axpy | 100000 | 19.0 µs | 29.5 µs | **6.15 µs** | 32.9 µs | 22.2 µs | 44.9 µs | 39.8 µs | 22.5 µs |
| axpy | 1000000 | 207.0 µs | 87.6 µs | 48.8 µs | 89.8 µs | 222.0 µs | 107.0 µs | 76.9 µs | **44.5 µs** |
| axpy | 10000000 | 3.56 ms | 1.22 ms | 462.0 µs | 997.0 µs | 3.7 ms | 1.42 ms | 419.0 µs | **314.0 µs** |
| axpy_cold | 10000 | 1.71 µs | 28.7 µs | 2.96 µs | 22.9 µs | 1.75 µs | 49.6 µs | 57.1 µs | **2.57 µs** |
| axpy_cold | 1000000 | 213.0 µs | 108.0 µs | **50.2 µs** | 128.0 µs | 206.0 µs | 122.0 µs | 106.0 µs | 66.4 µs |
| tri | 30 | 2.5 µs | 21.8 µs | 3.02 µs | 23.4 µs | 3.96 µs | 9.09 µs | 11.0 µs | **2.86 µs** |
| tri | 300 | 287.0 µs | 87.7 µs | 69.3 µs | 90.5 µs | 462.0 µs | 75.7 µs | 75.0 µs | **60.3 µs** |
| tri | 3000 | 37.2 ms | 9.68 ms | 9.57 ms | 7.18 ms | 61.1 ms | 6.84 ms | 6.86 ms | **4.18 ms** |

### nthreads default=32 interactive=1 caller pool=interactive julia=1.13.0; oneTBB 2023.1 threads=33

| workload | n | serial | `@threads` | Polyester | OhMyThreads | C++ serial | oneTBB | oneTBB affinity | `pforeach` |
|---|---|---|---|---|---|---|---|---|---|
| axpy | 1000 | 92 ns | 164.0 µs | 7.14 µs | 141.0 µs | 130 ns | 20.5 µs | 24.8 µs | **468 ns** |
| axpy | 10000 | 1.55 µs | 180.0 µs | 6.72 µs | 157.0 µs | 1.65 µs | 32.3 µs | 30.3 µs | **2.35 µs** |
| axpy | 100000 | 19.1 µs | 181.0 µs | **8.26 µs** | 156.0 µs | 22.3 µs | 39.3 µs | 35.8 µs | 22.7 µs |
| axpy | 1000000 | 207.0 µs | 170.0 µs | **17.2 µs** | 168.0 µs | 222.0 µs | 86.0 µs | 51.8 µs | 53.0 µs |
| axpy | 10000000 | 4.11 ms | 994.0 µs | 123.0 µs | 994.0 µs | 3.68 ms | 1.39 ms | 258.0 µs | **116.0 µs** |
| axpy_cold | 10000 | 1.68 µs | 102.0 µs | 5.72 µs | 94.5 µs | 1.81 µs | 55.4 µs | 68.8 µs | **2.62 µs** |
| axpy_cold | 1000000 | 214.0 µs | 114.0 µs | **18.5 µs** | 147.0 µs | 204.0 µs | 111.0 µs | 92.5 µs | 74.3 µs |
| tri | 30 | 2.5 µs | 156.0 µs | 6.0 µs | 187.0 µs | 3.96 µs | 11.9 µs | 18.6 µs | **2.83 µs** |
| tri | 300 | 287.0 µs | 170.0 µs | **23.6 µs** | 187.0 µs | 462.0 µs | 38.9 µs | 38.9 µs | 60.8 µs |
| tri | 3000 | 37.5 ms | 3.76 ms | 2.43 ms | 2.11 ms | 61.0 ms | 1.91 ms | 1.91 ms | **1.26 ms** |

### nthreads default=63 interactive=1 caller pool=interactive julia=1.13.0; oneTBB 2023.1 threads=64

| workload | n | serial | `@threads` | Polyester | OhMyThreads | C++ serial | oneTBB | oneTBB affinity | `pforeach` |
|---|---|---|---|---|---|---|---|---|---|
| axpy | 1000 | 105 ns | 552.0 µs | 2.6 ms | 467.0 µs | 273 ns | 21.5 µs | 31.2 µs | **479 ns** |
| axpy | 10000 | 1.55 µs | 486.0 µs | 3.0 ms | 481.0 µs | 1.64 µs | 32.1 µs | 37.8 µs | **2.38 µs** |
| axpy | 100000 | 19.0 µs | 536.0 µs | 3.0 ms | 508.0 µs | 22.2 µs | 37.5 µs | 44.3 µs | **22.8 µs** |
| axpy | 1000000 | 208.0 µs | 495.0 µs | 5.99 ms | 503.0 µs | 222.0 µs | 83.9 µs | **62.8 µs** | 102.0 µs |
| axpy | 10000000 | 3.58 ms | 1.58 ms | 3.91 ms | 1.27 ms | 3.71 ms | 1.32 ms | 270.0 µs | **180.0 µs** |
| axpy_cold | 10000 | 1.67 µs | 228.0 µs | 2.94 ms | 205.0 µs | 1.76 µs | 45.4 µs | 92.7 µs | **2.47 µs** |
| axpy_cold | 1000000 | 215.0 µs | 230.0 µs | 2.93 ms | 210.0 µs | 204.0 µs | 114.0 µs | 121.0 µs | **100.0 µs** |
| tri | 30 | 2.5 µs | 492.0 µs | 8.2 µs | 258.0 µs | 3.96 µs | 17.9 µs | 29.9 µs | **2.88 µs** |
| tri | 300 | 287.0 µs | 427.0 µs | 5.99 ms | 557.0 µs | 463.0 µs | 38.1 µs | **36.7 µs** | 78.3 µs |
| tri | 3000 | 37.3 ms | 2.15 ms | 4.14 ms | 1.37 ms | 61.0 ms | 1.1 ms | 1.1 ms | **621.0 µs** |


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

## References

- R. M. Karp, A. Sahay, E. E. Santos, K. E. Schauser. *Optimal Broadcast and
  Summation in the LogP Model.* SPAA 1993.
- U. A. Acar, A. Charguéraud, A. Guatto, M. Rainey, F. Sieczkowski.
  *Heartbeat Scheduling: Provable Efficiency for Nested Parallelism.* PLDI 2018.
- U. A. Acar, A. Charguéraud, M. Rainey. *Oracle-Guided Scheduling for
  Controlling Granularity in Implicitly Parallel Languages.* JFP 2016
  (OOPSLA 2011).
- U. A. Acar, V. Aksenov, A. Charguéraud, M. Rainey. *Provably and Practically
  Efficient Granularity Control.* PPoPP 2019.
- S. F. Hummel, E. Schonberg, L. E. Flynn. *Factoring: A Method for Scheduling
  Parallel Loops.* CACM 1992.
- C. D. Polychronopoulos, D. J. Kuck. *Guided Self-Scheduling.* IEEE Trans.
  Computers 1987.
- A. Tzannes, G. C. Caragea, R. Barua, U. Vishkin. *Lazy Binary-Splitting.*
  PPoPP 2010.
- A. Robison, M. Voss, A. Kukanov. *Optimization via Reflection on Work
  Stealing in TBB.* IPDPS 2008 (the `auto_partitioner`).
- The wake-two-more ramp-up in oneTBB's `private_server.cpp` and Java's
  `ForkJoinPool`.

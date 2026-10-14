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
```

`pforeach(f, xs; ntasks)` calls `f(x)` for every element of `xs` (any
`AbstractArray`; other iterables are `collect`ed). `ntasks` caps how many tasks
work on the loop, the caller included. It defaults to the number of threads in
the default pool, plus one when the caller runs outside it (the main task runs
on the interactive thread by default on Julia 1.12 and later).

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
  rest. This greedy cooperative shape is the optimal way to wake many threads
  when a wake takes much longer to land than to send (Karp et al. 1993); a
  fixed fan-out of two, as in oneTBB, is far slower from deep sleep. A loop
  stops starting helpers while 8 of them (plus 2 per running helper) have been
  started but are not running yet: on a machine with no idle thread they would
  only find the loop done, and starting them without that limit cut throughput
  3× in a stress test with twice as many loops as threads.
- **Blocks.** Just before it starts the first helper, the caller cuts what is
  left of the loop into equal blocks. Block 1 belongs to the caller's thread,
  the others to default-pool threads in order. Every task works through the
  block of the thread it runs on first, then helps with the others, taking
  about half of what is left there but at least 1 µs of work. A loop that runs
  repeatedly over the same arrays gets the same blocks on the same threads
  every call, so each piece is still in that core's cache. Blocks live in one
  array, each counter on its own cache line, so claiming iterations never
  touches a counter shared by all tasks.
- **How many blocks.** One per 10 µs of predicted work, rounded up to a power
  of two, and one per thread once that is more than half the threads. Cutting
  exactly by predicted work moved the block boundaries from call to call as
  the timing varied, and a 1M-element loop then spent 4x the CPU time in cache
  misses; always cutting one block per thread made small loops walk through
  many tiny blocks (nested loops ran 1.7x slower).
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
  into the package image. A new loop body only compiles its own inner loop
  (about 10 ms for a small closure), not the scheduler (which took about
  120 ms per body before).
- **No pinning.** Helpers are ordinary tasks; each takes the block of the
  thread it lands on, or, if that thread has no block, the one matching the
  order it was started in. In tests, 97–99% of iterations ran on the same
  thread in consecutive calls of a 5 ms loop, the same as with helpers pinned
  to their block's thread. Pinning Julia's threads to cores
  (`JULIA_EXCLUSIVE=1`) made loops slower on this shared machine, because a
  thread pinned to a busy core cannot move away.

An earlier version also had a mode without blocks, where every task took
chunks from one shared counter. Blocks were as fast or faster nearly
everywhere (2x on loops streaming 800 MB from memory, 1.3–1.6x on 300k–1M
elements, 1.1–1.4x on nested loops), so it was removed.

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
- **The caller does work.** Iterations also run on the calling task, which is
  the interactive thread when called from the REPL or a script's main task.
- **First call.** A new loop body is compiled on its first chunk, on the
  caller. Short first calls may finish before any helper joins.
- No reductions yet; use per-index outputs or per-chunk accumulators.

## Performance

The charts, with every number linked to its data, are on the
[performance dashboard](https://claude.ai/artifact/4TcpEYtgj34RLyRoDsK9cH). The
numbers below are from Julia 1.13.0 (nightly where marked) and oneTBB 2022.0
on a 2-socket AMD EPYC 9354 (64 cores) shared with other users, run on 14 Oct
2026 (load average 10–30, so rows at 32 and 63 threads are noisier). Speedup
is each language's own serial loop divided by the parallel loop, from the
same run.

### Summary

- **Short loops stay near serial speed.** A 10,000-element `axpy` runs at
  0.586× of serial speed with 63 threads, where oneTBB gets
  0.0523× and `@threads` 0.00288×: the caller runs it alone.
- **Large even loops over the same arrays:** 35.9× at 32 threads on 10M-element
  `axpy`, against 29.2× for Polyester and 12.8× for oneTBB's affinity
  partitioner. At 63 threads, 28.7× against 15.4× and 0.685× (Polyester's 64
  spinning workers compete with other users' processes on this machine).
- **Large uneven loops scale like oneTBB:** 52.4× against 54.1× at 63
  threads on the 3,000-element triangle.
- **Medium loops depend on how fast helpers start.** Back to back,
  Polyester's always-spinning workers reach 11.7× on 1M-element `axpy` at
  32 threads, against 4.36× for `pforeach` and 4.29× for oneTBB
  with affinity. On the 300-element triangle at 32 threads, oneTBB reaches
  12.3× and `pforeach` 4.77×.

### Where the time goes: starting helpers

Starting one helper on an idle thread (8 threads, median of 1,500 spawns,
`bench/wake/`, split with `perf record --switch-events`):

| Idle before the spawn | Spawner's `@spawn` | Until the thread gets a core | Julia on the woken thread | Total |
|---|---|---|---|---|
| threads spinning | 2.2 µs | – | – | 3.6 µs |
| asleep 150 us (run 1) | 4.1 µs | 47.7 µs | 14.9 µs | 63.0 µs |
| asleep 150 us (run 2) | 4.1 µs | 48.1 µs | 14.8 µs | 63.2 µs |
| asleep 150 us (run 3) | 4.1 µs | 47.8 µs | 14.8 µs | 63.1 µs |
| asleep 500 us | 4.4 µs | 49.8 µs | 17.1 µs | 67.1 µs |
| asleep 2000 us | 4.0 µs | 51.4 µs | 17.5 µs | 69.1 µs |

- **The hardware is the largest part.** A bare C `futex` wake takes about
  40 µs to get a thread running from 1 ms idle: cores drop into C2 (800 µs
  nominal exit latency) and the `schedutil` governor lowers their clock.
- **Julia's own path on the woken thread** takes 14.8 µs after a short sleep
  and 17.5 µs after a long one: the same code, run with cold caches at a low
  clock. With threads spinning, a whole spawn takes 3.6 µs.
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
| pforeach | 9 | 5.65× | 4.31× | 8.97× | 8.96× |
| oneTBB | 9 | 6.83× | 5.01× | 8.93× | 8.9× |
| pforeach | 33 | 5.73× | 4.46× | 30.8× | 30.4× |
| oneTBB | 33 | 13.8× | 6.32× | 32.1× | 31.3× |
| pforeach | 64 | 4.57× | 3.24× | 53.2× | 49.6× |
| oneTBB | 64 | 16× | 5.72× | 56× | 52.4× |

1M-element `axpy` at 32 threads, back to back and after the threads have been
idle; the last three columns run with `JULIA_THREAD_SLEEP_THRESHOLD=infinite`,
so that Julia's threads never sleep (`bench/wake/axpy1m.jl`,
`bench/compare/axpy1m_parked.jl`):

| Library | Julia | Back to back | After 2 ms idle | After 50 ms idle | Never sleep: back to back | 2 ms | 50 ms |
|---|---|---|---|---|---|---|---|
| Polyester | 1.13 | 17.8 µs | 18.3 µs | 145 µs | 17.9 µs | 18.6 µs | 64.5 µs |
| oneTBB affinity | C++ | 53 µs | 95.2 µs | 229 µs | – | – | – |
| oneTBB | C++ | 87.1 µs | 111 µs | 228 µs | – | – | – |
| ParkedWorkers | nightly | 220 µs | 220 µs | 351 µs | 16.8 µs | 29.3 µs | 75.5 µs |
| parallel_for (vc branch) | nightly | 221 µs | 222 µs | 303 µs | 12.7 µs | 21.8 µs | 45.7 µs |
| pforeach | 1.13 | 51.8 µs | 72.6 µs | 213 µs | 52.9 µs | 52.5 µs | 108 µs |

- **Polyester's lead comes from its workers spinning**: they spin for 2^20
  pauses (tens of ms) after a loop. After 50 ms idle, when they are asleep,
  it takes 145 µs, 8 times its back-to-back time.
- **The parked designs were bimodal in these runs** (medians of three shown):
  back to back, either 12–17 µs or about 220 µs, close to the serial time, as
  if one worker was not woken in time. With threads never sleeping they were
  fast in most runs. Earlier the same day, with the same builds, they took
  16 µs and 12 µs every time, and the speedup table below is from those runs.
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
| axpy 1,000 | **0.17×** | 0.0072× | 0.0201× | 0.000701× |
| axpy 100,000 | 0.82× | 1.58× | **2.91×** | 0.128× |
| axpy 1,000,000 | 4.18× | 12.8× | **14.8×** | 1.28× |
| axpy 10,000,000 | 34.6× | 45.2× | **49.9×** | 5.13× |
| axpy_cold 1,000,000 | **3.04×** | 2.76× | 2.69× | 1.77× |
| tri 30 | **0.867×** | 0.209× | 0.506× | 0.0174× |
| tri 300 | 4.83× | **13.9×** | 13.7× | 1.75× |
| tri 3,000 | **31×** | 16.1× | 16.3× | 11.2× |

- **They win medium loops back to back**, where their workers are still
  spinning: 14.8× for the branch against 4.18× for `pforeach` on
  1M-element `axpy`. With the threads asleep first (2 ms), 3.04× for
  `pforeach` against 2.69× for the branch.
- **`pforeach` wins short loops**, which they always split across every
  thread (0.17× against 0.0201× on 1,000 elements), **and large uneven
  loops**, where one fixed chunk per thread leaves the last thread with most
  of the work (31× against 16.3× on the 3,000-element triangle).
- At 63 threads, on this loaded machine, fixed chunks also stall on busy
  cores: on 10M-element `axpy`, 26.1× for `pforeach` against
  10× for the branch.

### Few long iterations

`n` iterations that each spin for a fixed time (`bench/fewlong.jl`), against
the ideal of `cld(n, threads)` iterations' time. `pforeach` uses one more task
than `@threads` and Polyester (the caller), which is why 9 iterations at
8 threads and 33 at 32 fit in one round:

| Threads | n × iteration | Ideal | `pforeach` | `@threads :dynamic` | Polyester |
|---|---|---|---|---|---|
| 8 | 2 × 1000 µs | 1.00 ms | 1.02 ms | 1.02 ms | 1.00 ms |
| 8 | 4 × 1000 µs | 1.00 ms | 1.04 ms | 1.02 ms | 1.00 ms |
| 8 | 8 × 1000 µs | 1.00 ms | 1.05 ms | 1.02 ms | 1.00 ms |
| 8 | 9 × 1000 µs | 2.00 ms | 1.05 ms | 2.02 ms | 2.00 ms |
| 8 | 16 × 1000 µs | 2.00 ms | 3.04 ms | 2.02 ms | 2.00 ms |
| 8 | 32 × 1000 µs | 4.00 ms | 5.04 ms | 4.03 ms | 4.00 ms |
| 8 | 2 × 100 µs | 0.10 ms | 0.12 ms | 0.11 ms | 0.10 ms |
| 8 | 4 × 100 µs | 0.10 ms | 0.13 ms | 0.11 ms | 0.10 ms |
| 8 | 8 × 100 µs | 0.10 ms | 0.15 ms | 0.12 ms | 0.10 ms |
| 8 | 9 × 100 µs | 0.20 ms | 0.15 ms | 0.22 ms | 0.20 ms |
| 8 | 16 × 100 µs | 0.20 ms | 0.33 ms | 0.22 ms | 0.20 ms |
| 8 | 32 × 100 µs | 0.40 ms | 0.53 ms | 0.42 ms | 0.40 ms |
| 32 | 2 × 1000 µs | 1.00 ms | 1.02 ms | 1.01 ms | 1.00 ms |
| 32 | 4 × 1000 µs | 1.00 ms | 1.04 ms | 1.02 ms | 1.00 ms |
| 32 | 8 × 1000 µs | 1.00 ms | 1.04 ms | 1.03 ms | 1.00 ms |
| 32 | 16 × 1000 µs | 1.00 ms | 1.06 ms | 1.08 ms | 1.00 ms |
| 32 | 32 × 1000 µs | 1.00 ms | 1.08 ms | 1.15 ms | 1.01 ms |
| 32 | 33 × 1000 µs | 2.00 ms | 1.08 ms | 2.02 ms | 2.00 ms |
| 32 | 64 × 1000 µs | 2.00 ms | 3.09 ms | 2.13 ms | 2.01 ms |
| 32 | 128 × 1000 µs | 4.00 ms | 5.08 ms | 4.13 ms | 4.01 ms |
| 32 | 2 × 100 µs | 0.10 ms | 0.12 ms | 0.20 ms | 0.10 ms |
| 32 | 4 × 100 µs | 0.10 ms | 0.14 ms | 0.20 ms | 0.10 ms |
| 32 | 8 × 100 µs | 0.10 ms | 0.14 ms | 0.18 ms | 0.10 ms |
| 32 | 16 × 100 µs | 0.10 ms | 0.15 ms | 0.18 ms | 0.10 ms |
| 32 | 32 × 100 µs | 0.10 ms | 0.26 ms | 0.23 ms | 0.11 ms |
| 32 | 33 × 100 µs | 0.20 ms | 0.25 ms | 0.23 ms | 0.20 ms |
| 32 | 64 × 100 µs | 0.20 ms | 0.36 ms | 0.32 ms | 0.21 ms |
| 32 | 128 × 100 µs | 0.40 ms | 0.55 ms | 0.53 ms | 0.41 ms |

- **Up to as many iterations as threads,** `pforeach` starts one helper right
  away, which brings in the others if the caller's first iteration is still
  running after 20 µs (see How it works); without it, these loops took twice
  the ideal. Bringing in 32 helpers that way takes about 150 µs, which is
  why 32 iterations of 100 µs take 2.6 times the ideal at 32 threads.
- **With more iterations than threads,** the first iteration still runs on
  the caller alone, so the loop takes up to one iteration longer than ideal.
  After it, the remaining iterations take 50–90 µs longer than ideal at
  32 threads: the time for helpers to start.

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

### Remaining gaps

- **Helper start-up on medium loops.** Each helper is a new task started
  through Julia's scheduler, and a woken thread runs 15–17.5 µs of Julia before
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

#### `-t8,1` (oneTBB 9 threads)

| workload | n | serial | `@threads` | Polyester | OhMyThreads | C++ serial | oneTBB | oneTBB affinity | `pforeach` |
|---|---|---|---|---|---|---|---|---|---|
| axpy | 1000 | 91 ns | 23.0 µs | 2.29 µs | 26.8 µs | 140 ns | 22.1 µs | 27.7 µs | **728 ns** |
| axpy | 10000 | 1.56 µs | 25.8 µs | **2.5 µs** | 23.3 µs | 1.62 µs | 38.2 µs | 35.5 µs | 2.6 µs |
| axpy | 100000 | 18.9 µs | 28.7 µs | **9.64 µs** | 30.2 µs | 22.1 µs | 50.4 µs | 42.8 µs | 22.6 µs |
| axpy | 1000000 | 205.0 µs | 86.6 µs | 80.8 µs | 93.3 µs | 223.0 µs | 116.0 µs | 80.5 µs | **46.0 µs** |
| axpy | 10000000 | 3.57 ms | 1.17 ms | 778.0 µs | 1.17 ms | 3.66 ms | 1.31 ms | 474.0 µs | **320.0 µs** |
| axpy_cold | 10000 | 1.69 µs | 25.1 µs | **2.63 µs** | 27.2 µs | 1.73 µs | 50.4 µs | 64.3 µs | 2.82 µs |
| axpy_cold | 1000000 | 215.0 µs | 112.0 µs | 80.3 µs | 131.0 µs | 203.0 µs | 130.0 µs | 102.0 µs | **62.1 µs** |
| tri | 30 | 2.46 µs | 21.1 µs | **2.48 µs** | 22.5 µs | 3.95 µs | 9.13 µs | 11.5 µs | 3.14 µs |
| tri | 300 | 287.0 µs | 87.5 µs | 68.7 µs | 91.6 µs | 462.0 µs | 75.6 µs | 76.8 µs | **60.1 µs** |
| tri | 3000 | 37.3 ms | 9.65 ms | 9.58 ms | 6.93 ms | 61.0 ms | 6.84 ms | 6.83 ms | **4.17 ms** |

#### `-t32,1` (oneTBB 33 threads)

| workload | n | serial | `@threads` | Polyester | OhMyThreads | C++ serial | oneTBB | oneTBB affinity | `pforeach` |
|---|---|---|---|---|---|---|---|---|---|
| axpy | 1000 | 91 ns | 168.0 µs | 7.4 µs | 161.0 µs | 142 ns | 19.7 µs | 24.2 µs | **732 ns** |
| axpy | 10000 | 1.54 µs | 188.0 µs | 6.85 µs | 157.0 µs | 1.63 µs | 30.3 µs | 28.4 µs | **2.6 µs** |
| axpy | 100000 | 18.8 µs | 191.0 µs | **8.17 µs** | 155.0 µs | 22.3 µs | 38.1 µs | 33.4 µs | 22.5 µs |
| axpy | 1000000 | 204.0 µs | 174.0 µs | **17.7 µs** | 186.0 µs | 221.0 µs | 84.4 µs | 51.6 µs | 46.9 µs |
| axpy | 10000000 | 4.03 ms | 1.08 ms | 123.0 µs | 932.0 µs | 3.7 ms | 1.39 ms | 288.0 µs | **112.0 µs** |
| axpy_cold | 10000 | 1.7 µs | 101.0 µs | 6.72 µs | 90.8 µs | 1.74 µs | 57.6 µs | 73.5 µs | **2.9 µs** |
| axpy_cold | 1000000 | 211.0 µs | 118.0 µs | **18.4 µs** | 126.0 µs | 204.0 µs | 115.0 µs | 98.5 µs | 71.0 µs |
| tri | 30 | 2.46 µs | 158.0 µs | 6.76 µs | 149.0 µs | 3.93 µs | 11.5 µs | 16.9 µs | **3.14 µs** |
| tri | 300 | 288.0 µs | 172.0 µs | **24.4 µs** | 177.0 µs | 462.0 µs | 37.5 µs | 39.0 µs | 60.3 µs |
| tri | 3000 | 37.3 ms | 3.56 ms | 2.43 ms | 1.96 ms | 61.2 ms | 1.91 ms | 1.9 ms | **1.26 ms** |

#### `-t63,1` (oneTBB 64 threads)

| workload | n | serial | `@threads` | Polyester | OhMyThreads | C++ serial | oneTBB | oneTBB affinity | `pforeach` |
|---|---|---|---|---|---|---|---|---|---|
| axpy | 1000 | 91 ns | 532.0 µs | 2.99 ms | 525.0 µs | 142 ns | 20.3 µs | 26.0 µs | **873 ns** |
| axpy | 10000 | 1.54 µs | 588.0 µs | 2.02 ms | 505.0 µs | 1.62 µs | 31.1 µs | 34.6 µs | **2.63 µs** |
| axpy | 100000 | 18.9 µs | 504.0 µs | 2.39 ms | 504.0 µs | 22.2 µs | 35.1 µs | 37.9 µs | **22.8 µs** |
| axpy | 1000000 | 204.0 µs | 479.0 µs | 2.69 ms | 396.0 µs | 222.0 µs | 81.8 µs | **55.1 µs** | 99.5 µs |
| axpy | 10000000 | 4.06 ms | 1.26 ms | 5.99 ms | 1.29 ms | 3.76 ms | 1.45 ms | 244.0 µs | **141.0 µs** |
| axpy_cold | 10000 | 1.69 µs | 225.0 µs | 1.95 ms | 219.0 µs | 1.73 µs | 52.9 µs | 89.2 µs | **2.97 µs** |
| axpy_cold | 1000000 | 214.0 µs | 228.0 µs | 1.96 ms | 276.0 µs | 201.0 µs | 119.0 µs | 111.0 µs | **91.3 µs** |
| tri | 30 | 2.46 µs | 539.0 µs | 6.96 µs | 181.0 µs | 3.94 µs | 16.0 µs | 28.2 µs | **3.16 µs** |
| tri | 300 | 288.0 µs | 466.0 µs | 2.99 ms | 554.0 µs | 463.0 µs | 33.1 µs | **32.6 µs** | 75.5 µs |
| tri | 3000 | 37.2 ms | 2.19 ms | 2.92 ms | 1.49 ms | 61.1 ms | 1.13 ms | 1.12 ms | **710.0 µs** |


To rerun:

```
julia +1.13 --project=bench -e 'using Pkg; Pkg.instantiate()'
julia +1.13 -t8,1 --project=bench bench/bench.jl > bench/results/scaling/t8.txt
julia +1.13 -t8,1 --project=bench bench/bench.jl serial pfor > bench/results/scaling/t8-pfor.txt  # pforeach rerun
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

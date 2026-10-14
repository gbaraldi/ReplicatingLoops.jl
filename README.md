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

# A loop that runs again and again over the same arrays:
for step in 1:1000
    pforeach(i -> y[i] = a * x[i] + y[i], eachindex(y); affinity = true)
end
```

`pforeach(f, xs; ntasks, affinity)` calls `f(x)` for every element of `xs` (any
`AbstractArray`; other iterables are `collect`ed). `ntasks` caps how many tasks
work on the loop, the caller included. It defaults to the number of threads in
the default pool, plus one when the caller runs outside it (the main task runs
on the interactive thread by default on Julia 1.12 and later). `affinity` is
described below.

## How it works

Most parallel loops create one task per chunk up front and then wait for them.
That costs tens of microseconds even when the loop itself takes one, and the
waiting threads have to be woken one by one.

Here the caller starts running iterations immediately and times them:

- **Timing.** The caller starts with one iteration and grows its chunks 4x
  until it has run for 1 µs, then estimates the time per iteration. After that,
  every task re-estimates it from each chunk that ran for at least 1 µs, so
  loops whose cost changes along the way are tracked, while a short chunk,
  whose time is mostly overhead, cannot throw the estimate off.
- **Spawning.** Every 5 µs of work, a task raises the number of helpers
  wanted to what the predicted remaining work (time per iteration ×
  iterations left) would keep busy at 10 µs each. Each new helper also asks
  for two more while work is left, so the count can double like a tree even
  when early iterations made the work look small. Every task, the caller
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
  3× in a stress test with twice as many loops as threads. Loops shorter than
  5 µs never spawn anything.
- **Chunks.** Tasks take ranges of iterations from a shared counter, sized to
  about 20 µs of work and at most twice the previous chunk. Once helpers are
  running, a chunk is also at most half of an even share of what is left, so
  chunks shrink near the end and the last ones finish close together.
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

### Affinity

With `affinity = true`, the caller cuts the loop into equal blocks when it
would start its first helper: one block per 10 µs of predicted work, at most
one per thread. Block 1 is the caller's thread; the others go to default-pool
threads in order. One owner per block is wanted right away and started
cooperatively as above, and every task works through its own block first,
then helps with the others. A loop that runs repeatedly over the same arrays
gets the same blocks on the same threads every call, so each piece is still
in that core's cache.

- **No pinning.** Helpers are ordinary tasks; each takes the block of the
  thread it lands on, or, if that thread has no block, the one matching the
  order it was started in. In tests, 97–99% of iterations ran on the same
  thread in consecutive calls of a 5 ms loop, the same as with helpers pinned
  to their block's thread. Pinning Julia's threads to cores
  (`JULIA_EXCLUSIVE=1`) made loops slower on this shared machine, because a
  thread pinned to a busy core cannot move away.
- **Uneven loops.** If the work turns out larger than the first timing
  suggested (early iterations cheaper than later ones), the usual rule starts
  more helpers, which only help with other blocks. A task helping with
  another block takes about half of what is left there, but at least 1 µs of
  work.
- **Flat storage.** All blocks live in one array, each counter on its own
  cache line, followed by a table from thread to block, instead of one object
  per block.

Affinity is 2–3× faster than the default on 1M-element `axpy` that runs over
the same arrays again and again, and 6–14× faster on 10M elements. On uneven
loops it is about as fast as the default: helpers beyond one per block start
when the work turns out larger than first measured.

## Trade-offs

- **Cache affinity is opt-in.** Without `affinity = true`, iterations go to
  whichever task asks first, so a loop that runs repeatedly over the same
  memory-bound data does not keep each piece on the same core.
- **Ramp-up.** Each helper costs its spawner a `@spawn` of 2–5 µs, most of it
  waking a sleeping thread. Libraries whose workers keep spinning between
  loops, such as Polyester and oneTBB, bring in all threads faster when loops
  run back to back.
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
  0.599× of serial speed with 63 threads, where oneTBB gets
  0.0523× and `@threads` 0.00288×: the caller runs it alone.
- **Large even loops over the same arrays scale furthest with affinity:**
  30× at 32 threads on 10M-element `axpy`, against 29.2× for
  Polyester and 12.8× for oneTBB's affinity partitioner. At 63 threads,
  24.1× against 15.4× (Polyester drops to 0.685×: its 64 spinning
  workers compete with other users' processes on this machine).
- **Large uneven loops scale like oneTBB:** 53.4× against 54.1× at 63
  threads on the 3,000-element triangle.
- **Medium loops depend on how fast helpers start.** Back to back,
  Polyester's always-spinning workers reach 11.7× on 1M-element `axpy` at
  32 threads, against 3.95× for `pforeach` with affinity and 4.29× for oneTBB
  with affinity. On the 300-element triangle at 32 threads, oneTBB reaches
  12.3× and `pforeach` 4.74×.

### Where the time goes: starting helpers

Starting one helper on an idle thread (8 threads, median of 1,500 spawns,
`bench/wake/`, split with `perf record --switch-events`):

| Idle before the spawn | Spawner's `@spawn` | Until the thread gets a core | Julia on the woken thread | Total |
|---|---|---|---|---|
| threads spinning | 2.0 µs | – | – | 3.4 µs |
| asleep 150 us (run 1) | 4.3 µs | 21.4 µs | 6.6 µs | 28.2 µs |
| asleep 150 us (run 2) | 4.2 µs | 47.9 µs | 15.2 µs | 63.4 µs |
| asleep 150 us (run 3) | 4.0 µs | 17.3 µs | 5.7 µs | 23.1 µs |
| asleep 500 us | 4.2 µs | 49.4 µs | 16.2 µs | 66.0 µs |
| asleep 2000 us | 4.1 µs | 52.0 µs | 18.4 µs | 71.0 µs |

- **The hardware is the largest part.** A bare C `futex` wake takes about
  40 µs to get a thread running from 1 ms idle: cores drop into C2 (800 µs
  nominal exit latency) and the `schedutil` governor lowers their clock.
- **Julia's own path on the woken thread** takes 5.7 µs after a short sleep
  and 18.4 µs after a long one: the same code, run with cold caches at a low
  clock. With threads spinning, a whole spawn takes 3.4 µs.
- **oneTBB wakes threads the same way**, one futex wake per thread and never a
  broadcast, in a binary tree where a woken worker wakes two more as soon as
  it runs (8 wake calls per cold loop with 9 threads). `pforeach` starts helpers
  cooperatively from a shared counter instead (see How it works), and each
  woken Julia thread makes one extra wake call on its lock (16 per cold loop).
  After running out of work, oneTBB's workers also spin for up to 1 ms, so
  back-to-back loops find them awake.

The triangle with threads awake (loops back to back) and asleep (2 ms pause
before each loop), speedup over each library's own serial loop:

| Library | Threads | 300 awake | 300 asleep | 3,000 awake | 3,000 asleep |
|---|---|---|---|---|---|
| pforeach | 9 | 5.38× | 4.19× | 9.07× | 9.02× |
| oneTBB | 9 | 6.65× | 5.26× | 8.93× | 8.9× |
| pforeach | 33 | 5.67× | 3.8× | 31.9× | 31.5× |
| oneTBB | 33 | 14.4× | 6.51× | 32.1× | 31.4× |
| pforeach | 64 | 4.67× | 3.34× | 53.7× | 52.6× |
| oneTBB | 64 | 15.7× | 5.18× | 56.1× | 52.8× |

1M-element `axpy` at 32 threads, back to back and after the threads have been
idle; the last three columns run with `JULIA_THREAD_SLEEP_THRESHOLD=infinite`,
so that Julia's threads never sleep (`bench/wake/axpy1m.jl`,
`bench/compare/axpy1m_parked.jl`):

| Library | Julia | Back to back | After 2 ms idle | After 50 ms idle | Never sleep: back to back | 2 ms | 50 ms |
|---|---|---|---|---|---|---|---|
| Polyester | 1.13 | 17.8 µs | 17.4 µs | 173 µs | 18.9 µs | 18.6 µs | 62.9 µs |
| oneTBB affinity | C++ | 55.3 µs | 97.5 µs | 218 µs | – | – | – |
| oneTBB | C++ | 88.3 µs | 110 µs | 214 µs | – | – | – |
| ParkedWorkers | nightly | 16 µs | 73.2 µs | 296 µs | 17.1 µs | 30.5 µs | 64.1 µs |
| parallel_for (vc branch) | nightly | 12.2 µs | 67.7 µs | 229 µs | 13.3 µs | 23.5 µs | 48.8 µs |
| pforeach affinity | 1.13 | 58.2 µs | 68.8 µs | 172 µs | 60.4 µs | 51.9 µs | 112 µs |
| pforeach | 1.13 | 142 µs | 144 µs | 244 µs | 147 µs | 144 µs | 195 µs |

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
| axpy 1,000 | **0.165×** | 0.159× | 0.0072× | 0.0201× | 0.000701× |
| axpy 100,000 | 0.82× | 0.375× | 1.58× | **2.91×** | 0.128× |
| axpy 1,000,000 | 1.38× | 4.08× | 12.8× | **14.8×** | 1.28× |
| axpy 10,000,000 | 3.12× | 32.9× | 45.2× | **49.9×** | 5.13× |
| axpy_cold 1,000,000 | 1.36× | **2.84×** | 2.76× | 2.69× | 1.77× |
| tri 30 | **0.772×** | 0.762× | 0.209× | 0.506× | 0.0174× |
| tri 300 | 4.94× | 5.25× | **13.9×** | 13.7× | 1.75× |
| tri 3,000 | 30.7× | **31×** | 16.1× | 16.3× | 11.2× |

- **They win medium loops back to back**, where their workers are still
  spinning: 14.8× for the branch against 4.08× for `pforeach` with affinity on
  1M-element `axpy`. With the threads asleep first (2 ms), `pforeach` with
  affinity matches them: 2.84× against 2.69× for the branch.
- **`pforeach` wins short loops**, which they always split across every
  thread (0.165× against 0.0201× on 1,000 elements), **and large uneven
  loops**, where one fixed chunk per thread leaves the last thread with most
  of the work (30.7× against 16.3× on the 3,000-element triangle).
- At 63 threads, on this loaded machine, fixed chunks also stall on busy
  cores: on 10M-element `axpy`, 25.4× for `pforeach` with affinity against
  10× for the branch.

### What made it faster

Found by tracing every chunk of every task and by profiling with `perf` and
Julia's JIT profiling support (`ENABLE_JITPROFILING=1`); before and after each
change on the same machine.

| Change | Measured on | Threads | Before | After | Kept |
|---|---|---|---|---|---|
| Scheduler code no longer specialized on the loop body, and precompiled | first call of a new loop body (helpers must compile) | 8 | 128.7 ms | 18.6 ms | yes |
| No shared counter updated on every chunk claim (affinity) | 1M-element axpy, affinity, back to back | 32 | 177.5 µs | 91 µs | yes |
| Steals take at least 1 µs; timing only from chunks of at least 1 µs; skip empty blocks | 1M-element axpy, affinity, back to back | 32 | 109.5 µs | 89.5 µs | yes |
| Affinity blocks in one flat array instead of one object per block | 1M-element axpy, affinity, back to back (warm helpers on) | 32 | 67 µs | 47 µs | yes |
| New helpers ask for two more whenever 10 µs of work is left | 300-element triangle, default mode | 32 | 65.5 µs | 55.5 µs | yes |
| Helpers wait 50 µs for the next loop (warm helpers) | 1M-element axpy, affinity, back to back | 32 | 68.5 µs | 42 µs | no: back-to-back loops are not a realistic case |
| Helpers started greedily from a shared counter by every task (cooperative wake-up) | 1M-element axpy, affinity, after 2 ms idle (1.13) | 32 | 100.3 µs | 68.8 µs | yes |
| At most 8 helpers (plus 2 per running one) started but not yet running | stress test: loops finished in 30 s, 2 loops per thread at once (nightly) | 63 | 51142 loops | 137899 loops | yes |

### Remaining gaps

- **Helper start-up on medium loops.** Each helper is a new task started
  through Julia's scheduler, and a woken thread runs 5.7–18.4 µs of Julia before
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

| workload | n | serial | `@threads` | Polyester | OhMyThreads | C++ serial | oneTBB | oneTBB affinity | `pforeach` | `pforeach` affinity |
|---|---|---|---|---|---|---|---|---|---|---|
| axpy | 1000 | 91 ns | 23.0 µs | 2.29 µs | 26.8 µs | 140 ns | 22.1 µs | 27.7 µs | **700 ns** | 804 ns |
| axpy | 10000 | 1.54 µs | 25.8 µs | **2.5 µs** | 23.3 µs | 1.62 µs | 38.2 µs | 35.5 µs | 2.62 µs | 2.68 µs |
| axpy | 100000 | 18.8 µs | 28.7 µs | **9.64 µs** | 30.2 µs | 22.1 µs | 50.4 µs | 42.8 µs | 22.8 µs | 26.3 µs |
| axpy | 1000000 | 205.0 µs | 86.6 µs | 80.8 µs | 93.3 µs | 223.0 µs | 116.0 µs | 80.5 µs | 110.0 µs | **48.1 µs** |
| axpy | 10000000 | 3.59 ms | 1.17 ms | 778.0 µs | 1.17 ms | 3.66 ms | 1.31 ms | 474.0 µs | 1.94 ms | **330.0 µs** |
| axpy_cold | 10000 | 1.68 µs | 25.1 µs | **2.63 µs** | 27.2 µs | 1.73 µs | 50.4 µs | 64.3 µs | 2.92 µs | 3.15 µs |
| axpy_cold | 1000000 | 213.0 µs | 112.0 µs | 80.3 µs | 131.0 µs | 203.0 µs | 130.0 µs | 102.0 µs | 128.0 µs | **71.4 µs** |
| tri | 30 | 2.46 µs | 21.1 µs | **2.48 µs** | 22.5 µs | 3.95 µs | 9.13 µs | 11.5 µs | 3.06 µs | 3.06 µs |
| tri | 300 | 287.0 µs | 87.5 µs | 68.7 µs | 91.6 µs | 462.0 µs | 75.6 µs | 76.8 µs | 56.6 µs | **53.6 µs** |
| tri | 3000 | 37.2 ms | 9.65 ms | 9.58 ms | 6.93 ms | 61.0 ms | 6.84 ms | 6.83 ms | **3.99 ms** | 4.17 ms |

#### `-t32,1` (oneTBB 33 threads)

| workload | n | serial | `@threads` | Polyester | OhMyThreads | C++ serial | oneTBB | oneTBB affinity | `pforeach` | `pforeach` affinity |
|---|---|---|---|---|---|---|---|---|---|---|
| axpy | 1000 | 93 ns | 168.0 µs | 7.4 µs | 161.0 µs | 142 ns | 19.7 µs | 24.2 µs | 980 ns | **783 ns** |
| axpy | 10000 | 1.54 µs | 188.0 µs | 6.85 µs | 157.0 µs | 1.63 µs | 30.3 µs | 28.4 µs | **2.5 µs** | 2.6 µs |
| axpy | 100000 | 18.7 µs | 191.0 µs | **8.17 µs** | 155.0 µs | 22.3 µs | 38.1 µs | 33.4 µs | 22.3 µs | 47.5 µs |
| axpy | 1000000 | 205.0 µs | 174.0 µs | **17.7 µs** | 186.0 µs | 221.0 µs | 84.4 µs | 51.6 µs | 140.0 µs | 52.0 µs |
| axpy | 10000000 | 3.56 ms | 1.08 ms | 123.0 µs | 932.0 µs | 3.7 ms | 1.39 ms | 288.0 µs | 1.64 ms | **119.0 µs** |
| axpy_cold | 10000 | 1.7 µs | 101.0 µs | 6.72 µs | 90.8 µs | 1.74 µs | 57.6 µs | 73.5 µs | **2.79 µs** | 3.3 µs |
| axpy_cold | 1000000 | 213.0 µs | 118.0 µs | **18.4 µs** | 126.0 µs | 204.0 µs | 115.0 µs | 98.5 µs | 152.0 µs | 74.2 µs |
| tri | 30 | 2.46 µs | 158.0 µs | 6.76 µs | 149.0 µs | 3.93 µs | 11.5 µs | 16.9 µs | **2.94 µs** | 3.07 µs |
| tri | 300 | 287.0 µs | 172.0 µs | **24.4 µs** | 177.0 µs | 462.0 µs | 37.5 µs | 39.0 µs | 60.7 µs | 58.5 µs |
| tri | 3000 | 37.2 ms | 3.56 ms | 2.43 ms | 1.96 ms | 61.2 ms | 1.91 ms | 1.9 ms | **1.15 ms** | 1.17 ms |

#### `-t63,1` (oneTBB 64 threads)

| workload | n | serial | `@threads` | Polyester | OhMyThreads | C++ serial | oneTBB | oneTBB affinity | `pforeach` | `pforeach` affinity |
|---|---|---|---|---|---|---|---|---|---|---|
| axpy | 1000 | 91 ns | 532.0 µs | 2.99 ms | 525.0 µs | 142 ns | 20.3 µs | 26.0 µs | **755 ns** | 786 ns |
| axpy | 10000 | 1.54 µs | 588.0 µs | 2.02 ms | 505.0 µs | 1.62 µs | 31.1 µs | 34.6 µs | **2.58 µs** | 2.68 µs |
| axpy | 100000 | 19.1 µs | 504.0 µs | 2.39 ms | 504.0 µs | 22.2 µs | 35.1 µs | 37.9 µs | **22.5 µs** | 68.4 µs |
| axpy | 1000000 | 206.0 µs | 479.0 µs | 2.69 ms | 396.0 µs | 222.0 µs | 81.8 µs | **55.1 µs** | 179.0 µs | 75.8 µs |
| axpy | 10000000 | 3.59 ms | 1.26 ms | 5.99 ms | 1.29 ms | 3.76 ms | 1.45 ms | 244.0 µs | 1.63 ms | **149.0 µs** |
| axpy_cold | 10000 | 1.68 µs | 225.0 µs | 1.95 ms | 219.0 µs | 1.73 µs | 52.9 µs | 89.2 µs | **2.82 µs** | 3.33 µs |
| axpy_cold | 1000000 | 214.0 µs | 228.0 µs | 1.96 ms | 276.0 µs | 201.0 µs | 119.0 µs | 111.0 µs | 177.0 µs | **87.2 µs** |
| tri | 30 | 2.46 µs | 539.0 µs | 6.96 µs | 181.0 µs | 3.94 µs | 16.0 µs | 28.2 µs | **2.94 µs** | 3.06 µs |
| tri | 300 | 287.0 µs | 466.0 µs | 2.99 ms | 554.0 µs | 463.0 µs | 33.1 µs | **32.6 µs** | 69.0 µs | 69.5 µs |
| tri | 3000 | 37.5 ms | 2.19 ms | 2.92 ms | 1.49 ms | 61.1 ms | 1.13 ms | 1.12 ms | 703.0 µs | **666.0 µs** |


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

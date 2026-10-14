# How much of a loop's time is Julia's and how much the scheduler's: the same
# scheduler run normally, with helpers handed to tasks that are already
# running and spinning ("instant": no @spawn, no wake-up), and with those
# tasks joining each loop as soon as it is cut into blocks ("bcast": no policy
# for starting helpers). Needs the scheduler patched with
# counterfactual.patch (against commit d8b9ec9):
#   git worktree add /tmp/rl-cf d8b9ec9 && git -C /tmp/rl-cf apply $PWD/bench/attribution/counterfactual.patch
#   julia -t32,1 --project=/tmp/rl-cf bench/attribution/attribution.jl normal
#   JULIA_THREAD_SLEEP_THRESHOLD=infinite julia -t32,1 --project=/tmp/rl-cf bench/attribution/attribution.jl normal never_sleep
#   julia -t32,1 --project=/tmp/rl-cf bench/attribution/attribution.jl instant
#   julia -t32,1 --project=/tmp/rl-cf bench/attribution/attribution.jl bcast
# bench/results/attribution.csv holds the four runs side by side.
using ReplicatingLoops, Base.Threads, Printf
const RL = ReplicatingLoops
mode = ARGS[1]; label = get(ARGS, 2, mode)
stop = Atomic{Bool}(false)
if mode == "instant"
    RL.start_workers!(stop); RL.K_INSTANT[] = true
elseif mode == "bcast"
    RL.start_bcast!(stop); RL.K_BCAST[] = true
end
@inline axpy_el!(y, x, a, i) = @inbounds y[i] = muladd(a, x[i], y[i])
function tri_el!(out, i)
    s = 0.0
    for j in 1:i; s += sin(j * 1e-3); end
    @inbounds out[i] = s
end
spin(ns) = (t = time_ns(); while time_ns() - t < ns; end)
function hot(f::F) where {F}
    t0 = time(); while time() - t0 < 0.3; f(); end
    best = Inf
    for _ in 1:5
        n = 0; t = time_ns()
        while time_ns() - t < 20_000_000; f(); n += 1; end
        best = min(best, (time_ns() - t) / n)
    end
    best / 1e3
end
function cold(f::F) where {F}
    t0 = time(); while time() - t0 < 0.2; f(); end
    minimum((Libc.systemsleep(0.002); t = time_ns(); f(); (time_ns() - t) / 1e3) for _ in 1:100)
end
function serial_us(g::G) where {G}
    for _ in 1:5; g(); end
    minimum((t = time_ns(); g(); (time_ns() - t) / 1e3) for _ in 1:20)
end
function main()
    println("label,workload,n,state,us,speedup")
    for n in (300, 1000, 3000)
        o = zeros(n)
        ser = serial_us(() -> (for i in 1:n; tri_el!(o, i); end))
        f = () -> pforeach(i -> tri_el!(o, i), 1:n)
        for (st, m) in (("back to back", hot), ("after 2 ms idle", cold))
            us = m(f); @printf("%s,tri,%d,%s,%.1f,%.3g\n", label, n, st, us, ser / us)
        end
    end
    for n in (100_000, 300_000, 1_000_000, 10_000_000)
        y = rand(n); x = rand(n)
        ser = serial_us(() -> (for i in 1:n; axpy_el!(y, x, 1.0, i); end))
        f = () -> pforeach(i -> axpy_el!(y, x, 1.0, i), 1:n)
        for (st, m) in (("back to back", hot), ("after 2 ms idle", cold))
            us = m(f); @printf("%s,axpy,%d,%s,%.1f,%.3g\n", label, n, st, us, ser / us)
        end
    end
    for n in (32, 64)
        g = () -> pforeach(i -> spin(100_000), 1:n)
        for _ in 1:3; g(); end
        us = minimum((t = time_ns(); g(); (time_ns() - t) / 1e3) for _ in 1:20)
        @printf("%s,spin100us,%d,%s,%.1f,%.3g\n", label, n, "ideal $(cld(n, nthreads() + 1) * 100) us", us, cld(n, nthreads() + 1) * 100 / us)
    end
    stop[] = true
end
main()

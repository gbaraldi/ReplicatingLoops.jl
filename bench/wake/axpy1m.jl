# 1M-element axpy: back to back, and after idle gaps of 2 ms and 50 ms (long
# enough that Polyester's workers, which spin for 2^20 pauses, are asleep).
#   julia -tN,1 --project=bench bench/wake/axpy1m.jl <label>
# prints: impl,mode,us,speedup
using ReplicatingLoops, Polyester, Base.Threads
@inline axpy_el!(y, x, a, i) = @inbounds y[i] = muladd(a, x[i], y[i])
axpy_serial!(y, x, a) = (for i in eachindex(y); axpy_el!(y, x, a, i); end)
axpy_batch!(y, x, a) = (@batch for i in eachindex(y); axpy_el!(y, x, a, i); end)
axpy_pfor!(y, x, a) = pforeach(i -> axpy_el!(y, x, a, i), eachindex(y))
function hot(f::F) where {F}
    t0 = time(); while time() - t0 < 0.5; f(); end
    best = Inf
    for _ in 1:7
        n = 0; t = time_ns()
        while time_ns() - t < 20_000_000; f(); n += 1; end
        best = min(best, (time_ns() - t) / n)
    end
    best / 1e3
end
function gap(f::F, s, reps) where {F}
    t0 = time(); while time() - t0 < 0.3; f(); end
    best = Inf
    for _ in 1:reps
        Libc.systemsleep(s)
        t = time_ns(); f(); best = min(best, (time_ns() - t) / 1e3)
    end
    best
end
function main(label)
    y = rand(1_000_000); x = rand(1_000_000)
    ser = hot(() -> axpy_serial!(y, x, 1.0001))
    for (name, f) in (("Polyester", axpy_batch!), ("pforeach", axpy_pfor!))
        g = () -> f(y, x, 1.0001)
        for (mode, t) in (("back to back", hot(g)), ("after 2 ms idle", gap(g, 0.002, 200)), ("after 50 ms idle", gap(g, 0.05, 40)))
            println("$name$label,$mode,$(round(t, digits = 1)),$(round(ser / t, sigdigits = 3))")
        end
    end
end
main(isempty(ARGS) ? "" : ARGS[1])

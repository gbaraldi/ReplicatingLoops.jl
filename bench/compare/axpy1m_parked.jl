# bench/wake/axpy1m.jl for ParkedWorkers.jl and the vc/parallel-for branch's
# parallel_for (both spin 100 µs, then sleep), next to pforeach; Julia nightly.
#   julia +nightly -tN,1 --project=<env> bench/compare/axpy1m_parked.jl <label>
# prints: impl,mode,us,speedup
using ReplicatingLoops, Base.Threads
import ParkedWorkers
Base.include(Base.Threads, joinpath(@__DIR__, "parallel_for_vc.jl"))
@inline axpy_el!(y, x, a, i) = @inbounds y[i] = muladd(a, x[i], y[i])
axpy_serial!(y, x, a) = (for i in eachindex(y); axpy_el!(y, x, a, i); end)
axpy_parked!(y, x, a) = ParkedWorkers.pforeach(i -> axpy_el!(y, x, a, i), eachindex(y))
axpy_branch!(y, x, a) = Base.Threads.parallel_for(i -> axpy_el!(y, x, a, i), eachindex(y))
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
    for (name, f) in (("ParkedWorkers", axpy_parked!), ("parallel_for (vc branch)", axpy_branch!),
                      ("pforeach", axpy_pfor!))
        g = () -> f(y, x, 1.0001)
        for (mode, t) in (("back to back", hot(g)), ("after 2 ms idle", gap(g, 0.002, 200)), ("after 50 ms idle", gap(g, 0.05, 40)))
            println("$name$label,$mode,$(round(t, digits = 1)),$(round(ser / t, sigdigits = 3))")
        end
    end
end
main(isempty(ARGS) ? "" : ARGS[1])

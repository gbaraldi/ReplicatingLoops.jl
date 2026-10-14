# bench.jl's workloads for ParkedWorkers.jl and the parallel_for of Julia's
# vc/parallel-for branch, next to pforeach, @threads and OhMyThreads. Runs on
# Julia nightly, which that branch needs (Polyester crashes there).
#
#   julia +nightly -tN,1 --project=<env with ReplicatingLoops, ParkedWorkers,
#       OhMyThreads> bench/compare/bench_parked.jl [impl...]
#
# Prints `RESULT <workload> <impl> <size> <ns>`: the best mean time per loop
# over several timing batches. "hot" workloads run loops back to back; "cold"
# ones sleep 2 ms between loops so idle threads have gone to sleep.
using Base.Threads
using ReplicatingLoops, OhMyThreads
import ParkedWorkers
Base.include(Base.Threads, joinpath(@__DIR__, "parallel_for_vc.jl"))

const NT = nthreads(:default)

function bench_ns(f::F; reps = 7) where {F}
    # Warm up long enough for helper tasks to be compiled too.
    t0 = time()
    while time() - t0 < 0.3
        f()
    end
    inner = 1
    t = @elapsed f()
    while t < 2e-3   # t is the time of the whole batch of `inner` calls
        inner *= 2
        t = @elapsed (for _ in 1:inner; f(); end)
    end
    best = Inf
    for _ in 1:reps
        t = @elapsed (for _ in 1:inner; f(); end)
        best = min(best, t / inner)
    end
    return best * 1e9
end

# One loop at a time, after idle threads have gone to sleep.
function cold_ns(f::F; reps = 200) where {F}
    t0 = time()
    while time() - t0 < 0.3
        f()
    end
    best = Inf
    for _ in 1:reps
        Libc.systemsleep(0.002)
        t = time_ns()
        f()
        best = min(best, time_ns() - t)
    end
    return Float64(best)
end

result(w, impl, n, ns) = (println("RESULT ", w, " ", impl, " ", n, " ", round(Int, ns)); flush(stdout))

# axpy: tiny uniform work per element.
@inline axpy_el!(y, x, a, i) = @inbounds y[i] = muladd(a, x[i], y[i])

axpy_serial!(y, x, a) = (for i in eachindex(y); axpy_el!(y, x, a, i); end)
axpy_threads!(y, x, a) = (@threads for i in eachindex(y); axpy_el!(y, x, a, i); end)
axpy_parked!(y, x, a) = ParkedWorkers.pforeach(i -> axpy_el!(y, x, a, i), eachindex(y))
axpy_branch!(y, x, a) = Base.Threads.parallel_for(i -> axpy_el!(y, x, a, i), eachindex(y))
axpy_omt!(y, x, a) = tforeach(i -> axpy_el!(y, x, a, i), eachindex(y))
axpy_pfor!(y, x, a) = pforeach(i -> axpy_el!(y, x, a, i), eachindex(y))

# Triangle: the cost of element i grows with i, so static splits are uneven.
function tri_el!(out, i)
    s = 0.0
    for j in 1:i
        s += sin(j * 1e-3)
    end
    @inbounds out[i] = s
end

tri_serial!(out) = (for i in eachindex(out); tri_el!(out, i); end)
tri_threads!(out) = (@threads for i in eachindex(out); tri_el!(out, i); end)
tri_parked!(out) = ParkedWorkers.pforeach(i -> tri_el!(out, i), eachindex(out))
tri_branch!(out) = Base.Threads.parallel_for(i -> tri_el!(out, i), eachindex(out))
tri_omt!(out) = tforeach(i -> tri_el!(out, i), eachindex(out))
tri_pfor!(out) = pforeach(i -> tri_el!(out, i), eachindex(out))

const IMPLS = Dict(
    "serial" => (axpy_serial!, tri_serial!),
    "threads" => (axpy_threads!, tri_threads!),
    "parked" => (axpy_parked!, tri_parked!),
    "branch" => (axpy_branch!, tri_branch!),
    "omt" => (axpy_omt!, tri_omt!),
    "pfor" => (axpy_pfor!, tri_pfor!),
)

impls = isempty(ARGS) ? ["serial", "threads", "omt", "pfor", "parked", "branch"] : ARGS
println("# nthreads default=", NT, " interactive=", nthreads(:interactive),
        " caller pool=", threadpool(), " julia=", VERSION)
for name in impls
    axpy!, tri! = IMPLS[name]
    for n in (1_000, 10_000, 100_000, 1_000_000, 10_000_000)
        y = rand(n); x = rand(n)
        result("axpy", name, n, bench_ns(() -> axpy!(y, x, 1.0001)))
    end
    for n in (10_000, 1_000_000)
        y = rand(n); x = rand(n)
        result("axpy_cold", name, n, cold_ns(() -> axpy!(y, x, 1.0001)))
    end
    for n in (30, 300, 3_000)
        out = zeros(n)
        result("tri", name, n, bench_ns(() -> tri!(out)))
    end
end

# One workload, run back to back for a while, for the profilers in this folder.
#   julia -tN,1 --project=bench bench/profile/workload.jl <name> <seconds> [walltime]
# names: axpy1m, axpy1m_cold (2 ms idle before each loop), tri300, tri3000,
# spin32 (32 iterations of 100 µs), nested (64 × 2,000), small (64 elements).
# With `walltime`, also prints a wall-clock profile of every task (Julia 1.12+),
# by the innermost ReplicatingLoops function on each sampled stack.
using ReplicatingLoops, Base.Threads, Printf, Profile

@inline axpy_el!(y, x, a, i) = @inbounds y[i] = muladd(a, x[i], y[i])
function tri_el!(out, i)
    s = 0.0
    for j in 1:i
        s += sin(j * 1e-3)
    end
    @inbounds out[i] = s
end
spin(ns) = (t = time_ns(); while time_ns() - t < ns; end)

# One function per workload, so each closure captures its own arrays (a
# variable assigned in several branches of one function would be boxed, and
# the loop body would then dispatch dynamically on every element).
function axpy_workload(cold)
    y = rand(10^6); x = rand(10^6)
    f = () -> pforeach(i -> axpy_el!(y, x, 1.0, i), eachindex(y))
    return cold ? () -> (Libc.systemsleep(0.002); f()) : f
end
tri_workload(n) = (o = zeros(n); () -> pforeach(i -> tri_el!(o, i), eachindex(o)))
spin_workload() = () -> pforeach(i -> spin(100_000), 1:32)
nested_workload() = (y = zeros(64 * 2000);
    () -> pforeach(j -> pforeach(i -> (@inbounds y[(j - 1) * 2000 + i] += sin(i)), 1:2000), 1:64))
small_workload() = (y = zeros(64); () -> pforeach(i -> (@inbounds y[i] += 1.0), 1:64))

function workload(name)
    name == "axpy1m" && return axpy_workload(false)
    name == "axpy1m_cold" && return axpy_workload(true)
    startswith(name, "tri") && return tri_workload(parse(Int, name[4:end]))
    name == "spin32" && return spin_workload()
    name == "nested" && return nested_workload()
    name == "small" && return small_workload()
    error("unknown workload $name")
end

function run_for(f, secs)
    n = 0
    t0 = time()
    while time() - t0 < secs
        f()
        n += 1
    end
    return n
end

# Wall-clock samples of every task (Julia 1.12+), counted for the tasks that
# ever run ReplicatingLoops code (the caller and the helpers), grouped by the
# innermost frame in ReplicatingLoops: where those tasks are, not only where
# the CPUs are. Samples outside it name the innermost Julia frame.
function walltime_report(f, secs)
    Profile.clear()
    Profile.init(n = 10^8, delay = 2e-5)
    n = Profile.@profile_walltime run_for(f, secs)
    data, lidict = Profile.retrieve()
    nmeta = Profile.nmeta
    samples = Tuple{UInt,String,Bool}[]     # task, category, in the package
    i = 1
    frames = UInt[]
    while i <= length(data)
        if data[i] == 0 && i < length(data) && data[i+1] == 0
            # Each backtrace ends with nmeta metadata words (thread, task, ...).
            task = frames[end - nmeta + 2]
            bt = frames[1:end-nmeta]
            cat, inpkg = "", false
            for ip in bt, sf in get(lidict, ip, Base.StackTraces.StackFrame[])
                if endswith(String(sf.file), "ReplicatingLoops.jl")
                    fn = String(sf.func)
                    cat, inpkg = occursin("Body", fn) ? "loop body" : fn, true
                    @goto found
                end
            end
            for ip in bt, sf in get(lidict, ip, Base.StackTraces.StackFrame[])
                sf.from_c && continue
                cat = "outside: " * String(sf.func)
                @goto found
            end
            cat = "outside: ?"
            @label found
            push!(samples, (task, cat, inpkg))
            empty!(frames)
            i += 2
        else
            push!(frames, data[i])
            i += 1
        end
    end
    ours = Set(t for (t, _, p) in samples if p)
    counts = Dict{String,Int}()
    for (t, c, _) in samples
        t in ours && (counts[c] = get(counts, c, 0) + 1)
    end
    total = sum(values(counts); init = 0)
    @printf("wall-clock samples of the %d tasks that ran pforeach code: %d (%d loops; %d samples of other tasks left out)\n",
            length(ours), total, n, length(samples) - total)
    for (k, v) in sort(collect(counts), by = x -> -last(x))
        100v / total >= 0.3 && @printf("  %5.1f%%  %s\n", 100v / total, k)
    end
end

name, secs = ARGS[1], parse(Float64, ARGS[2])
f = workload(name)
run_for(f, 0.5)    # compile and warm up
if get(ARGS, 3, "") == "walltime"
    walltime_report(f, secs)
else
    # Under `perf ... --control fifo:<ctl> -D -1`, count only the timed loops.
    ctl = get(ENV, "PERF_CTL", "")
    perf(cmd) = isempty(ctl) || open(io -> write(io, cmd * "\n"), ctl, "w")
    perf("enable")
    n = run_for(f, secs)
    perf("disable")
    @printf("%s: %d loops in %.1f s, %.1f µs each\n", name, n, secs, secs * 1e6 / n)
end

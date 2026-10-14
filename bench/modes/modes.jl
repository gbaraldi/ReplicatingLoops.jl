# The A/B behind removing the shared-counter mode: shared counter ("default")
# against blocks ("affinity"), on workloads chosen to find where blocks lose.
# Needs commit 2c7eb2a, which still had the `affinity` keyword; the
# "blocks_after_heartbeat" column of bench/results/modes.csv used the same
# commit with the split waiting for the 5 µs heartbeat (`maybe_raise!` without
# its `(r.affinity && r.nb == 0) ||` clause).
#   git worktree add /tmp/rl-2c7eb2a 2c7eb2a
#   julia -tN,1 --project=/tmp/rl-2c7eb2a bench/modes/modes.jl t<N> default,affinity
using ReplicatingLoops, Base.Threads, Random
@inline axpy_el!(y, x, a, i) = @inbounds y[i] = muladd(a, x[i], y[i])
function tri_el!(out, i)
    s = 0.0
    for j in 1:i; s += sin(j * 1e-3); end
    @inbounds out[i] = s
end
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
fmt(v) = v < 10 ? string(round(v, digits = 2)) : v < 1000 ? string(round(v, digits = 1)) : string(round(Int, v))
function main(label, modes)
    rows = Pair{String,Function}[]
    for n in (30_000, 100_000, 300_000, 1_000_000)
        y = rand(n); x = rand(n)
        push!(rows, "axpy $(n)" => aff -> hot(() -> pforeach(i -> axpy_el!(y, x, 1.0, i), eachindex(y); affinity = aff)))
        push!(rows, "axpy $(n) cold" => aff -> cold(() -> pforeach(i -> axpy_el!(y, x, 1.0, i), eachindex(y); affinity = aff)))
    end
    let n = 50_000_000, y = rand(n), x = rand(n)   # 800 MB: bigger than all caches
        push!(rows, "axpy 50M (streaming)" => aff -> hot(() -> pforeach(i -> axpy_el!(y, x, 1.0, i), eachindex(y); affinity = aff)))
    end
    let n = 1_000_000, y = zeros(n), x = rand(n), p = randperm(MersenneTwister(1), n)  # random gathers
        push!(rows, "gather 1M (random)" => aff -> hot(() -> pforeach(i -> (@inbounds y[i] = x[p[i]]), eachindex(y); affinity = aff)))
    end
    for n in (100, 300, 1000)
        o = zeros(n)
        push!(rows, "tri $(n)" => aff -> hot(() -> pforeach(i -> tri_el!(o, i), eachindex(o); affinity = aff)))
    end
    let y = zeros(64 * 2000)   # nested: 64 outer, 2000 inner
        push!(rows, "nested 64x2000" => aff -> hot(() -> pforeach(j -> pforeach(i -> (@inbounds y[(j - 1) * 2000 + i] += sin(i)), 1:2000; affinity = aff), 1:64; affinity = aff)))
    end
    push!(rows, "concurrent: loops/ms" => function (aff)
        # 2 loops per thread at once, mixed sizes; throughput over 1 s
        stop = Atomic{Bool}(false); done = Atomic{Int}(0)
        ts = [Threads.@spawn begin
                  y = rand(20_000); x = rand(20_000); o = zeros(200)
                  while !stop[]
                      pforeach(i -> axpy_el!(y, x, 1.0, i), eachindex(y); affinity = aff)
                      pforeach(i -> tri_el!(o, i), eachindex(o); affinity = aff)
                      atomic_add!(done, 1)
                  end
              end for _ in 1:2nthreads()]
        sleep(0.3); done[] = 0; sleep(1.0); stop[] = true; foreach(wait, ts)
        done[] / 1000
    end)
    for (name, f) in rows
        vals = [fmt(f(m == "affinity")) for m in modes]
        println(label, ",", name, ",", join(vals, ","))
    end
end
main(ARGS[1], split(ARGS[2], ","))

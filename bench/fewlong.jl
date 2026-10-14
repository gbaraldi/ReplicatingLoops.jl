# Few, long iterations: n iterations of a fixed busy time each, from 2 to 4x the
# number of threads, against @threads :dynamic and Polyester. The ideal is
# cld(n, nthreads) iterations' time.
#   julia -tN,1 --project=bench bench/fewlong.jl > bench/results/fewlong.csv
using ReplicatingLoops, Polyester, Base.Threads, Printf

spin(ns) = (t = time_ns(); while time_ns() - t < ns; end)

fl_pfor(n, c) = pforeach(i -> spin(c), 1:n)
fl_threads(n, c) = (@threads :dynamic for i in 1:n; spin(c); end)
fl_batch(n, c) = (@batch for i in 1:n; spin(c); end)

function best(g, reps)
    g(); g()
    minimum((t = time_ns(); g(); (time_ns() - t) / 1e3) for _ in 1:reps)
end

# One library at a time, Polyester last: its workers keep spinning on Julia's
# threads for milliseconds after a loop, which would hold up the others.
function main()
    P = nthreads(:default)
    println("key,threads,n,cost_us,ideal_us,impl,label,us,over_ideal")
    for (impl, label, f) in (("pfor", "pforeach", fl_pfor), ("threads", "@threads :dynamic", fl_threads),
                             ("batch", "Polyester @batch", fl_batch))
        for c in (100_000, 1_000_000), n in unique([2, 4, 8, P ÷ 2, P, P + 1, 2P, 4P])
            reps = c >= 1_000_000 ? 5 : 20
            ideal = cld(n, P) * c / 1e3
            us = best(() -> f(n, c), reps)
            @printf("%s-%d-%d-%d,%d,%d,%d,%.0f,%s,\"%s\",%.0f,%.2f\n", impl, P, n, c ÷ 1000,
                    P, n, c ÷ 1000, ideal, impl, label, us, us / ideal)
        end
    end
end
main()

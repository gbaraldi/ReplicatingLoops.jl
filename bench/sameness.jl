# How often an iteration runs on the same thread as in the previous call, for
# a loop run again and again: the point of cutting loops into blocks.
#   julia -tN,1 --project=bench bench/sameness.jl > bench/results/sameness.csv
using ReplicatingLoops, Base.Threads, Printf
busy(ns) = (t = time_ns(); while time_ns() - t < ns; end)
function sameness(n, cost)
    tids = zeros(Int, n)
    mark = i -> (cost > 0 && busy(cost); @inbounds tids[i] = threadid())
    for _ in 1:50; pforeach(mark, 1:n); end
    fr = Float64[]
    for _ in 1:100
        pforeach(mark, 1:n); a = copy(tids)
        pforeach(mark, 1:n)
        push!(fr, count(a .== tids) / n)
    end
    sort!(fr)
    t = minimum((tm = time_ns(); pforeach(mark, 1:n); (time_ns() - tm) / 1e3) for _ in 1:20)
    return fr[50], fr[10], length(unique(tids)), t
end
println("threads,n,cost_ns,loop_us,same_thread_median,same_thread_p10,threads_used")
for (n, cost) in ((1_000_000, 0), (100_000, 0), (10_000, 500))
    med, p10, used, t = sameness(n, cost)
    @printf("%d,%d,%d,%.0f,%.3f,%.3f,%d\n", nthreads(), n, cost, t, med, p10, used)
end

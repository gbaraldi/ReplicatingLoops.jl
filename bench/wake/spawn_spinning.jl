# One @spawn at a time while idle threads spin (run with
# JULIA_THREAD_SLEEP_THRESHOLD=infinite): spawner cost and spawn -> task start.
# prints: spinning,<spawner_us>,,,<total_us>
using Base.Threads
const started = Atomic{Int}(0)
function one()
    started[] = 0
    t0 = time_ns()
    t = Threads.@spawn :default (started[] = time_ns())
    t1 = time_ns()
    wait(t)
    return t1 - t0, started[] - t0
end
function main()
    for _ in 1:200; one(); Libc.systemsleep(0.001); end
    c = Int[]; l = Int[]
    for _ in 1:1500
        Libc.systemsleep(0.001)
        x, y = one(); push!(c, x); push!(l, y)
    end
    med(v) = round(sort(v)[length(v) ÷ 2] / 1e3, digits = 1)
    println("threads spinning,$(med(c)),,,$(med(l))")
end
main()

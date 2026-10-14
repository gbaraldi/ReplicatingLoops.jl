# One @spawn at a time onto an idle default-pool thread, after `gap` seconds of
# idle. Writes spawn time, spawner return, task start and the task's OS thread
# id, to match against `perf record -e dummy --switch-events -k mono`.
#   julia -tN,1 bench/wake/spawn_split.jl <out.csv> <gap seconds>
using Base.Threads
const started = Atomic{Int}(0)
const ostid = Atomic{Int}(0)
function one()
    started[] = 0
    t0 = time_ns()
    t = Threads.@spawn :default (started[] = time_ns(); ostid[] = ccall(:gettid, Cint, ()))
    t1 = time_ns()
    wait(t)
    return (Int(t0), Int(t1), started[], ostid[])
end
function main(path, gap)
    for _ in 1:200; one(); Libc.systemsleep(gap); end
    rows = NTuple{4,Int}[]
    for _ in 1:1500
        Libc.systemsleep(gap)
        push!(rows, one())
    end
    open(path, "w") do io
        foreach(r -> println(io, join(r, ",")), rows)
    end
end
main(ARGS[1], parse(Float64, ARGS[2]))

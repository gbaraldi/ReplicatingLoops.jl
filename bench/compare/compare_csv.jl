# Collect bench/results/compare/nightly-t<N>[-pfor].txt into one CSV: one row
# per workload, implementation and thread count, with the speedup over the
# serial loop of the same run. Later -pfor files replace pforeach rows.
#   julia bench/compare/compare_csv.jl > bench/results/compare/compare.csv
const DIR = joinpath(@__DIR__, "..", "results", "compare")
const LABELS = Dict("pfor" => "pforeach", "pfor_aff" => "pforeach, affinity",
                    "parked" => "ParkedWorkers.jl", "branch" => "Threads.parallel_for (vc branch)",
                    "threads" => "@threads", "omt" => "OhMyThreads tforeach")
println("key,workload,n,impl,label,threads,ns,serial_ns,speedup")
rows = Dict{Tuple{String,Int,String,Int},String}()
order = Tuple{String,Int,String,Int}[]
files = filter(f -> occursin(r"^nightly-t\d+(-pfor)?\.txt$", f), readdir(DIR))
for f in sort(files; by = f -> (parse(Int, match(r"t(\d+)", f)[1]), occursin("-pfor", f)))
    nt = parse(Int, match(r"t(\d+)", f)[1])
    res = Dict{Tuple{String,String,Int},Float64}()
    for line in eachline(joinpath(DIR, f))
        startswith(line, "RESULT ") || continue
        _, w, impl, n, ns = split(line)
        res[(w, impl, parse(Int, n))] = parse(Float64, ns)
    end
    for ((w, impl, n), ns) in sort(collect(res); by = first)
        haskey(LABELS, impl) || continue
        serial = res[(w, "serial", n)]
        key = (w, n, impl, nt)
        haskey(rows, key) || push!(order, key)
        rows[key] = join(("$w-$n-$impl-$nt", w, n, impl, "\"$(LABELS[impl])\"", nt, round(Int, ns),
                          round(Int, serial), round(serial / ns, sigdigits = 3)), ",")
    end
end
foreach(k -> println(rows[k]), order)

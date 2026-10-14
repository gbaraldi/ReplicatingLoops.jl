# Collect bench/results/scaling/{t,tbb-t}<N>*.txt into one CSV for the scaling
# charts: one row per workload size, implementation and thread count, with the
# speedup over the same language's serial loop from the same run.
#
#   julia bench/scaling_csv.jl > bench/results/scaling/scaling.csv

const DIR = joinpath(@__DIR__, "results", "scaling")

const CASES = Dict(("axpy", 10_000) => "small", ("axpy", 1_000_000) => "medium",
                   ("axpy", 10_000_000) => "large", ("tri", 30) => "small",
                   ("tri", 300) => "medium", ("tri", 3_000) => "large",
                   ("axpy_cold", 10_000) => "small", ("axpy_cold", 1_000_000) => "medium")

# impl => (label, language, uses the calling thread too)
const IMPLS = Dict(
    "pfor" => ("pforeach", "Julia", true),
    "pfor_aff" => ("pforeach, affinity", "Julia", true),
    "threads" => ("@threads", "Julia", false),
    "batch" => ("Polyester @batch", "Julia", false),
    "omt" => ("OhMyThreads tforeach", "Julia", false),
    "tbb" => ("oneTBB", "C++", true),
    "tbb_affinity" => ("oneTBB, affinity", "C++", true),
)

function read_results(file)
    res = Dict{Tuple{String,String,Int},Float64}()
    for line in eachline(file)
        startswith(line, "RESULT ") || continue
        _, w, impl, n, ns = split(line)
        res[(w, impl, parse(Int, n))] = parse(Float64, ns)
    end
    return res
end

println("key,workload,case,n,impl,label,language,threads,threads_used,ns,serial_ns,serial_us,speedup")
# t<N>.txt and tbb-t<N>.txt hold full runs; t<N>-<name>.txt are later reruns of
# some implementations, which replace those rows.
rows = Dict{Tuple{String,String,String,Int},String}()
order = Tuple{String,String,String,Int}[]
files = filter(f -> occursin(r"^(tbb-)?t\d+(-\w+)?\.txt$", f), readdir(DIR))
for f in sort(files; by = f -> (parse(Int, match(r"t(\d+)", f)[1]), occursin('-', replace(f, "tbb-" => "")), f))
    nt = parse(Int, match(r"t(\d+)", f)[1])
    res = read_results(joinpath(DIR, f))
    for ((w, impl, n), ns) in sort(collect(res); by = first)
        haskey(CASES, (w, n)) && haskey(IMPLS, impl) || continue
        serial = get(res, (w, "serial", n), NaN)
        label, lang, caller = IMPLS[impl]
        c = CASES[(w, n)]
        key = (w, c, impl, nt)
        haskey(rows, key) || push!(order, key)
        rows[key] = join(("$w-$c-$impl-$nt", w, c, n, impl, "\"$label\"", lang, nt, nt + caller,
                          round(Int, ns), round(Int, serial), round(serial / 1e3, sigdigits = 3),
                          round(serial / ns, sigdigits = 3)), ",")
    end
end
foreach(k -> println(rows[k]), order)

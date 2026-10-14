# Print benchmark results as one markdown table, merging bench.jl and
# bench_tbb output for the same thread count. Later files replace earlier rows.
#
#   julia bench/table.jl bench/results/scaling/{t8,t8-pfor,tbb-t8}.txt
function fmt(ns)
    ns < 1e3 && return string(round(Int, ns), " ns")
    ns < 1e6 && return string(round(ns / 1e3, sigdigits = 3), " µs")
    return string(round(ns / 1e6, sigdigits = 3), " ms")
end

# (file kind, impl) => column name; serial runs from both languages are kept.
const COLUMNS = [
    ("julia", "serial") => "serial",
    ("julia", "threads") => "`@threads`",
    ("julia", "batch") => "Polyester",
    ("julia", "omt") => "OhMyThreads",
    ("tbb", "serial") => "C++ serial",
    ("tbb", "tbb") => "oneTBB",
    ("tbb", "tbb_affinity") => "oneTBB affinity",
    ("julia", "pfor") => "`pforeach`",
    ("julia", "pfor_aff") => "`pforeach` affinity",
]

rows = Dict{Tuple{String,Int},Dict{Tuple{String,String},Float64}}()
order = Tuple{String,Int}[]
headers = String[]
for file in ARGS
    kind = occursin("tbb", basename(file)) ? "tbb" : "julia"
    for line in eachline(file)
        startswith(line, "# ") && push!(headers, line[3:end])
        startswith(line, "RESULT ") || continue
        _, w, impl, n, ns = split(line)
        key = (w, parse(Int, n))
        haskey(rows, key) || (rows[key] = Dict(); push!(order, key))
        rows[key][(kind, impl)] = parse(Float64, ns)
    end
end

cols = [c for c in COLUMNS if any(r -> haskey(r, first(c)), values(rows))]
println("### ", join(headers, "; "), "\n")
println("| workload | n | ", join(last.(cols), " | "), " |")
println("|---|---|", repeat("---|", length(cols)))
for key in order
    r = rows[key]
    par = [r[k] for (k, _) in cols if k[2] != "serial" && haskey(r, k)]
    best = isempty(par) ? NaN : minimum(par)
    cells = map(cols) do (k, _)
        haskey(r, k) || return "–"
        s = fmt(r[k])
        k[2] != "serial" && r[k] == best ? "**$s**" : s
    end
    println("| ", key[1], " | ", key[2], " | ", join(cells, " | "), " |")
end
println()

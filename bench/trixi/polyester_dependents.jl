# The packages in the General registry whose latest version depends directly
# on a package (by UUID); for Polyester:
#   julia bench/trixi/polyester_dependents.jl f517fe37-dbe3-4b94-8317-1923a5111588
# Packages in General whose latest version depends directly on a given package.
using Pkg, TOML
target = Base.UUID(ARGS[1])
reg = only(filter(r -> r.name == "General", Pkg.Registry.reachable_registries()))
out = String[]
for (uuid, entry) in reg
    info = Pkg.Registry.registry_info(reg, entry)
    vs = collect(keys(info.version_info))
    isempty(vs) && continue
    v = maximum(vs)
    deps = Pkg.Registry.query_deps_for_version(info.deps, info.weak_deps, v)
    target in deps || continue
    push!(out, "$(entry.name) $(v)$(target in keys(get(info.weak_deps, v, Dict())) ? " (weak)" : "")")
end
foreach(println, sort(out))
println(length(out), " packages")

# How many parallel loops one right-hand-side evaluation runs, and over how
# many elements, in the patched Trixi (counts `ReplicatingLoops.Loop`s made).
#   julia -t8,1 --project=<env with the patched Trixi> bench/trixi/count_loops.jl
using Trixi, OrdinaryDiffEqLowStorageRK, Printf, ReplicatingLoops
const NS = Int[]
@eval ReplicatingLoops Loop(@nospecialize(body), n::Int, maxhelpers::Int) =
    (push!(Main.NS, n); Loop(0, n, 0, 0, 0, 0.0, false, nothing, nothing, body, n, maxhelpers, NO_BLOCKS, 0, UInt64(0), UInt(0)))
for (elixir, level) in [("tree_2d_dgsem/elixir_euler_source_terms.jl", 5), ("tree_2d_dgsem/elixir_euler_source_terms.jl", 7),
                        ("tree_3d_dgsem/elixir_euler_taylor_green_vortex.jl", 3), ("tree_2d_dgsem/elixir_euler_sedov_blast_wave_sc_subcell.jl", 5)]
    redirect_stdout(devnull) do
        trixi_include(Main, joinpath(examples_dir(), elixir); initial_refinement_level = level, tspan = (0.0, 1e-6))
    end
    Base.invokelatest() do
        ode = semidiscretize(Main.semi, (0.0, 1.0)); u = copy(ode.u0); du = similar(u)
        ode.f(du, u, ode.p, 0.0); empty!(NS)
        ode.f(du, u, ode.p, 0.0)
        s = sort(NS)
        @printf("%-45s level %d: %d parallel loops per rhs!, sizes: min %d, median %d, max %d; loops with < 64 elements: %d\n",
                basename(elixir), level, length(s), s[1], s[cld(end, 2)], s[end], count(<(64), s))
    end
end

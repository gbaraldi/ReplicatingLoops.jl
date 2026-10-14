# Trixi.jl with Polyester (its default) or with ReplicatingLoops behind its
# `@threaded`/`@batch` (trixi_pforeach.patch): time of one right-hand-side
# evaluation (all of Trixi's parallel loops) and of one time step, for one
# variant at one thread count. See run.sh.
#   julia -tN,1 --project=<env> bench/trixi/trixi_bench.jl <poly|pfor>
using Trixi, OrdinaryDiffEqLowStorageRK, Printf, Statistics
variant = ARGS[1]
CASES = [("tree_2d_dgsem/elixir_euler_source_terms.jl", 5), ("tree_2d_dgsem/elixir_euler_source_terms.jl", 6),
         ("tree_2d_dgsem/elixir_euler_source_terms.jl", 7), ("tree_3d_dgsem/elixir_euler_taylor_green_vortex.jl", 3),
         ("tree_3d_dgsem/elixir_euler_taylor_green_vortex.jl", 4), ("tree_2d_dgsem/elixir_euler_sedov_blast_wave_sc_subcell.jl", 5)]
function bench_rhs(ode, n)
    u = copy(ode.u0); du = similar(u)
    for _ in 1:20; ode.f(du, u, ode.p, 0.0); end
    ts = Float64[]
    for _ in 1:n
        t = time_ns(); ode.f(du, u, ode.p, 0.0); push!(ts, (time_ns() - t) / 1e3)
    end
    minimum(ts), median(ts)
end
function bench_solve(ode, cb, steps)
    alg = CarpenterKennedy2N54(williamson_condition = false)   # integrator not threaded
    solve(ode, alg; dt = 1.0, save_everystep = false, callback = cb, maxiters = 10)
    t = @elapsed sol = solve(ode, alg; dt = 1.0, save_everystep = false, callback = cb, maxiters = steps)
    t / sol.stats.naccept * 1e6
end
function measure(elixir, level)
    semi, solver, cb = Main.semi, Main.solver, Main.stepsize_callback
    ode2 = semidiscretize(semi, (0.0, 1e6))
    rmin, rmed = bench_rhs(ode2, 200)
    step = bench_solve(ode2, CallbackSet(cb), 200)
    @printf("%s,%d,%s,%d,%d,%.1f,%.1f,%.1f\n", variant, Threads.nthreads(), basename(elixir), level,
            nelements(solver, semi.cache), rmin, rmed, step)
    flush(stdout)
end
println("variant,threads,elixir,level,elements,rhs_min_us,rhs_median_us,step_us")
for (elixir, level) in CASES
    path = joinpath(examples_dir(), elixir)
    redirect_stdout(devnull) do
        trixi_include(Main, path; initial_refinement_level = level, tspan = (0.0, 1e-6))
    end
    # trixi_include defined `semi` and friends in a newer world.
    Base.invokelatest(measure, elixir, level)
end

using ReplicatingLoops
using Test
using Base.Threads: nthreads, @spawn

# Atomic counters, so an element run twice at once is still counted twice.
tally(n) = [Threads.Atomic{Int}(0) for _ in 1:n]
hit!(h, i) = (Threads.atomic_add!(h[i], 1); nothing)
once(h) = all(x -> x[] == 1, h)

# Each element must be visited exactly once.
function counts(n; kw...)
    h = tally(n)
    pforeach(i -> hit!(h, i), 1:n; kw...)
    return [x[] for x in h]
end

module MyOps
max(a, b) = a > b ? a : b
end

@testset "ReplicatingLoops" begin
    @info "threads" nthreads(:default) nthreads(:interactive) Threads.threadpool()

    @testset "every element once" begin
        for n in (0, 1, 2, 3, 7, 64, 1000, 100_003)
            for ntasks in (1, 2, 3, 8, 64)
                @test all(==(1), counts(n; ntasks))
            end
            @test all(==(1), counts(n))
        end
    end

    @testset "collections" begin
        A = zeros(Int, 3, 4, 5)
        pforeach(eachindex(A)) do i
            A[i] += i
        end
        @test A == reshape(1:60, 3, 4, 5)

        seen = zeros(Int, 3, 4)
        pforeach(CartesianIndices(seen)) do I
            seen[I] += 1
        end
        @test all(==(1), seen)

        v = collect(1:100)
        out = zeros(Int, 100)
        pforeach(view(v, 2:2:100)) do x
            out[x] = x
        end
        @test out == [iseven(i) ? i : 0 for i in 1:100]

        out .= 0
        pforeach(enumerate(10:10:500)) do (i, x)
            out[i] = x
        end
        @test out[1:50] == 10:10:500
    end

    @testset "@pfor" begin
        y = zeros(100)
        x = collect(1.0:100.0)
        @pfor for i in eachindex(y)
            y[i] = 2x[i]
        end
        @test y == 2x

        y .= 0
        @pfor ntasks = 2 for (i, xi) in enumerate(x)
            y[i] = xi + 1
        end
        @test y == x .+ 1

        @test_throws ArgumentError macroexpand(@__MODULE__, :(@pfor 1 + 1))
        nested = quote
            @pfor for i in 1:2, j in 1:2
            end
        end
        @test_throws ArgumentError macroexpand(@__MODULE__, nested)
    end

    @testset "@pfor reductions and continue" begin
        x = rand(100_003)
        for nt in (1, 2, 8, 64)
            s = 0.0; m = -Inf; lo = Inf; c = 0
            @pfor ntasks = nt reduction = ((+, s), (max, m), (min, lo), (+, c)) for v in x
                v < 0.25 && continue
                s += v
                m = max(m, v)
                lo = min(lo, v)
                c += 1
            end
            @test s ≈ sum(v for v in x if v >= 0.25)
            @test m == maximum(x) && lo == minimum(v for v in x if v >= 0.25)
            @test c == count(>=(0.25), x)
        end
        # The value before the loop is part of the result, and an empty loop keeps it.
        t = 10
        @pfor reduction = (+, t) for i in 1:1000
            t += i
        end
        @test t == 10 + sum(1:1000)
        e = 7
        @pfor reduction = (*, e) for i in 1:0
            e *= 2
        end
        @test e == 7
        # The loop variable is local to the loop, as in a plain `for`.
        i = -1
        @pfor for i in 1:10
        end
        @test i == -1
        bad_option = quote
            @pfor minbatch = 10 for i in 1:2
            end
        end
        bad_reduction = quote
            @pfor reduction = (+, 1) for i in 1:2
            end
        end
        @test_throws ArgumentError macroexpand(@__MODULE__, bad_option)
        @test_throws ArgumentError macroexpand(@__MODULE__, bad_reduction)
        @test_throws ArgumentError ReplicatingLoops.neutral(-, 1.0)
        # Another package's `max` is recognised by its name, as Polyester does.
        @test ReplicatingLoops.neutral(MyOps.max, 1.0) == -Inf
        @test ReplicatingLoops.neutral(MyOps.max, 1) == typemin(Int)
    end

    @testset "exceptions" begin
        # Thrown from whichever task gets the bad chunk.
        for n in (1, 10, 10_000), bad in (1, n ÷ 2 + 1, n)
            e = try
                pforeach(i -> i == bad && error("bad $i"), 1:n)
                nothing
            catch err
                err
            end
            @test e isa CompositeException
            @test length(e.exceptions) == 1
            @test e.exceptions[1] isa CapturedException
            @test e.exceptions[1].ex == ErrorException("bad $bad")
        end
        # Every chunk throws: still one exception, and the loop returns.
        @test_throws CompositeException pforeach(i -> error("x"), 1:1000)
        # A failed loop stops handing out chunks.
        ran = Threads.Atomic{Int}(0)
        try
            pforeach(1:10_000; ntasks = 1) do i
                Threads.atomic_add!(ran, 1)
                i == 10 && error("stop")
            end
        catch
        end
        @test ran[] == 10
    end

    @testset "nested" begin
        n = 200
        hits = tally(n * n)
        pforeach(1:n) do j
            pforeach(1:n) do i
                hit!(hits, (j - 1) * n + i)
            end
        end
        @test once(hits)
    end

    @testset "concurrent loops" begin
        ntask = 4 * max(nthreads(), 2)
        results = Vector{Bool}(undef, ntask)
        @sync for t in 1:ntask
            @spawn begin
                ok = true
                for n in (10, 100, 5000)
                    ok &= all(==(1), counts(n))
                end
                results[t] = ok
            end
        end
        @test all(results)
    end

    @testset "slow chunks make the caller block" begin
        hits = tally(16)
        pforeach(1:16) do i
            sleep(0.02)
            hit!(hits, i)
        end
        @test once(hits)
    end

    # Long enough loops that helpers start.
    busy(ns) = (t = time_ns(); while time_ns() - t < ns; end)

    @testset "helpers" begin
        tids = zeros(Int, 2000)
        mark = i -> (busy(5_000); tids[i] = Threads.threadid())
        # The first call may finish while helper code is still compiling.
        pforeach(mark, 1:2000)
        tids .= 0
        pforeach(mark, 1:2000)
        @test all(>(0), tids)
        nthreads(:default) > 1 && @test length(unique(tids)) > 1

        # Costs that grow with the index: early timing underestimates the rest.
        hits = tally(400)
        pforeach(1:400) do i
            busy(100 * i)
            hit!(hits, i)
        end
        @test once(hits)

        # The error comes from the end of the loop, usually run by a helper.
        for _ in 1:20
            e = try
                pforeach(i -> (busy(2_000); i == 1000 && error("late")), 1:1000)
                nothing
            catch err
                err
            end
            @test e isa CompositeException && e.exceptions[1].ex == ErrorException("late")
        end

        hits2 = tally(64 * 64)
        pforeach(1:64) do j
            pforeach(1:64) do i
                busy(2_000)
                hit!(hits2, (j - 1) * 64 + i)
            end
        end
        @test once(hits2)
    end

    @testset "blocks" begin
        for n in (1000, 100_003), cost in (0, 1_000)
            hits = tally(n)
            pforeach(1:n) do i
                cost > 0 && busy(cost)
                hit!(hits, i)
            end
            @test once(hits)
        end
        # Uneven cost: blocks finish at different times and tasks help others.
        hits = tally(400)
        pforeach(1:400) do i
            busy(100 * i)
            hit!(hits, i)
        end
        @test once(hits)

        # Same blocks on the same threads each time, once helpers are compiled.
        tids = zeros(Int, 4000)
        mark = i -> (busy(1_000); tids[i] = Threads.threadid())
        # The first calls may finish while helper code is still compiling.
        t0 = time()
        while time() - t0 < 1
            pforeach(mark, 1:4000)
        end
        # On a loaded machine one pair of calls can land differently, so take the
        # best of five; random placement would keep about 1 in nthreads.
        same = 0
        for _ in 1:5
            first_run = copy(tids)
            pforeach(mark, 1:4000)
            same = max(same, count(tids .== first_run))
        end
        if nthreads(:default) > 1
            @test length(unique(tids)) > 1
            @test same > length(tids) ÷ 4
        end

        for _ in 1:20
            e = try
                pforeach(i -> (busy(2_000); i == 1000 && error("late")), 1:1000)
                nothing
            catch err
                err
            end
            @test e isa CompositeException && e.exceptions[1].ex == ErrorException("late")
        end

        hits2 = tally(64 * 64)
        pforeach(1:64) do j
            pforeach(1:64) do i
                busy(2_000)
                hit!(hits2, (j - 1) * 64 + i)
            end
        end
        @test once(hits2)

        out = zeros(Int, 1000)
        @pfor ntasks = 4 for i in 1:1000
            out[i] = i
        end
        @test out == 1:1000
    end

    @testset "few long iterations" begin
        # As many iterations as threads: a watcher starts helpers while the
        # caller is still in its first iteration, so they all start together.
        for n in (2, min(nthreads(:default), 8))
            n >= 2 && nthreads(:default) >= n || continue
            starts = zeros(UInt64, n)
            t0 = time_ns()
            pforeach(1:n) do i
                starts[i] = time_ns() - t0
                busy(30_000_000)
            end
            @test maximum(starts) - minimum(starts) < 20_000_000
        end
        # An error in the caller's first iteration stops the watcher's helpers.
        if nthreads(:default) >= 2
            for _ in 1:20
                e = try
                    pforeach(i -> (i == 1 ? (busy(50_000); error("first")) : busy(50_000)), 1:2)
                    nothing
                catch err
                    err
                end
                @test e isa CompositeException && e.exceptions[1].ex == ErrorException("first")
            end
            @test all(==(1), counts(2; ntasks = 2))
        end
    end

    @testset "other tasks run during a long loop" begin
        if nthreads(:default) < 2
            @test_skip "needs two threads"
        else
            # A loop that keeps every default thread busy for about 500 ms, started
            # from the default pool, and a task that asks to run 150 ms in. Without
            # yielding it waited 300 ms; with it, 8 ms.
            n = 200 * nthreads(:default)
            loop = Threads.@spawn :default pforeach(i -> busy(2_000_000), 1:n)
            sleep(0.15)
            t0 = time_ns()
            started = fetch(Threads.@spawn :default time_ns())
            @test (started - t0) / 1e6 < 100
            wait(loop)
        end
    end

    @testset "interrupted caller waits for running chunks" begin
        if nthreads(:default) < 2
            @test_skip "needs two threads"
        else
            # The first chunk a helper runs blocks on `gate` until the test opens it.
            st = (gate = Ref(Threads.Event()), held = Threads.Atomic{Bool}(false),
                  caller = Ref(0), ran = Threads.Atomic{Int}(0))
            body = function (i)
                busy(5_000)
                if Threads.threadid() != st.caller[] && !Threads.atomic_xchg!(st.held, true)
                    wait(st.gate[])
                end
                Threads.atomic_add!(st.ran, 1)
            end
            run_in_task(at_throw) = Threads.@spawn begin
                st.caller[] = Threads.threadid()
                try
                    pforeach(body, 1:2000)
                catch
                    at_throw[] = st.ran[]
                    rethrow()
                end
            end
            # Warm up the same body with the gate open, so helpers are compiled.
            for _ in 1:5
                st.gate[] = Threads.Event(); notify(st.gate[]); st.held[] = false
                wait(run_in_task(Ref(0)))
            end
            st.gate[] = Threads.Event(); st.held[] = false; st.ran[] = 0
            at_throw = Ref(-1)
            t = run_in_task(at_throw)
            # The caller is waiting once a helper holds a chunk and nothing else runs.
            t0 = time(); last = -1
            while time() - t0 < 30 && !(st.held[] && st.ran[] == last)
                last = st.ran[]
                sleep(0.1)
            end
            if !st.held[]
                notify(st.gate[]); wait(t)
                @test_skip "no helper ran"
            elseif t.queue === nothing
                # Waiting on an Event does not leave the task in a Condition queue
                # on this Julia, so the test cannot interrupt the wait safely.
                notify(st.gate[]); wait(t)
                @test_skip "cannot inject an interrupt here"
            else
                schedule(t, InterruptException(); error = true)
                sleep(0.05)
                notify(st.gate[])
                e = try
                    wait(t)
                    nothing
                catch err
                    err
                end
                @test e isa TaskFailedException && e.task.exception isa InterruptException
                sleep(0.05)
                @test at_throw[] == st.ran[] == 2000
            end
        end
    end

    @testset "limits" begin
        # Block boundaries must not overflow for huge lazy ranges.
        @test_throws ArgumentError pforeach(identity, 1:typemax(Int); ntasks = 4)
        e = try
            pforeach(i -> i > 1 && error("x"), 1:3_000_000_000_000_000_000 ÷ 8; ntasks = 4)
            nothing
        catch err
            err
        end
        @test e isa CompositeException && e.exceptions[1].ex == ErrorException("x")
        # The predicted work of a huge loop must not overflow the helper count.
        e = try
            pforeach(i -> i == 1 ? sleep(0.002) : error("second"), 1:10^18; ntasks = 1)
            nothing
        catch err
            err
        end
        @test e isa CompositeException && e.exceptions[1].ex == ErrorException("second")
    end

    @testset "many small loops" begin
        acc = zeros(Int, 64)
        for _ in 1:20_000
            pforeach(i -> (acc[i] += 1), 1:64)
        end
        @test all(==(20_000), acc)
    end
end

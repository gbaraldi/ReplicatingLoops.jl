module ReplicatingLoops

using Base.Threads: @spawn, nthreads, threadpool, threadid

export pforeach, @pfor

# Timing constants, in nanoseconds.
const MEASURE_NS = 1_000     # chunks shorter than this are too noisy to time
const HEARTBEAT_NS = 5_000   # a task starts at most one helper per this much work
const MIN_WORK_NS = 10_000   # least work per task worth starting a helper for
const CHUNK_NS = 20_000      # target length of one chunk
const SPIN_NS = 20_000       # how long the caller spins before blocking
const PENDING = 8           # helpers started but not running yet, plus 2 per running one

const CLOSED = typemax(Int) >> 1  # `next` value once nothing more is handed out

# In affinity mode the loop is cut into blocks, kept in one flat array so that
# cutting needs one allocation: block i takes STRIDE entries from STRIDE(i - 1),
# holding its counter (the last iteration handed out, on a cache line of its
# own), its last iteration and its thread; after the blocks comes a table from
# thread id to block.
const STRIDE = 8
const NO_BLOCKS = Int[]

@inline bhi(d::Vector{Int}, i::Int) = @inbounds d[STRIDE * (i - 1) + 2]
@inline bnext(d::Vector{Int}, i::Int) =
    GC.@preserve d unsafe_load(pointer(d, STRIDE * (i - 1) + 1), :monotonic)
@inline bclaim!(d::Vector{Int}, i::Int, k::Int) =
    GC.@preserve d Base.unsafe_modify!(pointer(d, STRIDE * (i - 1) + 1), +, k, :monotonic)[2]
@inline bclose!(d::Vector{Int}, i::Int) =
    GC.@preserve d Base.unsafe_swap!(pointer(d, STRIDE * (i - 1) + 1), CLOSED, :sequentially_consistent)

# The loop body over a range of positions. Only this is compiled for each body
# type; the scheduling code below works on any `Loop` and calls the body once
# per chunk, so a new loop body does not recompile it.
struct Body{F,A}
    f::F
    xs::A
end

# The range a task runs next. Each task reuses one, so the dynamic call to the
# body passes a reference instead of boxing two integers every chunk.
mutable struct Chunk
    lo::Int
    hi::Int
end

function (b::Body)(c::Chunk)
    f, xs = b.f, b.xs
    off = firstindex(xs) - 1
    for k in c.lo:c.hi
        f(@inbounds xs[off + k])
    end
    return nothing
end

mutable struct Loop
    @atomic next::Int                   # iterations handed out so far
    const pad::NTuple{7,Int}            # keep `next` on its own cache line
    @atomic left::Int                   # iterations not finished yet
    @atomic helpers::Int                # helper tasks started
    @atomic target::Int                 # helper tasks wanted
    @atomic running::Int                # helper tasks that have started running
    @atomic ns_per_iter::Float64        # time per iteration, for new helpers
    @atomic event::Union{Nothing,Threads.Event}  # set if the caller blocks
    @atomic err::Union{Nothing,CapturedException}
    const body::Any                     # a Body, called once per chunk with a Chunk
    const n::Int
    const maxhelpers::Int
    const affinity::Bool
    blocks::Vector{Int}                 # set before the first helper starts
    nb::Int                             # number of blocks, 0 until then
end

# State for one parallel loop. The caller starts by taking ranges of iterations
# from `next` alone. Without affinity, helpers take from `next` too. With
# affinity, the caller cuts the loop into blocks just before it starts the
# first helper, and from then on every task takes from its own block first.
#
# Ordering: `next` and the block counters only hand out ranges, so claims are
# monotonic. Results are published through `left`: each task subtracts what it
# claimed (a seq_cst RMW, so a release), and the caller sees 0 with an acquire
# load or RMW. `event` and `left` form a store-then-load handshake on both
# sides, which needs seq_cst so the caller and the last task cannot both miss
# each other. Everything the caller writes before starting a helper, including
# `blocks`, is published by `schedule` when it starts a helper.
Loop(body::Body, n::Int, maxhelpers::Int, affinity::Bool) =
    Loop(0, ntuple(_ -> 0, 7), n, 0, 0, 0, 0.0, nothing, nothing,
         body, n, maxhelpers, affinity, NO_BLOCKS, 0)

# Every heartbeat, raise the number of helpers wanted to what the work left
# would keep busy, MIN_WORK_NS each (in affinity mode, first cut the blocks:
# one owner per block). Returns the time of this check.
function maybe_raise!(r::Loop, est::Float64, left::Int, now::UInt64, last::UInt64)
    now - last >= HEARTBEAT_NS || (r.affinity && r.nb == 0) || return last
    want = min(r.maxhelpers, floor(Int, left * est / MIN_WORK_NS) - 1)
    want > (@atomic :monotonic r.target) || return now
    if r.affinity && r.nb == 0
        split!(r, left * est) || return now
        want = max(want, r.nb - 1)
    end
    # New helpers size their first chunk from this.
    @atomic :monotonic r.ns_per_iter = est
    raise_target!(r, want)
    return now
end

function raise_target!(r::Loop, want::Int)
    t = @atomic :monotonic r.target
    while want > t
        t, ok = @atomicreplace r.target t => want
        ok && break
    end
end

# Start helpers until as many as wanted have been started. Every task does this
# before each chunk, so starting helpers is shared out: when a new helper takes
# long to start running, the tasks already running start many before it does;
# when it starts quickly, it takes over starting the rest. Greedy cooperative
# wake-up is the optimal shape for this (Karp, Sahay, Santos and Schauser,
# "Optimal broadcast and summation in the LogP model", SPAA 1993).
function spawn_wanted!(r::Loop)
    while true
        h = @atomic :monotonic r.helpers
        h < (@atomic :monotonic r.target) || return
        # Helpers started but not yet running: on a busy machine they would
        # only find the loop done, so stop there (as oneTBB's slack does).
        h - (@atomic :monotonic r.running) < PENDING + 2 * (@atomic :monotonic r.running) || return
        (@atomicreplace r.helpers h => h + 1).success || continue
        @spawn :default helper!(r, h + 1)
    end
end

# Aim for CHUNK_NS, grow at most 2x per chunk, and once helpers run take at
# most half of an even share of what is left, so the last chunks finish close
# together. Never go below MEASURE_NS worth of iterations.
function chunk_size(r::Loop, est::Float64, k::Int, left::Int)
    h = min(@atomic(:monotonic, r.helpers), r.maxhelpers)
    want = min(CHUNK_NS / est, 2.0 * k)
    h > 0 && (want = min(want, left / (2 * (h + 1))))
    return floor(Int, clamp(max(want, MEASURE_NS / est), 1, left))
end

# Run iterations until none are left and return how many this task claimed.
#
# The caller has no timing yet, so it starts with one iteration and grows chunks
# 4x until it has run for MEASURE_NS; timing shorter chunks would mostly measure
# the timer. It also waits a heartbeat before starting a helper, so loops shorter
# than that never spawn. Helpers start from the caller's timing. From then on
# every task uses the latest time per iteration to size its chunks and to decide
# whether to start a helper.
function work!(r::Loop, caller::Bool, helper::Int = 0)
    n = r.n
    claimed = 0
    est = caller ? 0.0 : @atomic :monotonic r.ns_per_iter
    k = est > 0 ? typemax(Int) >> 2 : 1   # capped by chunk_size before use
    t0 = t = last = time_ns()
    c = Chunk(0, 0)
    home = 0   # affinity: where this task starts; `j` counts the blocks it has finished
    own = false
    j = 0
    try
        while true
            if est > 0
                if r.nb == 0
                    left = n - (@atomic :monotonic r.next)
                    left > 0 || break
                else
                    # A shared count of what is left would cost a contended
                    # add per chunk; estimate it from the block this task is in.
                    home == 0 && ((home, own) = home_block(r, helper))
                    j = skip_empty(r, home, j)
                    j < r.nb || break
                    left = blocks_left(r, home, j)
                    left == 0 && continue   # emptied meanwhile; look again
                end
                if !caller && claimed == 0 && left * est >= MIN_WORK_NS
                    # Each new helper asks for two more while work is left, so
                    # the number of helpers can double like a tree even when
                    # early iterations made the work look small.
                    raise_target!(r, min(r.maxhelpers, 2helper + 1))
                end
                last = maybe_raise!(r, est, left, t, last)
                spawn_wanted!(r)
                k = chunk_size(r, est, k, left)
            end
            if r.nb > 0
                home == 0 && ((home, own) = home_block(r, helper))
                lo, hi, j = claim_block!(r, home, own, j, k, est > 0 ? max(floor(Int, MEASURE_NS / est), 1) : 1)
                lo > hi && break
            elseif (@atomic :monotonic r.helpers) == 0
                # Only the caller exists until it starts a helper, and starting
                # one publishes `next`, so a plain store will do here; a locked
                # add would wait for this chunk's stores to drain.
                lo = (@atomic :monotonic r.next) + 1
                hi = min(lo + k - 1, n)
                lo > n && break
                @atomic :monotonic r.next = hi
            else
                hi = @atomic :monotonic r.next += k
                lo = hi - k + 1
                lo > n && break
                hi = min(hi, n)
            end
            claimed += hi - lo + 1
            c.lo = lo
            c.hi = hi
            r.body(c)
            now = time_ns()
            if est > 0
                # A short chunk's time is mostly overhead; keep the last estimate.
                now - t >= MEASURE_NS && (est = (now - t) / (hi - lo + 1))
            elseif now - t0 >= MEASURE_NS
                est = (now - t0) / claimed
            else
                k *= 4
            end
            t = now
        end
    catch e
        claimed += cancel!(r, e, catch_backtrace())
    end
    return claimed
end

function helper!(r::Loop, i::Int)
    @atomic :monotonic r.running += 1
    claimed = work!(r, false, i)
    claimed > 0 && finish!(r, claimed)
    return nothing
end

# Affinity mode. Called by the caller, while it is still the only task, just
# before it starts the first helper. Cuts the loop into equal blocks, one per
# MIN_WORK_NS of predicted work and at most one per thread. A loop that runs
# repeatedly then gets the same blocks every time, and each one is run by the
# same thread, so its data is still in that thread's cache. Block 1 belongs to
# the caller's thread, the others to default-pool threads in order. Iterations
# the caller already ran count as handed out. Returns false if there is only
# one thread to use.
function split!(r::Loop, work_left::Float64)
    most = min(r.maxhelpers + 1, default_ntasks())
    most >= 2 || return false
    me = threadid()
    pool = Threads.threadpooltids(:default)
    nb = min(clamp(floor(Int, work_left / MIN_WORK_NS), 2, most), 1 + count(!=(me), pool))
    d = zeros(Int, STRIDE * nb + max(me, maximum(pool)))
    d[3] = me
    i = 1
    for tid in pool
        i == nb && break
        tid == me && continue
        i += 1
        d[STRIDE * (i - 1) + 3] = tid
    end
    n = r.n
    done = @atomic :monotonic r.next
    for i in 1:nb
        b = STRIDE * (i - 1)
        hi = Int(div(widemul(i, n), nb))
        d[b + 1] = clamp(done, Int(div(widemul(i - 1, n), nb)), hi)
        d[b + 2] = hi
        d[STRIDE * nb + d[b + 3]] = i
    end
    r.blocks = d
    r.nb = nb
    @atomic r.next = CLOSED
    return true
end

# Where a task starts taking iterations, and whether it owns that block. A task
# owns the block of the thread it runs on. Helpers are not pinned, so one that
# lands on a thread without a block owns block i + 1 for the i-th helper, which gives each block an owner as long as there are as
# many helpers as blocks. Any further helper, started because the loop turned
# out longer than first measured, owns nothing and only helps.
function home_block(r::Loop, i::Int)
    me = threadid()
    nb = r.nb
    at = STRIDE * nb + me
    b = at <= length(r.blocks) ? r.blocks[at] : 0
    b > 0 && return b, true
    return mod1(i + 1, nb), i + 1 <= nb
end

# Rough count of iterations left: what is left in the block this task is on,
# times the blocks it has not been through yet.
function blocks_left(r::Loop, home::Int, j::Int)
    nb = r.nb
    j < nb || return 0
    i = mod1(home + j, nb)
    return max(bhi(r.blocks, i) - bnext(r.blocks, i), 0) * (nb - j)
end

# Move past blocks with nothing left, so estimates come from one that has work.
function skip_empty(r::Loop, home::Int, j::Int)
    nb = r.nb
    while j < nb
        i = mod1(home + j, nb)
        bhi(r.blocks, i) > bnext(r.blocks, i) && return j
        j += 1
    end
    return j
end

# Take up to `k` iterations from the home block, or once it is empty from the
# next blocks in turn (`j` counts the empty ones). From a block it does not own,
# a task takes about half of what is left, so the owner, if it shows up late,
# still gets some, but at least `kmin` (MEASURE_NS of work): halving what is
# left again and again would end in chunks of a few iterations, and every chunk
# boundary costs, most of all in loops that stream through memory. Returns
# `(lo, hi, j)`, with `lo > hi` when nothing is left.
function claim_block!(r::Loop, home::Int, own::Bool, j::Int, k::Int, kmin::Int)
    d = r.blocks
    nb = r.nb
    while j < nb
        i = mod1(home + j, nb)
        bh = bhi(d, i)
        rest = bh - bnext(d, i)
        if rest > 0
            kk = j == 0 && own ? k : min(k, max(cld(rest, 2), kmin))
            hi = bclaim!(d, i, kk)
            lo = hi - kk + 1
            lo <= bh && return lo, min(hi, bh), j
        end
        j += 1
    end
    return 1, 0, j
end

# After an error, record it and stop handing out iterations. Returns how many
# were never handed out; they count as done.
function cancel!(r::Loop, e, bt)
    @atomicreplace r.err nothing => CapturedException(e, bt)
    unclaimed = max(r.n - (@atomicswap r.next = CLOSED), 0)
    for i in 1:r.nb
        unclaimed += max(bhi(r.blocks, i) - bclose!(r.blocks, i), 0)
    end
    return unclaimed
end

function finish!(r::Loop, claimed::Int)
    if (@atomic r.left -= claimed) == 0
        ev = @atomic r.event
        ev === nothing || notify(ev)
    end
end

# Wait for the iterations other tasks are still running. Spin briefly, since
# they usually finish soon after the caller runs out of work, then block.
function wait_done(r::Loop)
    t0 = time_ns()
    while time_ns() - t0 < SPIN_NS
        (@atomic r.left) == 0 && return
        ccall(:jl_cpu_pause, Cvoid, ())
        GC.safepoint()
    end
    wait(event!(r))
end

# The event the last task notifies. Stored before `left` is checked again, so
# the caller and the last task cannot miss each other.
function event!(r::Loop)
    ev = @atomic r.event
    if ev === nothing
        ev = Threads.Event()
        @atomic r.event = ev
    end
    (@atomic r.left) == 0 && notify(ev)
    return ev
end

# The caller was interrupted while waiting. Stop handing out iterations and
# wait for the chunks still running, so that no iteration runs after
# `pforeach` has returned. Runs with ^C deferred; other exceptions thrown into
# the wait are ignored until the chunks are done.
function abort!(r::Loop, e, bt)
    unclaimed = cancel!(r, e, bt)
    (@atomic r.left -= unclaimed) == 0 && return
    ev = event!(r)
    while (@atomic r.left) != 0
        try
            wait(ev)
        catch
            Libc.systemsleep(1e-4)
        end
    end
end

# The caller runs iterations too, so a caller outside the default pool adds one.
default_ntasks() = nthreads(:default) + (threadpool() === :default ? 0 : 1)

"""
    pforeach(f, xs; ntasks, affinity = false)

Call `f(x)` for each element `x` of `xs`, using up to `ntasks` tasks.

The calling task starts on `xs` right away and times its iterations. After
every 5 µs of work, a task starts one helper task if every task, the new one
included, would still get at least 10 µs of the predicted work left (time per
iteration times iterations left). Helpers do the same, so loops shorter than
5 µs run on the caller alone and long ones spread to all threads within a few
wake-ups. Chunks are sized from the same timing.

With `affinity = true`, the caller cuts the loop into equal blocks, one per
10 µs of predicted work up to one per thread, just before it starts the first
helper. Every task takes iterations from its own block first, then helps with
the others, so a loop that runs repeatedly over the same memory keeps each
piece on the same core from call to call. Helpers start by the same rule as
without affinity.

`ntasks` defaults to the number of threads in the default pool, plus one when
the caller runs outside it. If `f` throws, no further iterations are started
and a `CompositeException` is thrown once the running ones finish.
"""
function pforeach(f, xs::AbstractArray; ntasks::Integer = default_ntasks(),
                  affinity::Bool = false)
    isempty(xs) && return nothing
    n = length(xs)
    maxhelpers = max(Int(ntasks), 1) - 1
    # Every task may add one claim past CLOSED after a failure; keep that in range.
    n <= CLOSED ÷ (maxhelpers + 1) ||
        throw(ArgumentError("pforeach supports at most $(CLOSED ÷ (maxhelpers + 1)) elements with ntasks = $ntasks"))
    r = Loop(Body(f, xs), n, maxhelpers, affinity)
    claimed = work!(r, true)
    if (@atomic r.left -= claimed) != 0
        # ^C is deferred except inside the wait itself, so a second ^C cannot
        # interrupt the cleanup of the first.
        disable_sigint() do
            try
                reenable_sigint(() -> wait_done(r))
            catch e
                abort!(r, e, catch_backtrace())
                rethrow()
            end
        end
    end
    err = @atomic r.err
    err === nothing || throw(CompositeException(Any[err]))
    return nothing
end

pforeach(f, itr; kw...) = pforeach(f, collect(itr); kw...)

"""
    @pfor [ntasks=n] [affinity=true] for x in xs
        ...
    end

Run the loop body for each element of `xs` in parallel. Same as
`pforeach(x -> body, xs; ntasks, affinity)`.
"""
macro pfor(args...)
    isempty(args) && throw(ArgumentError("@pfor needs a `for` loop"))
    loop = args[end]
    Meta.isexpr(loop, :for) || throw(ArgumentError("@pfor needs a `for` loop"))
    spec, body = loop.args
    Meta.isexpr(spec, :(=)) ||
        throw(ArgumentError("@pfor supports a single `for x in xs` loop"))
    var, itr = spec.args
    kws = map(args[1:end-1]) do a
        Meta.isexpr(a, :(=)) || throw(ArgumentError("expected `name=value`, got `$a`"))
        Expr(:kw, a.args[1], esc(a.args[2]))
    end
    f = Expr(:->, Expr(:tuple, var), body)
    return :(pforeach($(esc(f)), $(esc(itr)); $(kws...)))
end

# Compile the scheduling code into the package image, so a session's first loop
# only compiles its own body. The loops below start a helper even on one thread
# (ntasks = 2); yielding afterwards lets it run, which compiles the task that
# starts helpers too.
if ccall(:jl_generating_output, Cint, ()) == 1
    for f in (work!, helper!, maybe_raise!, raise_target!, spawn_wanted!, chunk_size, split!,
              home_block, blocks_left, skip_empty, claim_block!, cancel!, finish!, wait_done,
              event!, abort!)
        for m in methods(f)
            precompile(f, Tuple(m.sig.parameters[2:end]))
        end
    end
    let x = zeros(64)
        busy = i -> (t = time_ns(); while time_ns() - t < 2_000; end; x[i] = i)
        for affinity in (false, true)
            pforeach(busy, 1:64; ntasks = 2, affinity)
            yield()
        end
    end
end

end

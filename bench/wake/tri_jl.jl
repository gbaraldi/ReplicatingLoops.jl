# Triangle loop under pforeach, threads awake and asleep, as tri_tbb.cpp.
#   julia -tN,1 --project=. bench/wake/tri_jl.jl <n>
# prints: pforeach,<threads used>,<n>,serial_us,awake_us,asleep_us
using ReplicatingLoops, Base.Threads
function tri_el!(out, i)
    s = 0.0
    for j in 1:i; s += sin(j * 1e-3); end
    @inbounds out[i] = s
end
function main(n)
    out = zeros(n)
    f = i -> tri_el!(out, i)
    run() = pforeach(f, eachindex(out))
    serial() = (t = time_ns(); for i in eachindex(out); tri_el!(out, i); end; time_ns() - t)
    # Serial first, after 0.3 s of warm-up, so the core runs at full clock
    # (see tri_tbb.cpp).
    t0 = time(); while time() - t0 < 0.3; serial(); end
    ser = minimum(serial() for _ in 1:50)
    for _ in 1:2000; run(); end
    awake = minimum((t = time_ns(); run(); time_ns() - t) for _ in 1:300)
    asleep = minimum((Libc.systemsleep(0.002); t = time_ns(); run(); time_ns() - t) for _ in 1:200)
    r(x) = round(x / 1e3, digits = 1)
    println("pforeach,$(nthreads(:default) + 1),$n,$(r(ser)),$(r(awake)),$(r(asleep))")
end
main(parse(Int, ARGS[1]))

# A few cold triangle loops under pforeach with marker writes, for strace.
using ReplicatingLoops, Base.Threads
function tri_el!(out, i)
    s = 0.0
    for j in 1:i; s += sin(j * 1e-3); end
    @inbounds out[i] = s
end
out = zeros(300)
f = i -> tri_el!(out, i)
for _ in 1:200; pforeach(f, eachindex(out)); end
for k in 1:4
    Libc.systemsleep(0.02)
    ccall(:write, Cssize_t, (Cint, Ptr{UInt8}, Csize_t), 2, "MARK\n", 5)
    pforeach(f, eachindex(out))
    ccall(:write, Cssize_t, (Cint, Ptr{UInt8}, Csize_t), 2, "DONE\n", 5)
end

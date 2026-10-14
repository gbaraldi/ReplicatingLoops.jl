# Self time of a perf profile (after `perf inject --jit`) by category.
#   python3 categorize.py <perf.jit.data> [label]
import subprocess, sys, re, collections
data = sys.argv[1]; label = sys.argv[2] if len(sys.argv) > 2 else data
out = subprocess.run(["perf", "report", "-i", data, "--no-children", "--sort", "dso,sym", "--stdio",
                      "-F", "overhead,dso,sym", "--percent-limit", "0"], capture_output=True, text=True).stdout
SCHED = {"work!", "claim_block!", "spawn_wanted!", "maybe_raise!", "chunk_size", "skip_empty", "blocks_left",
         "split!", "finish!", "wait_done", "event!", "watch!", "helper!", "home_block", "raise_target!",
         "long_before", "remember!", "pforeach", "#pforeach", "cancel!", "abort!"}
cats = collections.Counter(); top = collections.defaultdict(collections.Counter)
for line in out.splitlines():
    m = re.match(r"\s*([\d.]+)%\s+(\S+)\s+\[(.)\]\s+(.*)", line)
    if not m: continue
    pct, dso, kind, sym = float(m.group(1)), m.group(2), m.group(3), m.group(4).strip()
    # Julia's mangled names: julia_claim_blockNOT._626.2 -> claim_block!
    base = sym.replace("NOT.", "!").replace("SUM.", "+")
    base = re.sub(r"^(j?julia_|jfptr_)", "", base)
    base = re.sub(r"(_\d+)?(\.\d+)?$", "", base)
    base = re.sub(r"\(.*$", "", base)
    if kind == "k" or dso.startswith("[kernel"):
        c = "kernel"
    elif dso.startswith("jitted") or sym.startswith("julia_") or sym.startswith("jfptr_"):
        if base in SCHED or base.lstrip("#") in SCHED:
            c = "ReplicatingLoops scheduler"
        elif re.search(r"axpy|tri_el|spin|Body|#\d+|sin", base):
            c = "loop body"
        elif re.search(r"poptask|^wait|yield|schedule|enq_work|multiq|task_done|Task|spawn|notify|trylock|^lock|unlock", base):
            c = "Julia scheduler (Base)"
        else:
            c = "other Julia code"
    elif "libjulia" in dso:
        c = "Julia runtime (C)"
    elif dso == "[vdso]":
        c = "clock reads (vdso)"
    elif "libc" in dso or "libm" in dso or "ld-linux" in dso:
        c = "libc/libm"
    else:
        c = "other: " + dso
    cats[c] += pct; top[c][sym] += pct
print(f"== {label}: self time by category")
for c, v in cats.most_common():
    syms = ", ".join(f"{s} {p:.1f}%" for s, p in top[c].most_common(3))
    print(f"  {v:5.1f}%  {c:28s} {syms}")

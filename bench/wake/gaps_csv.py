# Combine the 1M-element axpy idle-gap results of Julia 1.13 (oneTBB, Polyester,
# pforeach: bench/results/wake/axpy1m.csv) and nightly (ParkedWorkers.jl, the
# vc/parallel-for branch, pforeach: bench/results/compare/axpy1m-nightly.csv).
# Rows run with JULIA_THREAD_SLEEP_THRESHOLD=infinite carry a "Julia threads
# never sleep" label after the name, as " (...)" or, in older files, as an
# extra ", ..." field.
#   python3 bench/wake/gaps_csv.py > bench/results/wake/gaps.csv
import csv, os
R = os.path.join(os.path.dirname(__file__), "..", "results")
out = csv.writer(open(1, "w", closefd=False))
out.writerow(["key", "impl", "julia", "sleep", "mode", "us", "speedup"])
for path, julia in ((f"{R}/wake/axpy1m.csv", "1.13"), (f"{R}/compare/axpy1m-nightly.csv", "nightly")):
    rows = list(csv.reader(open(path)))[1:]
    for f in rows:
        never = "Julia threads never sleep" in ",".join(f[:2])
        if len(f) == 5:                     # "name, Julia threads never sleep" split on its comma
            f = [f[0], f[2], f[3], f[4]]
        impl, mode, us, speedup = f
        impl = impl.replace(" (Julia threads never sleep)", "").strip()
        lang = "C++" if impl.startswith("oneTBB") else julia
        sleep = "never" if never else "allowed"
        out.writerow([f"{impl}|{lang}|{sleep}|{mode}", impl, lang, sleep, mode, us, speedup])

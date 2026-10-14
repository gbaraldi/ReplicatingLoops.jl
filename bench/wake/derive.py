# Add row keys and speedups (own serial time / loop time) to the wake-up CSVs
# for the summary dashboard.
#   python3 bench/wake/derive.py bench/results/wake
import csv, sys
d = sys.argv[1]
sig = lambda x: float(f"{x:.3g}")
rows = list(csv.DictReader(open(f"{d}/tri.csv")))
with open(f"{d}/tri_summary.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["key", "impl", "threads", "n", "serial_us", "awake_us", "asleep_us", "awake_speedup", "asleep_speedup"])
    for r in rows:
        s, a, z = float(r["serial_us"]), float(r["awake_us"]), float(r["asleep_us"])
        w.writerow([f"{r['impl']}-{r['threads']}-{r['n']}", r["impl"], r["threads"], r["n"], r["serial_us"],
                    r["awake_us"], r["asleep_us"], sig(s / a), sig(s / z)])

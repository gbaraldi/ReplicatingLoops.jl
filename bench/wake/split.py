# Median split of each spawn: spawner call, spawn -> worker switched in on a
# CPU (kernel and hardware), switched in -> task body starts (Julia).
#   python3 split.py <spawns.csv> <switch-in lines from perf script> <label>
import bisect, collections, sys
spawns, switches, label = sys.argv[1:4]
ins = collections.defaultdict(list)
for l in open(switches):
    p = l.split(); ins[int(p[0])].append(int(round(float(p[1].rstrip(':')) * 1e9)))
for v in ins.values(): v.sort()
a, b, c, tot = [], [], [], []
for t0, t1, ts, tid in (tuple(map(int, l.split(','))) for l in open(spawns)):
    v = ins.get(tid, []); k = bisect.bisect_right(v, ts) - 1
    if k < 0 or v[k] < t0: continue
    a.append((t1 - t0) / 1e3); b.append((v[k] - t0) / 1e3); c.append((ts - v[k]) / 1e3); tot.append((ts - t0) / 1e3)
med = lambda x: round(sorted(x)[len(x) // 2], 1)
print(f"{label},{med(a)},{med(b)},{med(c)},{med(tot)}")

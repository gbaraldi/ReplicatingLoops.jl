# Turn the profile outputs in bench/results/profile into CSVs for the README
# and the dashboard: CPU time by category, wall-clock samples by function,
# cache fills per loop by source, and perf c2c HITM loads by function.
#   python3 bench/profile/to_csv.py <dir with the perf c2c *-full.txt reports>
import csv, re, os, sys, collections
D = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "results", "profile")
C2C = sys.argv[1] if len(sys.argv) > 1 else D

def sections(path):
    name, body = None, []
    for l in open(path):
        m = re.match(r"== (\S+)", l)
        if m:
            if name: yield name, body
            name, body = m.group(1).rstrip(":"), []
        else:
            body.append(l)
    if name: yield name, body

with open(f"{D}/cpu.csv", "w", newline="") as f:
    w = csv.writer(f); w.writerow(["key", "workload", "category", "percent", "top_symbols"])
    for name, body in sections(f"{D}/cpu.txt"):
        for l in body:
            m = re.match(r"\s+([\d.]+)%\s+(.{28})\s(.*)", l)
            if m and float(m.group(1)) >= 0.1:
                cat = m.group(2).strip()
                w.writerow([f"{name}|{cat}", name, cat, m.group(1), m.group(3).strip()[:160]])

with open(f"{D}/walltime.csv", "w", newline="") as f:
    w = csv.writer(f); w.writerow(["key", "workload", "where", "percent", "tasks", "samples"])
    for name, body in sections(f"{D}/walltime.txt"):
        head = next((l for l in body if l.startswith("wall-clock")), None)
        if not head: continue
        tasks, samples = re.search(r"of the (\d+) tasks.*?: (\d+)", head).groups()
        for l in body:
            m = re.match(r"\s+([\d.]+)%\s+(.*)", l)
            if m: w.writerow([f"{name}|{m.group(2).strip()}", name, m.group(2).strip(), m.group(1), tasks, samples])

SRC = {"local_l2": "own L2", "local_ccx": "own CCX's L3", "near_cache": "another CCX, same socket",
       "far_cache": "a cache on the other socket", "dram_io_near": "memory, same socket", "dram_io_far": "memory, other socket"}
with open(f"{D}/fills.csv", "w", newline="") as f:
    w = csv.writer(f); w.writerow(["key", "workload", "source", "fills_per_loop", "loops"])
    for name, body in sections(f"{D}/fills.txt"):
        loops = next((int(re.search(r": (\d+) loops", l).group(1)) for l in body if re.search(r": \d+ loops", l)), None)
        for l in body:
            p = l.strip().split(",")
            if len(p) > 2 and p[2].startswith("ls_dmnd_fills_from_sys."):
                src = p[2].split(".")[1]
                w.writerow([f"{name}|{src}", name, SRC.get(src, src), round(int(p[0]) / loops), loops])

OURS = {"work!", "claim_block!", "skip_empty", "bclaim!", "bnext", "spawn_wanted!", "finish!", "maybe_raise!",
        "blocks_left", "chunk_size", "helper!", "watch!", "wait_done", "event!", "split!", "raise_target!", "home_block"}
with open(f"{D}/c2c.csv", "w", newline="") as f:
    w = csv.writer(f); w.writerow(["key", "workload", "function", "hitm_percent", "lines", "in_package"])
    for wl in ("axpy1m", "tri300", "nested"):
        path = f"{C2C}/c2c-{wl}-full.txt"
        if not os.path.exists(path): continue
        txt = open(path).read()
        part = txt[txt.index("Shared Cache Line Distribution Pareto"):]
        hitm = collections.Counter(); lines = collections.defaultdict(set); cur = None; tot_line = {}
        for l in part.splitlines():
            m = re.match(r"\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(0x[0-9a-f]+)\s*$", l)
            if m:
                cur = m.group(7); tot_line[cur] = int(m.group(2)) + int(m.group(3)); continue
            m = re.match(r"\s+([\d.]+)%\s+([\d.]+)%\s+[\d.]+%\s+[\d.]+%\s+[\d.]+%\s+0x[0-9a-f]+\s+\S+\s+\d+\s+0x[0-9a-f]+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\[.\]\s+(\S+)", l)
            if m and cur:
                sym = m.group(3).replace("NOT.", "!")
                sym = re.sub(r"^(j?julia_)", "", sym); sym = re.sub(r"(_\d+)?(\.\d+)?$", "", sym)
                hitm[sym] += (float(m.group(1)) + float(m.group(2))) / 200 * tot_line[cur]; lines[sym].add(cur)
        tot = sum(hitm.values()) or 1
        for s, v in hitm.most_common():
            if 100 * v / tot >= 0.05 or s in OURS:
                w.writerow([f"{wl}|{s}", wl, s, round(100 * v / tot, 2), len(lines[s]), s in OURS])
print("wrote", D)

# FUTEX_WAKE calls per cold loop from `strace -f -tt -e trace=futex,write`
# output, between "MARK" and "DONE" marker writes; prints the median.
#   python3 count_futex.py <strace output> <label> <threads>
import re, statistics, sys
path, label, nt = sys.argv[1:4]
counts = []; cur = None
for l in open(path):
    if 'write(2, "MARK' in l: cur = 0; continue
    if 'write(2, "DONE' in l and cur is not None: counts.append(cur); cur = None; continue
    if cur is not None and re.search(r'futex\(\S+, FUTEX_WAKE', l) and 'resumed' not in l: cur += 1
print(f"{label},{nt},{int(statistics.median(counts[1:]))}")

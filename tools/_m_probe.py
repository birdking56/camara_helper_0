import re, glob, os
files = sorted(glob.glob(r"C:\Users\GREAT\Desktop\camara_helper_0\tools\uart_*.log"), key=os.path.getmtime)
f = files[-1]
print("log:", os.path.basename(f))
rows = []; words = {}
for line in open(f, encoding="utf-8", errors="replace"):
    m = re.match(r"DGC4\s+([SIWJGKPQRM])=([0-9A-F]{16})", line.strip())
    if not m: continue
    v = int(m.group(2), 16)
    words[m.group(1)] = [(v >> 48) & 0xFFFF, (v >> 32) & 0xFFFF, (v >> 16) & 0xFFFF, v & 0xFFFF]
    if m.group(1) == "M":
        rows.append(dict(words))
prev = None
for i, r in enumerate(rows):
    m0, m1, m2, m3 = r["M"]
    d = lambda k: 0 if prev is None else ((k - prev) & 0xFFFF)
    print("t=%2d job_fid=%5d alloc=%5d(+%d) release=%5d(+%d) drop=%5d(+%d) age=%4d frames (%.1f s)"
          % (i, m0, m1, d(m1), m2, d(m2), m3, d(m3), (m1 - m0) & 0xFFFF, ((m1 - m0) & 0xFFFF)/60.0))
    prev = r

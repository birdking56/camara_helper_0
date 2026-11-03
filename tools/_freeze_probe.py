import re
words = {}
rows = []
for line in open(r"tools\uart_freeze_probe.log", encoding="utf-8", errors="replace"):
    m = re.match(r"DGC3 ([SIWJGKPQR])=([0-9A-F]{16})", line.strip())
    if not m: continue
    lab, h = m.group(1), m.group(2)
    v = int(h, 16)
    words[lab] = [(v >> 48) & 0xFFFF, (v >> 32) & 0xFFFF, (v >> 16) & 0xFFFF, v & 0xFFFF]
    if lab == "R":
        rows.append(dict(words))
print("snapshots:", len(rows))
prev = None
for i, r in enumerate(rows):
    out = r["W"][3]; ins = r["W"][2]; jobs = r["J"][0]; blocks = r["J"][1]
    d_out = None if prev is None else (out - prev["W"][3]) & 0xFFFF
    d_in  = None if prev is None else (ins - prev["W"][2]) & 0xFFFF
    d_job = None if prev is None else (jobs - prev["J"][0]) & 0xFFFF
    print("t=%2d in=%04X(+%s) out=%04X(+%s) jobs=%d(+%s) blocks=%d slots=%02X cur_stripe=%d" % (
        i, ins, d_in, out, d_out, jobs, d_job, blocks, r["J"][3], r["G"][3] & 0x7F))
    prev = r

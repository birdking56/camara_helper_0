import re
rows = []
words = {}
for line in open(r"tools\uart_freeze_probe.log", encoding="utf-8", errors="replace"):
    m = re.match(r"DGC3 ([SIWJGKPQR])=([0-9A-F]{16})", line.strip())
    if not m: continue
    v = int(m.group(2), 16)
    words[m.group(1)] = [(v >> 48) & 0xFFFF, (v >> 32) & 0xFFFF, (v >> 16) & 0xFFFF, v & 0xFFFF]
    if m.group(1) == "R":
        rows.append(dict(words))
prev_cap = prev_wa = None
for i, r in enumerate(rows):
    cap = r["S"][2]; wa = r["W"][0]
    dc = None if prev_cap is None else ((cap - prev_cap) & 0xFFFF)
    dw = None if prev_wa is None else ((wa - prev_wa) & 0xFFFF)
    print("t=%2d cap=%5d (+%s) wa=%5d (+%s)" % (i, cap, dc, wa, dw))
    prev_cap, prev_wa = cap, wa

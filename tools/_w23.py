import re, glob, os
f = sorted(glob.glob(r"C:\Users\GREAT\Desktop\camara_helper_0\tools\uart_*.log"), key=os.path.getmtime)[-1]
print(os.path.basename(f))
w = {}
rows = []
for line in open(f, encoding="utf-8", errors="replace"):
    m = re.match(r"DGC[45]\s+([SIWJGKPQRMV])=([0-9A-F]{16})", line.strip())
    if not m: continue
    v = int(m.group(2),16); w[m.group(1)] = [(v>>48)&0xFFFF,(v>>32)&0xFFFF,(v>>16)&0xFFFF,v&0xFFFF]
    if m.group(1)=="M": rows.append(dict(w))
# 2026-11-02: W2/W3 are the upper halves of the 32-bit input/output RGB rolling
# sums again (the core_snap/fill_starts probes are gone - J2 carries the core
# state). This helper only exists to eyeball a capture by hand.
prev = None
for r in rows[-3:]:
    W2 = r["W"][2]; W3 = r["W"][3]
    d2 = "" if prev is None else (" in+%d" % (((W2 - prev["W"][2]) & 0xFFFF)))
    d3 = "" if prev is None else (" out+%d" % (((W3 - prev["W"][3]) & 0xFFFF)))
    print("in_rgb_sum[31:16]=%04X%s out_rgb_sum[31:16]=%04X%s | wa_frames=%d wa_aborts=%d | jobs=%d blocks=%d | M0=%d M1=%d M2=%d M3=%d" % (
      W2, d2, W3, d3, r["W"][0], r["W"][1], r["J"][0], r["J"][1],
      r["M"][0], r["M"][1], r["M"][2], r["M"][3]))
    prev = r

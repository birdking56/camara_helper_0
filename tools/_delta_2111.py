import re
p=r"C:\Users\GREAT\Desktop\camara_helper_0\tools\uart_20261102_211110.log"
rows=[]
for line in open(p,encoding='utf-8',errors='ignore'):
    m=re.match(r'DGC5 ([SIWJGKMPQRV])=([0-9A-Fa-f]{16})',line.strip())
    if not m: continue
    tag,hexs=m.group(1),m.group(2)
    w=[int(hexs[i:i+4],16) for i in range(0,16,4)]
    if tag=='J': rows.append({'jobs':w[0],'blocks':w[1]})
    elif tag=='V' and rows: rows[-1].update({'V0':w[0],'V1':w[1],'V2':w[2],'V3':w[3]})
    elif tag=='G' and rows: rows[-1].update({'uf':w[2]})
    elif tag=='M' and rows: rows[-1].update({'M0':w[0],'M1':w[1],'M2':w[2],'M3':w[3]})
prev=None
print(f"{'jobs':>5} {'dJ':>4} {'blocks':>6} {'V0':>5} {'dV0':>5} {'V1':>4} {'V2':>6} {'dV3':>5} {'uf':>5} {'duf':>4} {'M0':>6} {'dM1':>4} {'M3':>3}")
for r in rows:
    if prev is None:
        print(f"{r['jobs']:5d} {'-':>4} {r['blocks']:6d} {r.get('V0',0):5d} {'-':>5} {r.get('V1',0):4d} {r.get('V2',0):6d} {'-':>5} {r.get('uf',0):5d} {'-':>4} {r.get('M0',0):6d} {'-':>4} {r.get('M3',0):3d}")
    else:
        print(f"{r['jobs']:5d} {r['jobs']-prev['jobs']:4d} {r['blocks']:6d} {r.get('V0',0):5d} {r.get('V0',0)-prev.get('V0',0):5d} {r.get('V1',0):4d} {r.get('V2',0):6d} {r.get('V3',0)-prev.get('V3',0):5d} {r.get('uf',0):5d} {r.get('uf',0)-prev.get('uf',0):4d} {r.get('M0',0):6d} {r.get('M1',0)-prev.get('M1',0):4d} {r.get('M3',0):3d}")
    prev=r

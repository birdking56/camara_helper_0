import re,sys
p=r"C:\Users\GREAT\Desktop\camara_helper_0\tools\uart_20261102_203842.log"
rows=[]
for line in open(p,encoding='utf-8',errors='ignore'):
    m=re.match(r'DGC5 ([SIWJGKMPQRV])=([0-9A-Fa-f]{16})',line.strip())
    if not m: continue
    tag,hexs=m.group(1),m.group(2)
    w=[int(hexs[i:i+4],16) for i in range(0,16,4)]
    if tag=='J': rows.append({'jobs':w[0],'blocks':w[1]})
    elif tag=='V' and rows: rows[-1].update({'V0':w[0],'V1':w[1],'V2':w[2],'V3':w[3]})
    elif tag=='G' and rows: rows[-1].update({'uf':w[2]})
prev=None
print(f"{'jobs':>5} {'dJobs':>6} {'blocks':>6} {'V0':>5} {'dV0':>5} {'V1':>4} {'V2':>6} {'V3':>5} {'uf':>5} {'duf':>4}")
for r in rows:
    if prev is None:
        print(f"{r['jobs']:5d} {'-':>6} {r['blocks']:6d} {r.get('V0',0):5d} {'-':>5} {r.get('V1',0):4d} {r.get('V2',0):6d} {r.get('V3',0):5d} {r.get('uf',0):5d} {'-':>4}")
    else:
        dj=r['jobs']-prev['jobs']; duf=r.get('uf',0)-prev.get('uf',0)
        dv0=r.get('V0',0)-prev.get('V0',0)
        print(f"{r['jobs']:5d} {dj:6d} {r['blocks']:6d} {r.get('V0',0):5d} {dv0:5d} {r.get('V1',0):4d} {r.get('V2',0):6d} {r.get('V3',0):5d} {r.get('uf',0):5d} {duf:4d}")
    prev=r

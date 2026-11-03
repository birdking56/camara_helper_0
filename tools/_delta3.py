import re
p=r"C:\Users\GREAT\Desktop\camara_helper_0\tools\uart_20261102_220406.log"
rows=[]
for line in open(p,encoding='utf-8',errors='ignore'):
    m=re.match(r'DGC5 ([SIWJGKMPQRV])=([0-9A-Fa-f]{16})',line.strip())
    if not m: continue
    tag,hexs=m.group(1),m.group(2)
    w=[int(hexs[i:i+4],16) for i in range(0,16,4)]
    if tag=='J': rows.append({'jobs':w[0]})
    elif tag=='W' and rows: rows[-1].update({'wa':w[0],'ab':w[1]})
    elif tag=='M' and rows: rows[-1].update({'M0':w[0],'M1':w[1],'M2':w[2],'M3':w[3]})
prev=None
print(f"{'jobs':>5} {'dJ':>3} {'wa':>6} {'dwa':>4} {'ab':>4} {'M0':>6} {'dM0':>5} {'dM1':>4} {'dM2':>4} {'M3':>3}")
for r in rows:
    if prev is None:
        print(f"{r['jobs']:5d} {'-':>3} {r.get('wa',0):6d} {'-':>4} {r.get('ab',0):4d} {r.get('M0',0):6d} {'-':>5} {'-':>4} {'-':>4} {r.get('M3',0):3d}")
    else:
        print(f"{r['jobs']:5d} {r['jobs']-prev['jobs']:3d} {r.get('wa',0):6d} {r.get('wa',0)-prev.get('wa',0):4d} {r.get('ab',0):4d} {r.get('M0',0):6d} {(r.get('M0',0)-prev.get('M0',0))&0xffff:5d} {r.get('M1',0)-prev.get('M1',0):4d} {r.get('M2',0)-prev.get('M2',0):4d} {r.get('M3',0):3d}")
    prev=r


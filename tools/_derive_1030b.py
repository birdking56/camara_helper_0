P0=21118; P1=2384; P2=464; P3=89; Q0=16625; Q1=18124; Q2=326; Q3=2760
LSB=4096; F=171e6
jobs=30; blocks=4080
bps=jobs*blocks
print("blocks/s =", bps)
for name,lsb in [("fill_active",P0),("wait_beat",P1),("wait_row",P2),("wait_plan",P3),
                 ("fill_writes",Q0),("sample_active",Q1),("writer_stall",Q2),("sampler_stall",Q3)]:
    cyc=lsb*LSB
    per_blk=cyc/bps
    print("%-14s %8.2f ms/s   %7.1f cycles/block   %6.3f us/block" % (name, cyc/F*1000, per_blk, per_blk/F*1e9))
print()
print("phase estimate: %d blocks at %d us -> %.2f us/block -> job = %.2f ms" % (2680,11500,11500/2680,11500/2680*4080/1000))
print("frame period 16.667 ms -> 2 frames = %.3f ms -> %.1f jobs/s" % (2*16.667, 1000/(2*16.667)))
print()
print("after 2px/cycle writes: fill = %.1f cycles/block (writes %d -> %d records)"
      % ((P0*LSB/bps) - (561-289), 561, 289))
fill2 = (P0*LSB/bps) - (561-289)
print("  fill/block = %.1f, sample/block = %.1f -> block ~= max = %.2f us -> job = %.2f ms"
      % (fill2, Q1*LSB/bps, max(fill2, Q1*LSB/bps)/F*1e6, max(fill2, Q1*LSB/bps)*blocks/F*1000))

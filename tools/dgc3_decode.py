#!/usr/bin/env python3
"""dgc3_decode.py - decode the DGC3 board report and state a verdict.

Usage:
    python tools/dgc3_decode.py tools/uart_20261030_160000.log
    python tools/dgc3_decode.py --self-test

The report is nine lines of 25 characters per second:

    DGC3 <L>=<16 hex digits>          L = S I W J G K P Q R

Words 0..23 keep their DGC2 meaning (docs/DGC2串口协议_20261028.md); words
24..35 are the DGC3 performance report (docs/DGC3串口协议_20261030.md).

Scales:
    P line, Q line           1 LSB = 4096 proc cycles = 4095/171e6 s = 23.95 us
    R1, R2                   1 LSB = 4096 ddr cycles  = 32.77 us
    R0                       1 LSB = 128 native AR handshakes
    R3                       requests (0..8)

The decoder never guesses: it prints the raw decoded fields, the per-second
numbers, and only then a verdict whose rule is quoted. Fields that are
impossible (e.g. writes > fill active) are reported as inconsistencies.
"""

import sys
import re

PROC_HZ = 171_000_000.0
DDR_HZ = 125_000_000.0
PROC_LSB_US = 4096.0 / PROC_HZ * 1e6      # 23.95 us
DDR_LSB_US = 4096.0 / DDR_HZ * 1e6        # 32.77 us
JOBS_PER_REPORT_HINT = 30.0               # board baseline, 30 jobs/s

LINE_RE = re.compile(r"^DGC[345]\s+([SIWJGKPQRMV])=([0-9A-Fa-f]{16})\s*$")
LABELS = "SIWJGKPQRMV"
LABELS_REQUIRED = "SIWJGKPQR"   # M (DGC4) and V (DGC5) are optional for older logs


def starve_text(v2):
    """DGC5 V2 is the last latched starvation location, not an interval count."""
    if v2 == 0:
        return "zero is ambiguous: no event or starvation after stripe 0; compare G2"
    if (v2 >> 7) & 1:
        return "last starvation: stripe 0 missed the porch (latched history)"
    return "last starvation: stripe %d (latched history)" % (v2 & 0x7F)


class Snapshot:
    def __init__(self):
        self.words = {}

    def add(self, label, hexstr):
        v = int(hexstr, 16)
        # four 16-bit words, word 0 in the low half of the printed 64-bit value:
        # the reporter prints word0 first, so the printed string is
        # "w0 w1 w2 w3" as 16 hex digits -> parseInt gives w0 in bits 63..48.
        w = [
            (v >> 48) & 0xFFFF,
            (v >> 32) & 0xFFFF,
            (v >> 16) & 0xFFFF,
            v & 0xFFFF,
        ]
        self.words[label] = w

    def complete(self):
        return all(l in self.words for l in LABELS_REQUIRED)

    def w(self, label, i):
        return self.words[label][i]


def parse(path):
    snaps = []
    cur = Snapshot()
    raw = 0
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            m = LINE_RE.match(line)
            if not m:
                continue
            raw += 1
            label, hexstr = m.group(1), m.group(2)
            if label == "S" and cur.words:
                if cur.complete():
                    snaps.append(cur)
                cur = Snapshot()
            cur.add(label, hexstr)
    if cur.complete():
        snaps.append(cur)
    return snaps, raw


def pct(x, total):
    return 0.0 if total == 0 else 100.0 * x / total


def describe(s, prev=None):
    print("=" * 78)
    st = s.w("S", 0)
    print("S row  : status=%04X  T=%04X  cap_frames=%d  cap_aborted=%d" %
          (st, s.w("S", 1), s.w("S", 2), s.w("S", 3)))
    # DGC3 event latches (S[15:13]): a set bit means the event happened at least
    # once since board reset. This is the evidence the "no signal" / camera
    # unplug investigation needs, because a 1 Hz sample can miss a short event.
    ev = []
    if st & 0x8000:
        ev.append("PLL lock dropped")
    if st & 0x4000:
        ev.append("a domain reset re-asserted")
    if st & 0x2000:
        ev.append("MS7200 rx config done dropped")
    if ev:
        print("         event latches: " + "; ".join(ev))
    if (st & 0x1FFF) != 0x1FFD:
        print("         note: S[12:0] = %04X (1FFD expected with DDR/HDMI init and a pixel clock)"
              % (st & 0x1FFF))
    print("I row  : cap_rows=%d  pixclk=%.1f MHz  line_px=%d  frame_lines=%d" %
          (s.w("I", 0), s.w("I", 1) / 10.0, s.w("I", 2), s.w("I", 3)))
    print("W row  : wa_frames=%d  wa_aborts=%d  in_rgb_sum[31:16]=%04X  out_rgb_sum[31:16]=%04X"
          % (s.w("W", 0), s.w("W", 1), s.w("W", 2), s.w("W", 3)))
    # 2026-11-02: W2/W3 are the upper halves of the 32-bit input/output RGB rolling
    # sums again (see docs/DGC5串口协议_20261031.md). What matters is whether they
    # change between reports. Repeated static pixels also change a rolling sum,
    # so motion in these counters proves activity, not fresh source content.
    if prev is not None and "W" in prev.words:
        din = (s.w("W", 2) - prev.w("W", 2)) & 0xFFFF
        dout = (s.w("W", 3) - prev.w("W", 3)) & 0xFFFF
        in_moves = din != 0
        out_moves = dout != 0
        if not in_moves and not out_moves:
            print("         RGB sums FROZEN on both sides -> no pixel content anywhere: check")
            print("         the capture path (W0/W1, I row) and the DDR write/read frame base.")
        elif in_moves and not out_moves:
            print("         input sum moves, output sum unchanged -> possible black/static output")
            print("         or rolling-sum aliasing; inspect G2 underflow, M0 and reader flags")
        elif out_moves and not in_moves:
            print("         output sum moves but the input sum is frozen -> the captured pixels are")
            print("         static (or the input sum aliased); the display path is alive.")
        else:
            print("         both RGB sums move -> pixel activity on both sides; repeated images")
            print("         also change rolling sums, so check source fid M0 for freshness")
    print("J row  : jobs=%d  blocks=%d  flags=%04X  slots=%02X" %
          (s.w("J", 0), s.w("J", 1), s.w("J", 2), s.w("J", 3)))
    jf = s.w("J", 2)
    print("         job flags: %scstate=%d fill_busy=%d samp_busy=%d next_valid=%d "
          "aux_bank_busy=%d busy=%d state=%d" %
          ("WRITER-WATCHDOG " if (jf & 0x1000) else "",
           (jf >> 6) & 0x7, (jf >> 9) & 1, (jf >> 10) & 1, (jf >> 11) & 1,
           (jf >> 3) & 1, (jf >> 2) & 1, jf & 0x3))
    print("G row  : no_pend_us=%d  tick_skip=%d  underflow=%d  reader_flags=%04X" %
          (s.w("G", 0), s.w("G", 1), s.w("G", 2), s.w("G", 3)))
    # 2026-11-03: G0/G1 are the scheduling counters (they used to be the per-block
    # recs_total/sample_left snapshot). They answer "why is a boundary lost":
    #   G0 = microseconds of the interval spent IDLE with no descriptor in hand
    #   G1 = boundaries dropped because there was no descriptor and the repeat cap
    #        forbade forcing one -> this should equal the underflow increment
    duf = None
    if prev is not None and "G" in prev.words:
        # G1 is an INTERVAL counter (cleared together with the snapshot), so its value
        # already is "per last second" - do not take a delta of it.
        dskip = s.w("G", 1)
        duf   = (s.w("G", 2) - prev.w("G", 2)) & 0xFFFF
        if dskip or duf:
            print("         scheduling: tick_skip=%d/s  underflow=+%d/s%s" %
                  (dskip, duf, "  (MATCH -> every black frame is a boundary with no frame)"
                   if dskip == duf else "  (MISMATCH -> black frames have another cause)"))
        if s.w("G", 0) >= 0xFFFF:
            print("         wait-for-frame = SATURATED (>=65.5 ms/s) -> the job FSM spends a")
            print("         large part of every second waiting for a source frame")
        elif s.w("G", 0) > 0:
            print("         wait-for-frame = %.3f ms/s (1 LSB = 1.024 ms) -> the job FSM is"
                  " idle waiting for a source frame" % (s.w("G", 0) * 1.024))
    gf = s.w("G", 3)
    print("         reader: cur_stripe=%d cur_ok=%d frame_ok=%d waiting_first=%d "
          "frame_black=%d have_next=%d cur_bank=%d next_bank=%d" %
          (gf & 0x7F, (gf >> 8) & 1, (gf >> 7) & 1, (gf >> 9) & 1,
           (gf >> 10) & 1, (gf >> 11) & 1, (gf >> 12) & 0x3, (gf >> 14) & 0x3))
    # 2026-11-03: K0 = {acq_req, acq_got} - where does the descriptor get lost?
    print("K row  : acq_req=%3d  acq_got=%3d  job_max_us=%d  stripe=%04X  sticky=%04X" %
          (s.w("K", 0) >> 8, s.w("K", 0) & 0xFF, s.w("K", 1), s.w("K", 2), s.w("K", 3)))
    if (s.w("K", 0) >> 8) and (s.w("K", 0) & 0xFF):
        ar = s.w("K", 0) >> 8
        ag = s.w("K", 0) & 0xFF
        if ar >= 200 and ag <= 2:
            print("         acquire: %d requests but only %d descriptors -> the frame" % (ar, ag))
            print("         manager refuses (or has no READY frame); look at the slot states (J3)")
        elif ag >= 40:
            print("         acquire: %d requests -> %d descriptors (the acquire path works;" % (ar, ag))
            print("         the loss is in pend/start handling, not in the manager)")
    k2 = s.w("K", 2)
    print("         K2 (DGC5): pix_sid=%d  bank0_sid=%d  reading0=%d reading1=%d" %
          ((k2 >> 9) & 0x7F, (k2 >> 2) & 0x7F, k2 & 1, (k2 >> 1) & 1))
    stk = s.w("K", 3)
    print("         sticky: ack-timeout=%d writer-watchdog=%d reader-rel-overflow=%d "
          "reader-vs-discard=%d" %
          ((stk >> 15) & 1, (stk >> 10) & 1, (stk >> 11) & 1, (stk >> 12) & 1))

    p = [s.w("P", i) for i in range(4)]
    q = [s.w("Q", i) for i in range(4)]
    r = [s.w("R", i) for i in range(4)]

    if p[0] == 0 and q[1] == 0:
        print("\nP/Q/R : all zero -> the board is still running a DGC2 bit, or the")
        print("        counters are not latched (sticky[15] would be set on ack timeout).")
        return None

    print("\nP/Q/R (per second, 1 LSB = %.2f us proc / %.2f us ddr):" % (PROC_LSB_US, DDR_LSB_US))
    print("  P0 fill active      %6d LSB = %8.2f ms  (%5.1f %% of the second)"
          % (p[0], p[0] * PROC_LSB_US / 1000.0, pct(p[0], int(1e6 / PROC_LSB_US))))
    print("  P1 wait beats       %6d LSB = %8.2f ms  (%.1f %% of fill)"
          % (p[1], p[1] * PROC_LSB_US / 1000.0, pct(p[1], p[0])))
    print("  P2 wait row channel %6d LSB = %8.2f ms  (%.1f %% of fill)"
          % (p[2], p[2] * PROC_LSB_US / 1000.0, pct(p[2], p[0])))
    print("  P3 wait planner     %6d LSB = %8.2f ms  (%.1f %% of fill)"
          % (p[3], p[3] * PROC_LSB_US / 1000.0, pct(p[3], p[0])))
    print("  Q0 fill writes      %6d LSB = %8.2f ms  (%.1f %% of fill)"
          % (q[0], q[0] * PROC_LSB_US / 1000.0, pct(q[0], p[0])))
    print("  Q1 sample active    %6d LSB = %8.2f ms"
          % (q[1], q[1] * PROC_LSB_US / 1000.0))
    print("  Q2 writer stall     %6d LSB = %8.2f ms  (%.1f %% of sample)"
          % (q[2], q[2] * PROC_LSB_US / 1000.0, pct(q[2], q[1])))
    print("  Q3 sampler stall    %6d LSB = %8.2f ms  (%.1f %% of sample)"
          % (q[3], q[3] * PROC_LSB_US / 1000.0, pct(q[3], q[1])))
    print("  R0 AR handshakes    %6d LSB = %8.0f AR/s" % (r[0], r[0] * 128.0))
    print("  R1 wait ar_ready    %6d LSB = %8.2f ms ddr" % (r[1], r[1] * DDR_LSB_US / 1000.0))
    print("  R2 return starve    %6d LSB = %8.2f ms ddr" % (r[2], r[2] * DDR_LSB_US / 1000.0))
    print("  R3 max in flight    %6d" % r[3])

    # ---- DGC4 M line: frame age (the whole point of this line) --------------
    age = None
    if "M" in s.words:
        m = [s.w("M", i) for i in range(4)]
        age = (m[1] - m[0]) & 0xFFFF
        # job_id_r is loaded from pend_id = frame_acquired[31:0], i.e. source fid.
        print("  M0 source fid[15:0] %6d" % m[0])
        print("  M1 capture frames   %6d" % m[1])
        print("  M2 frame releases   %6d" % m[2])
        print("  M3 alloc drops      %6d" % m[3])
        print("  source frame age    %6d   (M1-M0 modulo 65536)" % age)
        if prev is not None and "M" in prev.words:
            dfid = (m[0] - prev.w("M", 0)) & 0xFFFF
            dcap = (m[1] - prev.w("M", 1)) & 0xFFFF
            print("  source progress     +%d fid, +%d capture allocations since previous report" % (dfid, dcap))
            if dfid == 0 and dcap > 0:
                print("         SOURCE REPEAT while capture advances; sustained repeats indicate a freeze")

    # ---- DGC5 V line: video-reader activity --------------------------------
    v = None
    if "V" in s.words:
        v = [s.w("V", i) for i in range(4)]
        print("  V0 offers consumed  %6d" % v[0])
        print("  V1 offers discarded %6d" % v[1])
        print("  V2 last starvation   0x%04X  %s" % (v[2], starve_text(v[2])))
        print("  V3 stripe releases  %6d" % v[3])

    problems = []
    if q[0] > p[0]:
        problems.append("Q0 (fill writes) > P0 (fill active) - counter wiring or scale error")
    if q[2] > q[1]:
        problems.append("Q2 (writer stall) > Q1 (sample active) - counter wiring or scale error")
    if r[3] > 8:
        problems.append("R3 > 8 - the fetch queue cannot exceed 8")
    if s.w("G", 2) == 0 or s.w("W", 1) != 0:
        pass
    for msg in problems:
        print("  !! INCONSISTENT: " + msg)

    # ---- job budget -----------------------------------------------------------
    jobs = s.w("J", 0)
    djobs = None
    if prev is not None:
        djobs = (jobs - prev.w("J", 0)) & 0xFFFF
    print("\njob budget: J.jobs=%d%s" %
          (jobs, "" if djobs is None else ", jobs/s = %d" % djobs))

    # ---- verdict --------------------------------------------------------------
    print("\nVERDICT (rules in docs/DGC3 protocol doc, section 5):")
    verdict = []
    # 1) which engine owns the block time: the one whose "active" count is larger.
    if q[1] < 0.65 * p[0]:
        verdict.append("- FILL sets the block time: fill active is %.1fx sample active; "
                       "sample is not the limiter" % (1.0 * p[0] / max(q[1], 1)))
    elif p[0] < 0.65 * q[1]:
        verdict.append("- SAMPLE sets the block time: sample active is %.1fx fill active" %
                       (1.0 * q[1] / max(p[0], 1)))
    else:
        verdict.append("- fill and sample are both active most of the time; split by the waits below")
    # 2) what the fill spends its time on
    if p[0] > 0:
        if pct(p[1], p[0]) > 40:
            verdict.append("- fill mostly WAITS FOR BEATS (P1 = %.0f%% of P0): look at R1/R2/R3"
                           % pct(p[1], p[0]))
        if pct(p[2], p[0]) + pct(p[3], p[0]) > 40:
            verdict.append("- fill mostly waits for the ROW CHANNEL or PLANNER (P2+P3 = %.0f%% of P0): "
                           "the row-request production rate limits the fill"
                           % (pct(p[2], p[0]) + pct(p[3], p[0])))
        if pct(q[0], p[0]) > 40:
            verdict.append("- fill time is dominated by actual CACHE WRITES (Q0 = %.0f%% of P0): "
                           "the cache write port is the floor" % pct(q[0], p[0]))
    if q[1] > 0 and pct(q[2], q[1]) > 40:
        verdict.append("- sample mostly stalls on the STRIPE WRITER (Q2 = %.0f%% of Q1): "
                       "output bank ownership, not DDR" % pct(q[2], q[1]))
    if age is not None and age > 5:
        verdict.append("- STALE SOURCE FRAME: the job is %d frames (%.1f s) behind the capture;"
                       " look at frame_manager acquire/release and slot states." % (age, age / 60.0))
    if v is not None:
        offers, discards, location, releases = v
        if duf == 0:
            verdict.append("- no new reader underflow since previous report; V2 is latched history")
        elif duf is not None:
            verdict.append("- %d new reader underflow(s); V2=0x%04X: %s" %
                           (duf, location, starve_text(location)))
        else:
            verdict.append("- V2=0x%04X is historical; compare G2 underflow between reports to detect new black frames" % location)
        if offers > 0 and releases == 0:
            verdict.append("- V0 = %d offers but V3 = 0 releases: the reader consumed stripe offers "
                           "and never returned a bank. The writer will run out of banks and px_ready "
                           "will stay 0; check the reader's frame_black state (G3) and the watchdog "
                           "sticky (K3 bit 10)." % offers)
        elif offers > releases + 2:
            verdict.append("- V0 - V3 = %d: more offers consumed than banks released, so some bank "
                           "ownership is outstanding across the report boundary (or leaked)."
                           % (offers - releases))
        if discards == offers and offers > 0:
            verdict.append("- V1 = V0 = %d: every offer was discarded, i.e. the reader is black and "
                           "its stripe 0 never arrived in time (G3 frame_black)." % offers)
        elif discards > 0 and offers > 0:
            verdict.append("- V1 = %d of %d offers discarded: the reader was black for part of the "
                           "interval (late stripe 0 / underflow), not for all of it."
                           % (discards, offers))
        if (s.w("K", 3) & 0x0400):
            verdict.append("- K3 bit 10 set: the stripe-writer reader-ownership watchdog fired. A bank "
                           "stayed in READING for 24.5 ms; the reader lost ownership of a bank. This "
                           "is the black-screen recovery path, not normal operation.")
    if r[3] == 1:
        verdict.append("- R3 = 1: never more than one native request in flight. "
                       "This is why deepening the fetch queue (QD 4->8) changed nothing.")
    elif r[3] >= 2:
        verdict.append("- R3 = %d: requests do overlap; latency/bandwidth per burst is the exposure." % r[3])
    if not verdict:
        verdict.append("- no dominant single cause; compare several reports and look at J/G/K as well.")
    print("\n".join(verdict))
    return True


SELF_TEST = [
    # one synthetic snapshot: fill active 35000 LSB, waiting for beats 30000,
    # writes 11000, sample 12000, no writer stall, 16000 LSB of ARs, max 1 in flight
    ("S", "1FFD02FF0000002A"),
    ("I", "02B405CA07800438"),
    ("W", "0042000000001234"),
    ("J", "00001E000010040F"),
    ("G", "0200000000000402"),
    ("K", "0010000A10840000"),
    ("P", "88B8753000000000"),
    ("Q", "2AF82EE000000000"),
    ("R", "3E80000000000001"),
    ("M", "0064006A00000000"),
    ("V", "00280000003C0028"),
]


def self_test():
    s = Snapshot()
    for label, h in SELF_TEST:
        s.add(label, h)
    assert s.complete()
    assert s.w("S", 0) == 0x1FFD, hex(s.w("S", 0))
    assert s.w("I", 2) == 0x0780
    assert s.w("P", 0) == 0x88B8, hex(s.w("P", 0))
    describe(s)
    print("\nSELF-TEST PASS")


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2
    if argv[1] == "--self-test":
        self_test()
        return 0
    snaps, raw = parse(argv[1])
    print("DGC3 decode: %s" % argv[1])
    print("decoded %d complete snapshot(s) from %d report lines" % (len(snaps), raw))
    if not snaps:
        print("no complete snapshot found - is the prefix DGC3/DGC4 and is the log complete?")
        return 1
    # the last complete snapshot is the most useful; print up to the last three
    for i in range(max(0, len(snaps) - 3), len(snaps)):
        describe(snaps[i], snaps[i - 1] if i > 0 else None)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))













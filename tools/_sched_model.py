"""Throw-away model of the board's job-scheduling loop (2026-11-02 investigation).

The board reads 40 job/s with REPEAT_MAX=1 and 50 job/s with REPEAT_MAX=4, while the
capture delivers 60 frames/s (and 60 job/s with unlimited repeats, but then the same
source frame is processed again and again).  Hand reasoning about the capture/display
phase drift kept contradicting the measurement, so this script reproduces the RTL
decision logic (dgc_frame_manager + the dgc_core_sys job FSM) as a discrete-event
model and prints the job rate and frame freshness for the candidate fixes.

Nothing here is part of the design; it only decides which RTL change to try next.

Model (times in microseconds)
  display boundary  B = 0, T_D, 2*T_D ...                  T_D = 16666.7 (60 Hz)
  capture           frame f is published at C = C0 + f*T_C and a slot is requested
                    for the next frame at the same instant (the capture writer
                    publishes and immediately needs the next slot).  T_C = 16690:
                    the camera is 23 us slower per frame, so the publish instant
                    drifts +23 us per frame against the display boundary.
  slots             FREE / WRITING / READY(age) / HELD, three of them.
  acquisition       newest READY by frame_id; the frame that was just acquired is
                    refused while a newer capture is in flight, unless the request
                    is forced (acquire_force).
  job FSM           idle -> acquire retried every 6 us -> descriptor held until a
                    boundary -> job runs for D (display paced) -> release.
                    A boundary with no descriptor forces one acquire (subject to the
                    repeat cap); a descriptor that arrives up to `window` us after a
                    boundary still starts the job (START_WINDOW).
  release           a released slot returns to READY with age 0 (frozen spec: the
                    newest frame may be processed again), so the capture side
                    reclaims the OLDEST READY slot.

Variants
  --repeat N    REPEAT_MAX (N consecutive repeats allowed; 999 = unlimited)
  --early R     release the source slot R us after the job start instead of at the
                job end (the "source no longer read" change)
  --prefetch    allow the acquire, and holding the descriptor, while a job runs
  --window W    START_WINDOW in us (117 us on the board)
"""

import argparse


class Slot:
    __slots__ = ("state", "fid", "age")

    def __init__(self, state="FREE", fid=0):
        self.state = state
        self.fid = fid
        self.age = 0.0


def simulate(T_D=16666.7, T_C=16690.0, D=16000.0, repeat=1, early=None,
             prefetch=False, window=117.0, seconds=20.0, quiet=False,
             slots_n=3):
    # slots_n = number of DDR source frame slots in dgc_frame_manager. 3 is today's
    # design; 4 is the option that makes descriptor prefetch safe, because prefetch
    # pins TWO slots (the running job + the pending descriptor) while the capture
    # still needs one to write into.
    slots = [Slot("WRITING", 0)] + [Slot() for _ in range(slots_n - 1)]
    nxt_fid = 1
    alloc_cnt = 0
    alloc_at_acq = 0
    last_acq_valid = False
    last_acq_fid = 0

    pend_valid = False
    pend_fid = 0
    pend_slot = None
    job_state = 0
    job_fid = 0
    job_slot = None
    job_start = 0.0
    job_seen = False
    job_repeat = 0
    src_released = False
    acq_next = 0.0
    force_req = False

    jobs = []
    drops = 0
    skips = 0
    late = 0

    t = 0.0
    t_end = seconds * 1e6
    B = T_D
    C = T_C
    last_B = -1e18
    started_this_boundary = True     # the first boundary has no job to start
    last_age_t = 0.0

    def advance_ages(t_new):
        nonlocal last_age_t
        dt = t_new - last_age_t
        for s in slots:
            if s.state == "READY" and s.age < 255:
                s.age += dt
        last_age_t = t_new

    def newest_ready():
        rdy = [s for s in slots if s.state == "READY"]
        return max(rdy, key=lambda s: s.fid) if rdy else None

    def oldest_ready():
        rdy = [s for s in slots if s.state == "READY"]
        return max(rdy, key=lambda s: s.age) if rdy else None

    def do_acquire(force):
        nonlocal alloc_at_acq, last_acq_valid, last_acq_fid
        s = newest_ready()
        if s is None:
            return None
        stale = (last_acq_valid and s.fid == last_acq_fid
                 and alloc_cnt != alloc_at_acq)
        if stale and not force:
            return None
        last_acq_fid = s.fid
        last_acq_valid = True
        alloc_at_acq = alloc_cnt
        s.state = "HELD"
        return s

    def start_job(s, t):
        nonlocal job_state, job_fid, job_slot, job_start, job_repeat, job_seen
        nonlocal pend_valid, src_released, acq_next, last_acq_fid
        job_state = 1
        job_fid = s.fid
        job_slot = s
        job_start = t
        job_repeat = (job_repeat + 1) if (job_seen and s.fid == job_fid_prev[0]) else 0
        job_seen = True
        job_fid_prev[0] = s.fid
        src_released = False
        pend_valid = False
        acq_next = t
        jobs.append((t, job_fid, job_repeat > 0))

    job_fid_prev = [None]

    while t < t_end:
        events = [(B, "B"), (C, "C")]
        if job_state == 1:
            if early is not None and not src_released:
                events.append((job_start + early, "R"))
            events.append((job_start + D, "E"))
        if force_req:
            events.append((t, "FORCE"))
        elif not pend_valid and (job_state == 0 or prefetch):
            events.append((max(acq_next, t), "A"))
        events.sort()
        t_new, kind = events[0]
        if t_new > t_end:
            break
        advance_ages(t_new)
        t = t_new

        if kind == "C":
            wr = [s for s in slots if s.state == "WRITING"]
            if wr:
                wr[0].state = "READY"
                wr[0].age = 0.0
            free = [s for s in slots if s.state == "FREE"]
            if free:
                g = free[0]
            else:
                g = oldest_ready()
                if g is None:
                    drops += 1
                    C += T_C
                    continue
            g.state = "WRITING"
            g.fid = nxt_fid
            nxt_fid += 1
            g.age = 0.0
            alloc_cnt += 1
            C += T_C

        elif kind == "A":
            force = force_req
            force_req = False
            s = do_acquire(force)
            if s is not None:
                pend_valid = True
                pend_fid, pend_slot = s.fid, s
                # a descriptor that arrives inside the start window starts now
                if (job_state == 0 and t - last_B <= window
                        and not started_this_boundary):
                    started_this_boundary = True
                    late += 1
                    start_job(s, t)
                    pend_valid = False
            else:
                acq_next = t + 6.0

        elif kind == "R":
            if job_slot is not None and job_slot.state == "HELD":
                job_slot.state = "READY"
                job_slot.age = 0.0
            src_released = True

        elif kind == "E":
            if job_slot is not None and not src_released:
                if job_slot.state == "HELD":
                    job_slot.state = "READY"
                    job_slot.age = 0.0
            src_released = True
            job_state = 0
            job_slot = None
            acq_next = t

        elif kind == "B":
            last_B = t
            started_this_boundary = False
            if job_state == 1:
                # the previous job is still running: this boundary cannot start
                # anything (one core, one job at a time) - it is simply lost.
                skips += 1
                B += T_D
                continue
            if pend_valid:
                started_this_boundary = True
                s = pend_slot
                start_job(s, t)
            else:
                if job_repeat < repeat:
                    force_req = True
                else:
                    skips += 1
            B += T_D

        elif kind == "FORCE":
            s = do_acquire(True)
            force_req = False
            if s is not None:
                started_this_boundary = True
                start_job(s, t)

    body = [j for j in jobs if j[0] > 4 * T_D]
    span = max(1e-9, (seconds * 1e6 - 8 * T_D))
    rate = len(body) / (span / 1e6)
    fresh = sum(1 for j in body if not j[2])
    rep = len(body) - fresh
    seq = [j[1] for j in body]
    consec = 0
    worst = 0
    prev = None
    for f in seq:
        if prev is not None and f == prev:
            consec += 1
            worst = max(worst, consec)
        else:
            consec = 0
        prev = f
    if not quiet:
        print(f"T_D={T_D/1000:.3f} T_C={T_C/1000:.3f} D={D/1000:.2f} "
              f"repeat={repeat} early={early} prefetch={prefetch} window={window}")
        print(f"  {rate:5.1f} job/s   jobs={len(body)} skips={skips} drops={drops} "
              f"late_starts={late}")
        print(f"  fresh={fresh} repeats={rep} worst_run={worst} "
              f"distinct_frames={len(set(seq))} (~{int(span/T_C)} captured)")
        print(f"  seq[:32]={seq[:32]}")
    return dict(rate=rate, fresh=fresh, repeats=rep, skips=skips, drops=drops,
                worst=worst, seq=seq, late=late)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--repeat", type=int, default=1)
    ap.add_argument("--early", type=float, default=None)
    ap.add_argument("--prefetch", action="store_true")
    ap.add_argument("--window", type=float, default=117.0)
    ap.add_argument("--d", type=float, default=16000.0)
    ap.add_argument("--tc", type=float, default=16690.0)
    ap.add_argument("--seconds", type=float, default=20.0)
    ap.add_argument("--slots", type=int, default=3)
    a = ap.parse_args()
    simulate(repeat=a.repeat, early=a.early, prefetch=a.prefetch,
             window=a.window, D=a.d, T_C=a.tc, seconds=a.seconds,
             slots_n=a.slots)

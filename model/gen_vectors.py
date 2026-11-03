#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_vectors.py - produce golden vectors for the map_pipeline RTL

The RTL must match model/s1_pipeline_model.py *bit for bit*. Instead of sampling
a few points, this script writes one line per output pixel for a whole
1920x1080 frame, so the testbench can check every coordinate the hardware will
ever produce within a job.

Two files are written:

    coords_mode1_full.vec   every pixel of one frame, mode 1 (static k1/k2)
    coords_mode0_sweep.vec  a stride-7 sweep of the frame, mode 0 (identity)

Line format (whitespace separated integers, order matches the RTL drive order):

    dst_x dst_y sx0 sy0 wx wy sample_ok math_error

`sx0 sy0 wx wy` are already the final record fields, i.e. they are zero whenever
sample_ok is 0, exactly as the RTL forces them.

Usage:
    python model/gen_vectors.py
"""

from __future__ import annotations

from pathlib import Path

import numpy as np

import dgc_fixed_ref as ref

F24 = 24
F16 = 16

OUT_DIR = Path(__file__).resolve().parents[1] / "sim" / "s1_map_pipeline" / "vectors"

CALIB = ref.CamParams(
    fx=2096.2197100932767, fy=2116.286816619084,
    cx=977.0284405843266, cy=520.1056361590967,
    k1=-0.4816025644280037, k2=0.27820370283889506,
)


def compute_frame(qp: ref.QuantParams, mode: int):
    """Vectorised integer pipeline. Returns (sx0, sy0, wx, wy, ok, merr)."""
    W, H = ref.WIDTH, ref.HEIGHT
    vv, uu = np.mgrid[0:H, 0:W]
    u = uu.astype(np.int64)
    v = vv.astype(np.int64)

    if mode == 0:
        sx = (u << F16)
        sy = (v << F16)
        ok = np.ones_like(sx, dtype=bool)
        merr = np.zeros_like(sx, dtype=bool)
    else:
        m = qp.M_q
        a = m[0, 0] * u + m[0, 1] * v + m[0, 2]
        b = m[1, 0] * u + m[1, 1] * v + m[1, 2]
        x = a >> 2
        y = b >> 2
        xsq = (x * x) >> F24
        ysq = (y * y) >> F24
        r2 = xsq + ysq
        r2sq = (r2 * r2) >> F24
        radial = (1 << F24) + ((int(qp.k1_q) * r2) >> 28) + ((int(qp.k2_q) * r2sq) >> 28)
        xd = (x * radial) >> F24
        yd = (y * radial) >> F24
        sx = ((int(qp.fx_q) * xd) >> 24) + int(qp.cx_q)
        sy = ((int(qp.fy_q) * yd) >> 24) + int(qp.cy_q)
        merr = np.zeros_like(sx, dtype=bool)
        ok = (sx >= 0) & (sx <= ((W - 1) << F16)) & (sy >= 0) & (sy <= ((H - 1) << F16))

    # record fields, exactly as the RTL assembles them
    sx0 = np.where(ok, (sx >> F16) & 0x7FF, 0)
    sy0 = np.where(ok, (sy >> F16) & 0x7FF, 0)
    wx = np.where(ok, sx & 0xFFFF, 0)
    wy = np.where(ok, sy & 0xFFFF, 0)
    return uu, vv, sx0, sy0, wx, wy, ok, merr


def write_vec(path: Path, uu, vv, sx0, sy0, wx, wy, ok, merr, stride: int = 1):
    """Write the vector file. stride > 1 subsamples the grid for the cheap sweeps."""
    u = uu[::stride, ::stride].ravel()
    v = vv[::stride, ::stride].ravel()
    a = sx0[::stride, ::stride].ravel()
    b = sy0[::stride, ::stride].ravel()
    c = wx[::stride, ::stride].ravel()
    d = wy[::stride, ::stride].ravel()
    e = ok[::stride, ::stride].ravel().astype(np.int64)
    f = merr[::stride, ::stride].ravel().astype(np.int64)

    n = u.size
    with path.open("w", encoding="ascii", newline="\n") as fh:
        fh.write(f"# dgc map_pipeline golden vectors\n")
        fh.write(f"# lines: {n}\n")
        fh.write("# dst_x dst_y sx0 sy0 wx wy sample_ok math_error\n")
        # writing column by column through a numpy buffer keeps this fast
        buf = np.empty((n, 8), dtype=np.int64)
        buf[:, 0] = u
        buf[:, 1] = v
        buf[:, 2] = a
        buf[:, 3] = b
        buf[:, 4] = c
        buf[:, 5] = d
        buf[:, 6] = e
        buf[:, 7] = f
        np.savetxt(fh, buf, fmt="%d")
    return n


def main() -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    qp = ref.quantize_params(CALIB)

    print("generating golden vectors for map_pipeline")
    print(f"  calibration : {CALIB.fx:.4f} / {CALIB.fy:.4f} / "
          f"{CALIB.cx:.4f} / {CALIB.cy:.4f}  k1={CALIB.k1:.6f} k2={CALIB.k2:.8f}")

    # ---- mode 1, full frame ----
    uu, vv, sx0, sy0, wx, wy, ok, merr = compute_frame(qp, 1)
    n1 = write_vec(OUT_DIR / "coords_mode1_full.vec", uu, vv, sx0, sy0, wx, wy, ok, merr, 1)
    print(f"  coords_mode1_full.vec : {n1:,} records "
          f"({100.0 * ok.sum() / ok.size:.2f} % sample_ok)")

    # ---- mode 0, stride-7 sweep ----
    uu0, vv0, sx00, sy00, wx0, wy0, ok0, merr0 = compute_frame(qp, 0)
    n0 = write_vec(OUT_DIR / "coords_mode0_sweep.vec", uu0, vv0, sx00, sy00, wx0, wy0, ok0, merr0, 7)
    print(f"  coords_mode0_sweep.vec: {n0:,} records (identity)")

    # ---- sanity: a couple of records reread and checked ----
    print("\n  spot check of the generated file:")
    with (OUT_DIR / "coords_mode1_full.vec").open(encoding="ascii") as fh:
        lines = [ln for ln in fh if not ln.startswith("#")]
    for idx in (0, 540 * ref.WIDTH + 960, len(lines) - 1):
        print(f"    [{idx}] {lines[idx].strip()}")

    print("\ndone")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

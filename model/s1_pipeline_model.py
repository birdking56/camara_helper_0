#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
s1_pipeline_model.py - bit-accurate integer model of the planned map_pipeline

The error budget script proved that the frozen parameter encodings alone cost
about 0.011 px, leaving roughly 0.089 px for the arithmetic inside
map_pipeline. This module fixes that arithmetic exactly, in integers, so that

  * the RTL has an unambiguous target to match,
  * the total error can be measured *before* writing RTL, and
  * the intermediate widths can be justified by numbers instead of by feel.

Chosen internal format: signed Q(23.x) with 24 fractional bits, 32-bit words.

    F24, W32  ->  range +-128.0,  resolution 2^-24 = 5.96e-8
                  1 LSB is 5.96e-8 * fx (2096) = 1.25e-4 source pixels,
                  i.e. about 800x finer than the 0.1 px budget.

Why F24 rather than F26 (the matrix format)
    The matrix is delivered in F26, but keeping F26 through the polynomial needs
    31 bits just to hold |x| <= 2.0 with a radial factor up to ~15, which leaves
    no headroom in a 32-bit word. Shifting to F24 after the matrix multiply costs
    two LSBs of the matrix result (1.2e-7 normalized, 2.5e-4 px) and buys a range
    of +-128, which comfortably holds every intermediate for the declared
    norm_abs_max = 2.0.

Every truncation is an arithmetic right shift (floor), matching Verilog's >>>.

Formats used below
    u, v            integer pixel coordinates
    m**             F26, 32-bit      (interface)
    x, y            F24, 32-bit      (after matrix multiply, two bits dropped)
    xsq, ysq, r2    F24, 32-bit      (|r2| <= 128 for |x|,|y| <= 2)
    r2sq            F24, 32-bit      (|r2^2| <= 64)
    radial          F24, 32-bit      (|radial| <= 128)
    xd, yd          F24, 32-bit      (|xd| <= 128)
    sx, sy          F16, 32-bit      (coordinate record, floor(coord * 65536))

Usage:
    python model/s1_pipeline_model.py
"""

from __future__ import annotations

import numpy as np

import dgc_fixed_ref as ref

F26 = 26
F24 = 24
F16 = 16


def mul_shift(a: np.ndarray, b: np.ndarray, shift: int) -> np.ndarray:
    """(a * b) >> shift with an arithmetic shift (floor), as Verilog >>> does.

    Python's >> on negative integers already floors, so this matches hardware.
    The inputs are int64 arrays; the product is widened by numpy automatically
    only up to int64, so callers must keep |a|,|b| < 2^31 (true here: all are
    signed 32-bit values).
    """
    return np.right_shift(np.multiply(a.astype(np.int64), b.astype(np.int64)), shift)


# --------------------------------------------------------------------------
# one output pixel through the planned data path, in integers
# --------------------------------------------------------------------------
def map_pixel_int(
    u: int,
    v: int,
    qp: ref.QuantParams,
    mode: int = 1,
) -> tuple[int, int, int, int, int]:
    """Return (sx_f16, sy_f16, sample_ok, math_error, r2_f24).

    mode 0: identity, sx/u and sy/v are exact integers shifted to F16.
    mode 1: default K-derived M, last row (0,0,1), no w division.
    """

    if mode == 0:
        sx = u << F16
        sy = v << F16
        ok = 1 if (0 <= u <= ref.WIDTH - 1 and 0 <= v <= ref.HEIGHT - 1) else 0
        if not ok:
            sx = 0
            sy = 0
        return sx, sy, ok, 0, 0

    m = qp.M_q  # F26

    # ---- (a, b) = M * (u, v, 1), still in F26 ---------------------------
    a_f26 = int(m[0, 0]) * u + int(m[0, 1]) * v + int(m[0, 2])
    b_f26 = int(m[1, 0]) * u + int(m[1, 1]) * v + int(m[1, 2])

    # mode 1 requires the last row to be (0,0,1); w == 1 so no division.
    # Nothing to check here: config_manager rejects a non-default M in mode 1.

    # ---- drop two fractional bits to enter the F24 polynomial ------------
    x = a_f26 >> 2
    y = b_f26 >> 2

    # ---- r2 = x*x + y*y ------------------------------------------------
    xsq = (x * x) >> F24
    ysq = (y * y) >> F24
    r2  = xsq + ysq
    r2sq = (r2 * r2) >> F24

    # ---- radial = 1 + k1*r2 + k2*r2^2 ----------------------------------
    # k1, k2 are F28; r2, r2sq are F24 -> product F52, want F24 -> shift 28
    one_f24 = 1 << F24
    k1r2  = (int(qp.k1_q) * r2)   >> 28
    k2r2s = (int(qp.k2_q) * r2sq) >> 28
    radial = one_f24 + k1r2 + k2r2s

    # ---- p1/p2 terms are not implemented in the basic stage -------------
    # The frozen spec keeps them behind capability bit 4; config_manager returns
    # UNSUPPORTED when a non-zero p1/p2/k3 is committed, so they are not in the
    # basic data path. The golden model still supports them in float form.

    # ---- xd = x * radial ------------------------------------------------
    xd = (x * radial) >> F24
    yd = (y * radial) >> F24

    # ---- sx = fx * xd + cx, fx/cx are F16 -------------------------------
    # fx(F16) * xd(F24) = F40, want F16 -> shift 24
    sx = ((int(qp.fx_q) * xd) >> 24) + int(qp.cx_q)
    sy = ((int(qp.fy_q) * yd) >> 24) + int(qp.cy_q)

    # ---- legality is decided on the PRE-quantization value -------------
    # The frozen spec: only if the pre-quantization mapped coordinate lies in
    # [0,1919]x[0,1079] is sample_ok set. sx is already floor(coord*65536), so
    # the comparison is done on the F16 integer with floor semantics.
    sx_max = (ref.WIDTH  - 1) << F16
    sy_max = (ref.HEIGHT - 1) << F16
    ok = 1 if (sx >= 0 and sx <= sx_max and sy >= 0 and sy <= sy_max) else 0

    if not ok:
        # out-of-range records are still written, but with the coordinate
        # fields zeroed so the sampler cannot read garbage
        return 0, 0, 0, 0, int(r2)

    return int(sx), int(sy), 1, 0, int(r2)


# --------------------------------------------------------------------------
# vectorised evaluation over the whole grid
# --------------------------------------------------------------------------
def evaluate(qp: ref.QuantParams, p: ref.CamParams, mode: int = 1):
    """Run every output pixel through the integer model and compare with float64."""
    W, H = ref.WIDTH, ref.HEIGHT
    vv, uu = np.mgrid[0:H, 0:W]
    uu = uu.astype(np.int64)
    vv = vv.astype(np.int64)

    m = qp.M_q
    if mode == 0:
        sx_i = uu << F16
        sy_i = vv << F16
    else:
        a_f26 = m[0, 0] * uu + m[0, 1] * vv + m[0, 2]
        b_f26 = m[1, 0] * uu + m[1, 1] * vv + m[1, 2]
        x = a_f26 >> 2
        y = b_f26 >> 2
        xsq = (x * x) >> F24
        ysq = (y * y) >> F24
        r2 = xsq + ysq
        r2sq = (r2 * r2) >> F24
        k1r2 = (int(qp.k1_q) * r2) >> 28
        k2r2s = (int(qp.k2_q) * r2sq) >> 28
        radial = (1 << F24) + k1r2 + k2r2s
        xd = (x * radial) >> F24
        yd = (y * radial) >> F24
        sx_i = ((int(qp.fx_q) * xd) >> 24) + int(qp.cx_q)
        sy_i = ((int(qp.fy_q) * yd) >> 24) + int(qp.cy_q)

    sx_max = (W - 1) << F16
    sy_max = (H - 1) << F16
    legal = (sx_i >= 0) & (sx_i <= sx_max) & (sy_i >= 0) & (sy_i <= sy_max)

    uf = uu.astype(np.float64)
    vf = vv.astype(np.float64)

    # Two references, because they answer two different questions.
    #   exact : the true ideal mapping with the UNQUANTIZED calibration. The
    #           frozen acceptance criterion is measured against this.
    #   quant : the same mapping with the frozen quantized parameters and float64
    #           arithmetic, which isolates the data-path arithmetic error from
    #           the parameter-encoding error.
    if mode == 0:
        sx_ex, sy_ex = uf, vf
        sx_qa, sy_qa = uf, vf
        legal_ex = np.ones_like(sx_ex, dtype=bool)
        legal_qa = legal_ex
    else:
        Mq_float = qp.M_q.astype(np.float64) / float(1 << F26)
        sx_ex, sy_ex, legal_ex = ref.map_float(uf, vf, p, p.default_M())
        sx_qa, sy_qa, legal_qa = ref.map_float(uf, vf, p, Mq_float)
        legal_ex = legal_ex & np.isfinite(sx_ex) & np.isfinite(sy_ex)
        legal_qa = legal_qa & np.isfinite(sx_qa) & np.isfinite(sy_qa)

    def _stats(ref_x, ref_y, ref_legal):
        disagree = int(np.sum(legal != ref_legal))
        both = legal & ref_legal
        ex = np.abs(sx_i[both] / 65536.0 - ref_x[both])
        ey = np.abs(sy_i[both] / 65536.0 - ref_y[both])
        e = np.maximum(ex, ey)
        return {
            "disagree": disagree,
            "max": float(e.max()) if e.size else 0.0,
            "mean": float(e.mean()) if e.size else 0.0,
        }

    return {
        "legal": int(legal.sum()),
        "exact": _stats(sx_ex, sy_ex, legal_ex),
        "quant": _stats(sx_qa, sy_qa, legal_qa),
    }


def main() -> int:
    ref.check_against_json()

    p = ref.CamParams(
        fx=2096.2197100932767, fy=2116.286816619084,
        cx=977.0284405843266, cy=520.1056361590967,
        k1=-0.4816025644280037, k2=0.27820370283889506,
    )
    qp = ref.quantize_params(p)

    print("\nS1 pipeline model - integer data path (F24 internal, F16 output)")
    print(f"  internal resolution  : 2^-24 = {2**-24:.3e} normalized "
          f"= {2**-24 * p.fx:.3e} source px")

    ok = True
    for mode, name in ((0, "mode 0 identity"), (1, "mode 1 static k1/k2")):
        r = evaluate(qp, p, mode)
        print(f"\n== {name} ==")
        print(f"  legal pixels                     : {r['legal']:,}")
        print(f"  vs EXACT float64 (end to end, the acceptance metric)")
        print(f"      legality disagreements       : {r['exact']['disagree']}")
        print(f"      max |error|                  : {r['exact']['max']:.6f} px")
        print(f"      mean |error|                 : {r['exact']['mean']:.6f} px")
        print(f"  vs QUANTIZED float64 (isolates the data-path arithmetic)")
        print(f"      legality disagreements       : {r['quant']['disagree']}")
        print(f"      max |error|                  : {r['quant']['max']:.6f} px")
        if mode == 0:
            if r["exact"]["max"] != 0.0:
                print("  FAIL: identity mode is not exact")
                ok = False
            else:
                print("  identity is exact (0.0 px), as required")
        if r["exact"]["max"] > 0.1 or r["exact"]["disagree"] != 0:
            ok = False

    # ---- identity of the integer path against itself, for RTL vectors ----
    print("\n== spot values for RTL vectors ==")
    for (u, v) in ((0, 0), (960, 540), (1919, 1079), (100, 200), (1800, 1000)):
        sx, sy, oks, merr, r2 = map_pixel_int(u, v, qp, 1)
        print(f"  (u,v)=({u:4d},{v:4d}) -> sx={sx:12d} sy={sy:12d} "
              f"sample_ok={oks} r2_f24={r2}")

    print("\n================ RESULT ================")
    print("  frozen 0.1 px budget : " + ("MET by the planned integer path" if ok else "NOT MET"))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())

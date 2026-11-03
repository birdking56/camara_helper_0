#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
s1_error_budget.py - does the frozen v1 parameter encoding meet 0.1 pixel?

The frozen acceptance criterion for S1 is:

    "恒等输出逐坐标精确，静态标定有效域的源坐标最大误差 <= 0.1 pixel"

Before any RTL is written this script answers the question that decides whether
that is even possible with the frozen encodings:

    fx, fy, cx, cy  S32/F16
    k1, k2, p1, p2, k3  S32/F28
    M  S32/F26

It compares, over the full 1920x1080 output grid,

    reference : float64 mapping with the exact calibration values
    v1 model  : same mapping but every parameter replaced by its quantized
                value, computed in float64 so that intermediate truncation is
                excluded

so the difference is purely the error contributed by *parameter encoding*.
That is a lower bound: the real pipeline adds its own arithmetic error on top,
and must therefore come in under the remaining margin.

It also prints the intermediate value ranges that size map_pipeline's data path
(needed later to prove no undetected overflow), and checks that a rotation-style
matrix still fits S32/F26, because S5 relies on it.

Usage:
    python model/s1_error_budget.py
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np

import dgc_fixed_ref as ref

ROOT = Path(__file__).resolve().parents[1]

# Frozen calibration, copied from docs/interface_v1/开发日志.md (the authoritative
# source is C:\Users\GREAT\Desktop\openCV_test\output\calib_round3_nolamp\calib.json).
CALIB = ref.CamParams(
    fx=2096.2197100932767,
    fy=2116.286816619084,
    cx=977.0284405843266,
    cy=520.1056361590967,
    k1=-0.4816025644280037,
    k2=0.27820370283889506,
    p1=0.0,
    p2=0.0,
    k3=0.0,
)

# Acceptance budget from the frozen spec.
BUDGET_PX = 0.1


def grid():
    v, u = np.mgrid[0:ref.HEIGHT, 0:ref.WIDTH]
    return u.astype(np.float64), v.astype(np.float64)


def analyse(label: str, p: ref.CamParams, M: np.ndarray | None = None):
    u, v = grid()

    sx_ref, sy_ref, legal_ref = ref.map_float(u, v, p, M)
    qp = ref.quantize_params(p, M)
    sx_q, sy_q, _ = ref.map_quantized_params(u, v, qp)

    # Only the valid domain matters: a point whose pre-quantization coordinate is
    # outside the source image is filled black and carries no coordinate record.
    valid = legal_ref & np.isfinite(sx_ref) & np.isfinite(sy_ref)

    err_x = np.abs(sx_q[valid] - sx_ref[valid])
    err_y = np.abs(sy_q[valid] - sy_ref[valid])
    err = np.maximum(err_x, err_y)

    n_total = u.size
    n_valid = int(valid.sum())

    print(f"\n== {label} ==")
    print(f"  output pixels            : {n_total:,}")
    print(f"  inside source image      : {n_valid:,}  ({100.0 * n_valid / n_total:.2f} %)")
    print(f"  max |error| x            : {err_x.max():.6f} px")
    print(f"  max |error| y            : {err_y.max():.6f} px")
    print(f"  max |error| (either)     : {err.max():.6f} px   budget {BUDGET_PX}")
    print(f"  mean |error|             : {err.mean():.6f} px")
    verdict = "PASS" if err.max() <= BUDGET_PX else "FAIL"
    print(f"  parameter-encoding only  : {verdict}")

    # margin left for the RTL arithmetic
    print(f"  margin left for RTL      : {BUDGET_PX - err.max():.6f} px")

    # ---------------- intermediate ranges (for data-path sizing) ----------------
    M_use = p.default_M() if M is None else M
    a = M_use[0, 0] * u + M_use[0, 1] * v + M_use[0, 2]
    b = M_use[1, 0] * u + M_use[1, 1] * v + M_use[1, 2]
    w = M_use[2, 0] * u + M_use[2, 1] * v + M_use[2, 2]
    x = a / w
    y = b / w
    r2 = x * x + y * y
    radial = 1.0 + p.k1 * r2 + p.k2 * r2 * r2 + p.k3 * r2 * r2 * r2

    def rng(name, arr):
        print(f"  {name:<24} : [{np.nanmin(arr):+.6f}, {np.nanmax(arr):+.6f}]")

    print("  --- intermediate ranges over the whole grid ---")
    rng("x (undistorted norm)", x)
    rng("y (undistorted norm)", y)
    rng("r2", r2)
    rng("radial", radial)
    rng("xd", x * radial)
    rng("yd", y * radial)

    # absolute bounds, ignoring the sign, for width sizing
    print(f"  max |x| = {np.nanmax(np.abs(x)):.6f}, max |y| = {np.nanmax(np.abs(y)):.6f}")
    print(f"  max r2  = {np.nanmax(r2):.6f}")

    return err.max(), verdict


def matrix_encoding_check():
    """S5 needs a rotation/affine matrix. Check that S32/F26 can hold one.

    A rotation matrix has entries in [-1, 1]; the translation column is scaled by
    1/fx, so it stays small. The dangerous case is a large scale factor applied to
    the pixel coordinates, which the host is required to pre-scale so M22 == 1.
    """
    print("\n== S32/F26 matrix encoding headroom ==")
    lo = -(1 << 31) / float(1 << 26)
    hi = ((1 << 31) - 1) / float(1 << 26)
    print(f"  representable range      : [{lo:.4f}, {hi:.4f}]")
    print(f"  resolution (1 LSB)       : {1.0 / (1 << 26):.3e}")

    # a 30 degree rotation, expressed the way the host would deliver it
    th = np.deg2rad(30.0)
    rot = np.array(
        [
            [np.cos(th) / CALIB.fx, -np.sin(th) / CALIB.fx, -CALIB.cx / CALIB.fx],
            [np.sin(th) / CALIB.fy, np.cos(th) / CALIB.fy, -CALIB.cy / CALIB.fy],
            [0.0, 0.0, 1.0],
        ]
    )
    q = np.vectorize(lambda v: ref.quantize_nearest_ties_away(v, 26))(rot)
    err = np.abs(q / float(1 << 26) - rot)
    print(f"  30 deg rotation, max quantization error of M : {err.max():.3e}")
    print(f"  (this multiplies pixel coordinates up to 1920, so the induced")
    print(f"   normalized-coordinate error is about {err.max() * 1920:.3e}, i.e. "
          f"{err.max() * 1920 * CALIB.fx:.6f} source pixels near the corner)")

    # the same rotation, end to end, in pixels
    u, v = grid()
    fs, _, legal_f = ref.map_float(u, v, CALIB, rot)
    qsx, _, _ = ref.map_quantized_params(u, v, ref.quantize_params(CALIB, rot))
    d = np.abs(qsx - fs)[legal_f]
    print(f"  30 deg rotation, max source-pixel error from M encoding : {d.max():.6f} px")


if __name__ == "__main__":
    print("S1 error budget - v1 frozen parameter encoding")
    ref.check_against_json()

    e_mode1, _ = analyse("mode 1: static k1/k2, default M from K", CALIB)

    # parameter quantization alone, with distortion disabled, isolates the
    # contribution of fx/fy/cx/cy and M
    pure = ref.CamParams(fx=CALIB.fx, fy=CALIB.fy, cx=CALIB.cx, cy=CALIB.cy)
    e_mode1_undistorted, _ = analyse("mode 1 with k1=k2=0 (pure K + M)", pure)

    matrix_encoding_check()

    print("\n================ SUMMARY ================")
    print(f"  with distortion      : {e_mode1:.6f} px")
    print(f"  without distortion   : {e_mode1_undistorted:.6f} px")
    print(f"  budget               : {BUDGET_PX} px")
    ok = max(e_mode1, e_mode1_undistorted) <= BUDGET_PX
    print(f"  frozen encoding      : {'SUFFICIENT' if ok else 'NOT SUFFICIENT'}")
    raise SystemExit(0 if ok else 1)

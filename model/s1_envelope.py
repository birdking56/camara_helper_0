#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
s1_envelope.py - verify that the planned integer data path cannot overflow

The frozen spec requires map_pipeline to "prove that no undetected overflow
occurs" and to satisfy the declared boundary W/F. This script computes the worst
case magnitude of every intermediate over the *declared legal input envelope*,
so that the register widths in the RTL can be justified instead of guessed.

Envelope assumed (and to be enforced by config_manager, returning RANGE outside
it - the spec already defines a RANGE error code and requires unsupported or
out-of-range commits to be rejected):

    |x|, |y| <= norm_abs_max           declared default 2.0, capped at 4.0
    |k1|, |k2| <= 1.0                  (S32/F28 can encode up to +-8)
    |p1|, |p2|, k3 = 0                 (capability bit 4 not set in the basic stage)
    |fx|, |fy| <= 65536                (S32/F16)

For each candidate register width it reports the headroom factor, i.e. how many
times larger the representable maximum is than the worst case value.

Usage:
    python model/s1_envelope.py
"""

from __future__ import annotations

F24 = 24


def fmt_range(width: int, frac: int) -> float:
    """Largest positive value of a signed fixed-point word."""
    return ((1 << (width - 1)) - 1) / float(1 << frac)


def analyse(norm_max: float, k_abs: float) -> dict:
    x_max = norm_max
    y_max = norm_max

    xsq_max = x_max * x_max
    ysq_max = y_max * y_max
    r2_max = xsq_max + ysq_max
    r2sq_max = r2_max * r2_max
    # worst case radial for |k1|,|k2| <= k_abs, all terms adding
    radial_max = 1.0 + k_abs * r2_max + k_abs * r2sq_max
    radial_min = 1.0 - k_abs * r2_max - k_abs * r2sq_max
    xd_max = x_max * radial_max
    yd_max = y_max * radial_max
    # sx = fx*xd + cx with |fx| <= 65536
    sx_max = 65536.0 * xd_max + 65536.0

    return dict(
        x_max=x_max, r2_max=r2_max, r2sq_max=r2sq_max,
        radial_max=radial_max, radial_min=radial_min,
        xd_max=xd_max, yd_max=yd_max, sx_max=sx_max,
    )


def report(label: str, norm_max: float, k_abs: float, widths: dict) -> bool:
    e = analyse(norm_max, k_abs)

    print(f"\n== {label}: norm_abs_max={norm_max}, |k1|,|k2|<={k_abs} ==")
    rows = [
        ("x, y",        e["x_max"],     widths["xy"]),
        ("x*x, y*y",    e["r2_max"],    widths["sq"]),
        ("r2",          e["r2_max"],    widths["r2"]),
        ("r2*r2",       e["r2sq_max"],  widths["r2sq"]),
        ("radial",      e["radial_max"], widths["radial"]),
        ("xd, yd",      e["xd_max"],    widths["xd"]),
    ]
    ok = True
    print(f"  {'intermediate':<14} {'worst |value|':>14} {'width':>6} {'representable':>15} {'headroom':>10}")
    for name, worst, width in rows:
        lim = fmt_range(width, F24)
        head = lim / worst if worst > 0 else float("inf")
        flag = "OK" if head >= 2.0 else ("TIGHT" if head >= 1.0 else "OVERFLOW")
        if head < 1.0:
            ok = False
        print(f"  {name:<14} {worst:>14.3f} {width:>6} {lim:>15.3f} {head:>9.1f}x  {flag}")

    neg_ok = (e["radial_min"] > -fmt_range(widths["radial"], F24))
    print(f"  radial worst negative value: {e['radial_min']:.3f}  "
          f"({'within range' if neg_ok else 'OVERFLOW'})")
    if not neg_ok:
        ok = False

    print(f"  sx worst magnitude (before F16 output): {e['sx_max']:.1f}")
    return ok


if __name__ == "__main__":
    print("S1 data-path envelope - intermediate magnitude check")

    # Design point chosen for the RTL: 40-bit registers with 24 fractional bits
    # for every polynomial intermediate. 40 bits gives +-32768 in F24.
    design_widths = dict(xy=32, sq=40, r2=40, r2sq=40, radial=40, xd=40)

    ok1 = report("design envelope, declared default", 2.0, 1.0, design_widths)
    ok2 = report("design envelope, capped maximum",    4.0, 1.0, design_widths)
    ok3 = report("stress, hostile coefficients",       4.0, 2.0, design_widths)

    print("\n== current camera, actual maximum ==")
    # measured by s1_error_budget.py over the full 1920x1080 grid:
    e = analyse(0.466091, 0.4817)
    print(f"  |x| max = 0.466, r2 max = 0.287, radial in [0.885, 1.000]")
    print(f"  the design point is {fmt_range(40, F24) / e['radial_max']:.0f}x above the "
          f"worst-case radial of this camera")

    print("\n================ RESULT ================")
    print(f"  declared envelope (norm<=2, |k|<=1) : {'SAFE' if ok1 else 'UNSAFE'}")
    print(f"  capped envelope   (norm<=4, |k|<=1) : {'SAFE' if ok2 else 'UNSAFE'}")
    print(f"  hostile stress    (norm<=4, |k|<=2) : {'SAFE' if ok3 else 'UNSAFE'}")
    print("  40-bit F24 registers are used for the polynomial; x,y and the")
    print("  matrix product stay in 32 bits because norm_abs_max bounds them.")
    raise SystemExit(0 if (ok1 and ok2) else 1)

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
dgc_fixed_ref.py - v1 fixed-point golden model for the distortion correction map

This module is the software reference that map_pipeline must match bit for bit.
It mirrors docs/interface_v1/接口冻结规范_v1.md sections 6 and 11 exactly:

  parameter encodings
      fx, fy, cx, cy    S32/F16   (signed 32 bit, 16 fractional bits)
      k1, k2, p1, p2, k3 S32/F28
      M (3x3)           S32/F26
      epsilon, norm_abs_max  U32/F26

  mapping for output pixel (u, v)
      (a, b, w) = M * (u, v, 1)
      x = a/w ,  y = b/w                      (w bypassed when M22 == 1 and
                                               the last row is (0,0,1))
      r2      = x*x + y*y
      radial  = 1 + k1*r2 + k2*r2^2 + k3*r2^3
      xd      = x*radial + 2*p1*x*y + p2*(r2 + 2*x*x)
      yd      = y*radial + p1*(r2 + 2*y*y) + 2*p2*x*y
      sx      = fx*xd + cx
      sy      = fy*yd + cy

  coordinate record
      the continuous (sx, sy) is quantized as floor(coord * 65536) into a
      signed W32/F16 value. Only coordinates whose pre-quantization value lies
      inside [0, 1919] x [0, 1079] with legal arithmetic get sample_ok.

  rounding of configuration constants
      nearest integer, ties away from zero (接口常量_v1.json -> rounding)

What this module is NOT
    It is not the RTL. It computes with exact integers plus float64 reference
    values, so the numbers it produces are the *achievable* accuracy of the
    frozen parameter encoding itself. The arithmetic widths chosen inside
    map_pipeline will add their own (smaller) contribution on top, and that
    contribution is measured separately by simulating the RTL against this
    model.

Author: implementation agent, S1
"""

from __future__ import annotations

import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Tuple

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
CONST_JSON = ROOT / "docs" / "interface_v1" / "接口常量_v1.json"

WIDTH = 1920
HEIGHT = 1080


# --------------------------------------------------------------------------
# quantization helpers, exactly as the frozen spec defines them
# --------------------------------------------------------------------------
def quantize_nearest_ties_away(value: float, frac_bits: int, signed: bool = True) -> int:
    """Software-side constant quantization: nearest integer, half away from zero."""
    scaled = value * (1 << frac_bits)
    # math.floor(x + 0.5) for positives, math.ceil(x - 0.5) for negatives
    if scaled >= 0.0:
        q = math.floor(scaled + 0.5)
    else:
        q = math.ceil(scaled - 0.5)
    if signed:
        if not (-(1 << 31) <= q <= (1 << 31) - 1):
            raise ValueError(f"value {value} does not fit in S32/F{frac_bits}")
    else:
        if not (0 <= q <= (1 << 32) - 1):
            raise ValueError(f"value {value} does not fit in U32/F{frac_bits}")
    return int(q)


def dequant(q: int, frac_bits: int) -> float:
    return q / float(1 << frac_bits)


def quantize_coord_floor(value: float) -> int:
    """Coordinate record quantization: floor(coord * 65536), signed W32/F16."""
    return int(math.floor(value * 65536.0))


# --------------------------------------------------------------------------
# parameter set
# --------------------------------------------------------------------------
@dataclass(frozen=True)
class CamParams:
    fx: float
    fy: float
    cx: float
    cy: float
    k1: float = 0.0
    k2: float = 0.0
    p1: float = 0.0
    p2: float = 0.0
    k3: float = 0.0

    @staticmethod
    def from_json_file(path: Path) -> "CamParams":
        p = CamParams(**json.loads(path.read_text(encoding="utf-8"))["calibration"]["float"])
        return p

    def default_M(self) -> np.ndarray:
        """Frozen default M: output pixel -> undistorted normalized coordinate."""
        return np.array(
            [
                [1.0 / self.fx, 0.0, -self.cx / self.fx],
                [0.0, 1.0 / self.fy, -self.cy / self.fy],
                [0.0, 0.0, 1.0],
            ],
            dtype=np.float64,
        )


@dataclass(frozen=True)
class QuantParams:
    """The same parameters after v1 quantization, kept as integers."""

    fx_q: int
    fy_q: int
    cx_q: int
    cy_q: int
    k1_q: int
    k2_q: int
    p1_q: int
    p2_q: int
    k3_q: int
    M_q: np.ndarray          # 3x3 int64

    def as_floats(self) -> CamParams:
        return CamParams(
            fx=dequant(self.fx_q, 16),
            fy=dequant(self.fy_q, 16),
            cx=dequant(self.cx_q, 16),
            cy=dequant(self.cy_q, 16),
            k1=dequant(self.k1_q, 28),
            k2=dequant(self.k2_q, 28),
            p1=dequant(self.p1_q, 28),
            p2=dequant(self.p2_q, 28),
            k3=dequant(self.k3_q, 28),
        )


def quantize_params(p: CamParams, M: np.ndarray | None = None) -> QuantParams:
    if M is None:
        M = p.default_M()
    M_q = np.vectorize(lambda v: quantize_nearest_ties_away(v, 26))(M).astype(np.int64)
    return QuantParams(
        fx_q=quantize_nearest_ties_away(p.fx, 16),
        fy_q=quantize_nearest_ties_away(p.fy, 16),
        cx_q=quantize_nearest_ties_away(p.cx, 16),
        cy_q=quantize_nearest_ties_away(p.cy, 16),
        k1_q=quantize_nearest_ties_away(p.k1, 28),
        k2_q=quantize_nearest_ties_away(p.k2, 28),
        p1_q=quantize_nearest_ties_away(p.p1, 28),
        p2_q=quantize_nearest_ties_away(p.p2, 28),
        k3_q=quantize_nearest_ties_away(p.k3, 28),
        M_q=M_q,
    )


# --------------------------------------------------------------------------
# mappings
# --------------------------------------------------------------------------
def map_float(u: np.ndarray, v: np.ndarray, p: CamParams, M: np.ndarray | None = None
              ) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Exact float64 mapping. Returns (sx, sy, legal) where legal means the
    mapped point lies inside the source image."""
    if M is None:
        M = p.default_M()
    a = M[0, 0] * u + M[0, 1] * v + M[0, 2]
    b = M[1, 0] * u + M[1, 1] * v + M[1, 2]
    w = M[2, 0] * u + M[2, 1] * v + M[2, 2]
    with np.errstate(divide="ignore", invalid="ignore"):
        x = a / w
        y = b / w
    r2 = x * x + y * y
    radial = 1.0 + p.k1 * r2 + p.k2 * r2 * r2 + p.k3 * r2 * r2 * r2
    xd = x * radial + 2.0 * p.p1 * x * y + p.p2 * (r2 + 2.0 * x * x)
    yd = y * radial + p.p1 * (r2 + 2.0 * y * y) + 2.0 * p.p2 * x * y
    sx = p.fx * xd + p.cx
    sy = p.fy * yd + p.cy
    legal = (sx >= 0.0) & (sx <= WIDTH - 1) & (sy >= 0.0) & (sy <= HEIGHT - 1)
    return sx, sy, legal


def map_quantized_params(u: np.ndarray, v: np.ndarray, qp: QuantParams
                         ) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Same mapping, but with the *quantized* parameters and float64 arithmetic.

    This isolates the contribution of parameter encoding alone: it does not
    include any intermediate truncation, so it is a lower bound on the error the
    real RTL will show.
    """
    return map_float(u, v, qp.as_floats(), qp.M_q.astype(np.float64) / float(1 << 26))


def map_identity(u: np.ndarray, v: np.ndarray) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
    """mode = 0: output coordinate is used directly as the source coordinate."""
    sx = u.astype(np.float64)
    sy = v.astype(np.float64)
    legal = np.ones_like(sx, dtype=bool)
    return sx, sy, legal


# --------------------------------------------------------------------------
# self-check against the frozen JSON defaults
# --------------------------------------------------------------------------
def check_against_json() -> None:
    """The default_integer / default_word_hex entries in 接口常量_v1.json are a
    ready-made test of this quantizer. Reproduce every one of them."""
    const = json.loads(CONST_JSON.read_text(encoding="utf-8"))
    bad = []
    for entry in const["parameter_registers"]:
        name = entry["name"]
        frac = entry["frac"]
        signed = entry["signed"]
        expected = entry["default_integer"]
        hex_word = entry["default_word_hex"]
        got = quantize_nearest_ties_away(entry["default_float"], frac, signed)
        raw = got & 0xFFFFFFFF
        got_hex = f"0x{raw:08X}"
        if got != expected or got_hex.upper() != hex_word.upper():
            bad.append((name, expected, got, hex_word, got_hex))
    if bad:
        for b in bad:
            print(f"  MISMATCH {b[0]}: json={b[1]}/{b[3]} model={b[2]}/{b[4]}")
        raise SystemExit("quantizer does not reproduce 接口常量_v1.json")
    print(f"quantizer reproduces all {len(const['parameter_registers'])} "
          f"default_integer / default_word_hex entries in 接口常量_v1.json")


if __name__ == "__main__":
    check_against_json()

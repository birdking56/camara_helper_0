"""Audit board constants and produce a full MODE=1 image reference.

Mapping uses the F24/F16 integer contract; a separate float64 map from the
original calibration checks sign, normalization, projection and quantization.
The reference image encodes R=x%256, G=y%256, B=R^G, matching tb_dgc_core.
"""
import json
import re
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]


def main():
    contract = json.loads((ROOT / 'docs/interface_v1/接口常量_v1.json').read_text(encoding='utf-8'))
    source = (ROOT / 'source/top/dgc_top_sys.v').read_text(encoding='utf-8')
    constants = {
        m[0]: (-1 if m[1] else 1) * int(m[2])
        for m in re.findall(r"localparam\s+(?:signed\s+)?\[31:0\]\s+CFG_(\w+)\s*=\s*(-?)32's?d(\d+)", source)
    }
    for entry in contract['parameter_registers']:
        name = entry['name'].upper()
        if name in constants:
            assert constants[name] == entry['default_integer'], (name, constants[name], entry)

    v, u = np.mgrid[:1080, :1920].astype(np.int64)
    q = constants
    x = (q['M00'] * u + q['M02']) >> 2
    y = (q['M11'] * v + q['M12']) >> 2
    r2 = ((x * x) >> 24) + ((y * y) >> 24)
    r4 = (r2 * r2) >> 24
    radial = (1 << 24) + ((q['K1'] * r2) >> 28) + ((q['K2'] * r4) >> 28)
    sx = ((q['FX'] * ((x * radial) >> 24)) >> 24) + q['CX']
    sy = ((q['FY'] * ((y * radial) >> 24)) >> 24) + q['CY']
    legal = (sx >= 0) & (sx <= 1919 * 65536) & (sy >= 0) & (sy <= 1079 * 65536)

    # Independent float64 Brown radial map: output -> distorted source.
    c = contract['calibration_float']
    xf = (u - c['cx']) / c['fx']
    yf = (v - c['cy']) / c['fy']
    rf = xf * xf + yf * yf
    scale = 1.0 + c['k1'] * rf + c['k2'] * rf * rf
    ideal_x = c['fx'] * xf * scale + c['cx']
    ideal_y = c['fy'] * yf * scale + c['cy']
    error = np.maximum(np.abs(sx / 65536.0 - ideal_x), np.abs(sy / 65536.0 - ideal_y))
    assert legal.all(), 'Default calibration unexpectedly maps out of bounds'
    assert error.max() < 0.1, float(error.max())

    x0, y0 = sx >> 16, sy >> 16
    x1, y1 = np.minimum(x0 + 1, 1919), np.minimum(y0 + 1, 1079)
    wx, wy = sx & 65535, sy & 65535
    weights = [(65536-wx)*(65536-wy), wx*(65536-wy), (65536-wx)*wy, wx*wy]
    channels = [np.zeros_like(u) for _ in range(3)]
    for px, py, weight in zip((x0, x1, x0, x1), (y0, y0, y1, y1), weights):
        for total, value in zip(channels, (px & 255, py & 255, (px ^ py) & 255)):
            total += value * weight
    red, green, blue = [(total + (1 << 31)) >> 32 for total in channels]
    pixels = (red << 16) | (green << 8) | blue
    folder = ROOT / 'sim/s4_core/vectors'
    folder.mkdir(exist_ok=True)
    np.savetxt(folder / 'radial_expected.hex', pixels.reshape(-1), fmt='%06x')
    summary = {
        'board_default_mode': int(re.search(r'parameter integer MODE\s*=\s*(\d+)', source)[1]),
        'constants_match_contract': True,
        'legal_pixels': int(legal.sum()),
        'max_coordinate_error_px': float(error.max()),
        'expected_pixels': int(pixels.size),
        'corner_top_left_source_px': [float(sx[0, 0]/65536.0), float(sy[0, 0]/65536.0)],
        'corner_bottom_right_source_px': [float(sx[-1, -1]/65536.0), float(sy[-1, -1]/65536.0)],
    }
    text = json.dumps(summary, indent=2)
    (folder / 'radial_audit.json').write_text(text + '\n', encoding='utf-8')
    print(text)


if __name__ == '__main__':
    main()

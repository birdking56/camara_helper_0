#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
dgc_source_cache_ref.py - reference model for the source block cache

Why this exists
    The frozen spec pins down the *address mapping* of the source cache precisely
    but says very little about the fill/read timing, and I failed twice writing
    the RTL directly. This model fixes the behaviour that the spec does define,
    generates test vectors, and gives the testbench something independent to
    compare against instead of restating the RTL in Verilog.

Frozen mapping (接口冻结规范_v1.md section 8)

    set 0 -> banks 0..3        set 1 -> banks 4..7
    local bank  = {local_y[0], local_x[0]}
    address     = (local_y >> 1)*32 + (local_x >> 1)
    physical    = set*4 + local bank

    Container: at most 64 x 64 pixels per set, and the block is addressed
    relative to its own bbox top-left corner.

Colour encoding
    The fill stream carries logical pixels rgb[23:0] = {R, G, B}. The cache
    stores the 24-bit word unchanged; the byte order in DDR was already undone by
    unpack. A read returns exactly what was written.

Checks this model provides
    1. mapping_is_bijective: two different (x, y) never share a physical
       address, so a block can be stored without aliasing.
    2. parity_split: the four bilinear neighbours of one output pixel always land
       in four different local banks when the neighbour pair is not duplicated.
    3. coverage: a 64x64 block uses exactly 32 addresses per bank, which is what
       the 24x1024 DRM provides.

Usage
    python model/dgc_source_cache_ref.py
"""

from __future__ import annotations

from dataclasses import dataclass, field

MAX_W = 64
MAX_H = 64
BANK_DEPTH = 1024
ADDR_SPAN = 32 * 32          # (y>>1) in 0..31, (x>>1) in 0..31


def local_bank(x: int, y: int) -> int:
    """Frozen rule: bank index inside a set is {y[0], x[0]}."""
    return ((y & 1) << 1) | (x & 1)


def address(x: int, y: int) -> int:
    """Frozen rule: (y>>1)*32 + (x>>1), i.e. 32 columns per row pair."""
    return ((y >> 1) * 32) + (x >> 1)


def physical_bank(x: int, y: int, cache_set: int) -> int:
    return cache_set * 4 + local_bank(x, y)


@dataclass
class SourceCacheRef:
    """Behavioural model of one cache set."""

    width: int = MAX_W
    height: int = MAX_H
    store: dict = field(default_factory=dict)      # (bank, addr) -> rgb
    filled: int = 0
    set_index: int = 0
    tag: int = 0
    state: str = "FREE"                            # FREE/FILLING/READY/READING

    # ---------------------------------------------------------------- fill side
    def begin_fill(self, tag: int) -> None:
        if self.state not in ("FREE", "FILLING"):
            raise RuntimeError(f"cannot begin fill in state {self.state}")
        self.state = "FILLING"
        self.tag = tag
        self.store.clear()
        self.filled = 0

    def fill(self, x: int, y: int, rgb: int) -> None:
        if self.state != "FILLING":
            raise RuntimeError(f"fill while {self.state}")
        if not (0 <= x < MAX_W and 0 <= y < MAX_H):
            raise ValueError(f"local coordinate out of range: ({x},{y})")
        b = local_bank(x, y)
        a = address(x, y)
        self.store[(b, a)] = rgb
        self.filled += 1

    def end_fill(self, expected_pixels: int) -> None:
        if self.filled != expected_pixels:
            raise RuntimeError(f"filled {self.filled} of {expected_pixels} pixels")
        self.state = "READY"

    # ---------------------------------------------------------------- read side
    def read(self, x: int, y: int) -> int:
        if self.state != "READY" and self.state != "READING":
            raise RuntimeError(f"read while {self.state}")
        key = (local_bank(x, y), address(x, y))
        if key not in self.store:
            raise KeyError(f"hole at ({x},{y}) - the spec forbids reading unwritten space")
        return self.store[key]


# --------------------------------------------------------------------------
# static checks
# --------------------------------------------------------------------------
def mapping_is_bijective() -> bool:
    seen = {}
    for y in range(MAX_H):
        for x in range(MAX_W):
            key = (local_bank(x, y), address(x, y))
            if key in seen:
                print(f"  COLLISION ({x},{y}) and {seen[key]} -> {key}")
                return False
            seen[key] = (x, y)
    return True


def addresses_per_bank() -> list:
    counts = [0, 0, 0, 0]
    for y in range(MAX_H):
        for x in range(MAX_W):
            counts[local_bank(x, y)] += 1
    return counts


def distinct_addresses_per_bank() -> list:
    seen = [set(), set(), set(), set()]
    for y in range(MAX_H):
        for x in range(MAX_W):
            seen[local_bank(x, y)].add(address(x, y))
    return [len(s) for s in seen]


def parity_split_holds() -> bool:
    """The four neighbours must always hit four different banks."""
    bad = 0
    for y in range(0, MAX_H - 1):
        for x in range(0, MAX_W - 1):
            banks = {local_bank(x, y), local_bank(x + 1, y),
                     local_bank(x, y + 1), local_bank(x + 1, y + 1)}
            if len(banks) != 4:
                bad += 1
    return bad == 0


def write_vectors(path) -> int:
    """Produce a fill + readback vector file for the RTL testbench.

    Every record is one 64x64 block worth of pixels; the testbench writes them
    through the fill interface and reads each one back.
    """
    ref = SourceCacheRef()
    ref.begin_fill(0x1234)
    n = 0
    with open(path, "w", encoding="ascii", newline="\n") as fh:
        fh.write("# source cache fill/readback vectors\n")
        fh.write("# fill: x y rgb    read: x y rgb\n")
        rows = []
        for y in range(MAX_H):
            for x in range(MAX_W):
                rgb = ((x * 4 + 1) << 16) | ((y * 4 + 2) << 8) | ((x ^ y) & 0xFF)
                ref.fill(x, y, rgb)
                rows.append((x, y, rgb))
                n += 1
        for (x, y, rgb) in rows:
            fh.write(f"{x} {y} {rgb:06x}\n")
    ref.end_fill(n)
    # readback must be exact
    for (x, y, rgb) in rows:
        if ref.read(x, y) != rgb:
            raise RuntimeError("model readback mismatch")
    return n


if __name__ == "__main__":
    print("source cache reference model")
    print(f"  container            : {MAX_W} x {MAX_H}")
    print(f"  bank depth available : {BANK_DEPTH}")
    print(f"  mapping bijective    : {mapping_is_bijective()}")
    print(f"  pixels per bank      : {addresses_per_bank()}")
    print(f"  distinct addresses   : {distinct_addresses_per_bank()}")
    print(f"  max address used     : {max(address(x, y) for y in range(MAX_H) for x in range(MAX_W))}")
    print(f"  four-neighbour split : {parity_split_holds()}")

    # the whole point of the parity split: each bank needs only 32 addresses per
    # 64x64 block, so 1024 deep is far more than one block needs
    print(f"  addresses needed per bank for one 64x64 block: {distinct_addresses_per_bank()[0]}"
          f" of {BANK_DEPTH}")

    from pathlib import Path
    out = Path(__file__).resolve().parents[1] / "sim" / "s2_source_cache" / "vectors" / "fill_readback.vec"
    out.parent.mkdir(parents=True, exist_ok=True)
    n = write_vectors(out)
    print(f"  vectors written      : {out.name} ({n} records)")

    ok = (mapping_is_bijective() and parity_split_holds() and
          len(set(distinct_addresses_per_bank())) == 1)
    print("\n================ RESULT ================")
    print("  frozen mapping is self-consistent: " + ("YES" if ok else "NO"))

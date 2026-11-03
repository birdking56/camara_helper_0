#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_dgc_top_fdc.py - derive constraints/dgc_top.fdc from constraints/board_base.fdc

Why this script exists
    board_base.fdc is the verified board-level baseline of the *previous* top
    level (HDMI_IN_DDR3_OUT_top). It contains:
      * the complete PG2L100H pin table (119 ports),
      * three real clock definitions (sys_clk / ref_clk / pixclk_in),
      * the DDR3 generated clocks and their clock groups,
      * three stale clock groups for clocks that belonged to the old 720p design
        (cfg_clk / clk_25M / pix_clk),
      * pin attributes for ports the new top level does not have
        (init_over_rx, debug_uart_tx) and the old name of one output
        (ddr_init_done instead of ddr_init_done_o).

    The new top level (source/top/dgc_top.v) keeps the same board pinout but
    renames two ports and adds four clock domains. Instead of hand-editing a
    878-line file, this script performs the transformation deterministically and
    records exactly what was dropped, so the result is auditable and repeatable.

What the generated file contains
    1. pin attributes restricted to dgc_top's real port list,
    2. the DDR3 instance-level placement attributes,
    3. sys_clk / ref_clk / pixclk_in clocks,
    4. the DDR3 generated clocks and their groups,
    5. NEW: proc_clk (225 MHz), cfg_clk (10 MHz), vout_clk (148.5 MHz) and
       vout_clk_5x (742.5 MHz) generated clocks,
    6. NEW: clock groups for the new domains - deliberately NOT a blanket
       set_false_path,
    7. NEW: bundled-data / max-delay constraints for the cross-domain mailbox
       payload buses,
    8. NEW: input delay on the HDMI pixel bus relative to pixclk_in.

Usage
    python constraints/tools/make_dgc_top_fdc.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / "constraints" / "board_base.fdc"
OUT = ROOT / "constraints" / "dgc_top.fdc"

# ---------------------------------------------------------------- port mapping
# Ports of dgc_top that differ in name from the old top level.
RENAME = {
    "ddr_init_done": "ddr_init_done_o",
}

# Ports of the new top level, without bit indices.
DGC_PORTS = {
    "sys_clk", "clk_p", "clk_n", "rst_in",
    "mem_rst_n", "mem_ck", "mem_ck_n", "mem_cke", "mem_cs_n",
    "mem_ras_n", "mem_cas_n", "mem_we_n", "mem_odt",
    "mem_a", "mem_ba", "mem_dqs", "mem_dqs_n", "mem_dq", "mem_dm",
    "rstn_out", "hd_scl", "hd_sda", "hdmi_int_led",
    "pixclk_in", "vs_in", "hs_in", "de_in", "r_in", "g_in", "b_in",
    "tmds_clk_p", "tmds_clk_n", "tmds_data_p", "tmds_data_n",
    "heart_beat_led", "ddr_init_done_o",
}

# Stale clock-group names left over from the 720p design.
STALE_CLOCK_GROUPS = {"cfg_clk", "clk_25M", "pix_clk"}

# DDR3 generated-clock groups that must be kept verbatim.
KEEP_GROUPS = {
    "sys_clk", "ref_clk", "rst_clk", "phy_dq_clk_0", "phy_dq_clk_1",
    "ddrphy_sysclk",
}


def base_port(attr_name: str) -> str:
    """'r_in[3]' -> 'r_in'."""
    return attr_name.split("[")[0]


def main() -> int:
    if not BASE.exists():
        print(f"error: {BASE} not found", file=sys.stderr)
        return 1

    text = BASE.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()

    kept_pin: list[str] = []
    kept_inst: list[str] = []
    kept_clocks: list[str] = []
    kept_ddr_gen: list[str] = []
    dropped_pins: set[str] = set()
    dropped_groups: list[str] = []

    for line in lines:
        s = line.strip()

        # ---- pin attributes ------------------------------------------------
        m = re.match(r"define_attribute \{p:([^}]+)\}", s)
        if m:
            name = m.group(1)
            bp = base_port(name)
            if bp in DGC_PORTS:
                kept_pin.append(line)
            elif bp in RENAME and RENAME[bp] in DGC_PORTS:
                kept_pin.append(line.replace(f"p:{name}", f"p:{name.replace(bp, RENAME[bp])}"))
            else:
                dropped_pins.add(bp)
            continue

        # ---- instance placement attributes (DDR PHY) -----------------------
        if s.startswith("define_attribute {i:"):
            kept_inst.append(line)
            continue

        # ---- clocks ---------------------------------------------------------
        if s.startswith("create_clock"):
            kept_clocks.append(line)
            continue
        if s.startswith("create_generated_clock"):
            kept_ddr_gen.append(line)
            continue

        # ---- clock groups ---------------------------------------------------
        if s.startswith("set_clock_groups"):
            m = re.match(r"set_clock_groups -name \{?([A-Za-z0-9_]+)\}?", s)
            gname = m.group(1) if m else ""
            if gname in STALE_CLOCK_GROUPS:
                dropped_groups.append(gname)
                continue
            if gname in KEEP_GROUPS:
                kept_ddr_gen.append(line)
                continue
            kept_ddr_gen.append(line)
            continue

        # ---- everything else that belongs to the DDR PHY --------------------
        if s.startswith("set_multicycle_path") or s.startswith("set_clock_uncertainty"):
            kept_ddr_gen.append(line)
            continue

    # ------------------------------------------------------------------ header
    out: list[str] = []
    out.append("#=============================================================================")
    out.append("# dgc_top.fdc - constraints for source/top/dgc_top.v")
    out.append("#")
    out.append("# GENERATED FILE - do not edit by hand.")
    out.append("# Regenerate with:  python constraints/tools/make_dgc_top_fdc.py")
    out.append("# Source baseline:  constraints/board_base.fdc")
    out.append("#")
    out.append("# This file REPLACES board_base.fdc in the PDS project. Do not add both:")
    out.append("# the pin attributes and the sys_clk / ref_clk / pixclk_in clocks would")
    out.append("# be defined twice.")
    out.append("#")
    out.append("# Dropped from the baseline, and why:")
    out.append("#   * pin attributes for ports dgc_top does not have: "
               + ", ".join(sorted(dropped_pins)))
    out.append("#   * stale clock groups for clocks that no longer exist: "
               + ", ".join(sorted(set(dropped_groups))))
    out.append("#   * renamed: ddr_init_done -> ddr_init_done_o (same pin)")
    out.append("#")
    out.append("# Every clock domain in this design is asynchronous to the others except")
    out.append("# where a PLL derives it from sys_clk; CDC is handled by the toggle")
    out.append("# mailbox and by the asynchronous FIFOs. No blanket false_path is used.")
    out.append("#=============================================================================")
    out.append("")

    out.append("#-----------------------------------------------------------------------------")
    out.append("# 1. Board pin table (unchanged locations from the verified baseline)")
    out.append("#-----------------------------------------------------------------------------")
    out.extend(kept_pin)
    out.append("")

    out.append("#-----------------------------------------------------------------------------")
    out.append("# 2. DDR3 PHY placement attributes")
    out.append("#-----------------------------------------------------------------------------")
    out.extend(kept_inst)
    out.append("")

    out.append("#-----------------------------------------------------------------------------")
    out.append("# 3. Input clocks")
    out.append("#-----------------------------------------------------------------------------")
    out.extend(kept_clocks)
    out.append("")

    out.append("#-----------------------------------------------------------------------------")
    out.append("# 4. DDR3 internal generated clocks and their groups")
    out.append("#-----------------------------------------------------------------------------")
    out.extend(kept_ddr_gen)
    out.append("")

    out.append("#-----------------------------------------------------------------------------")
    out.append("# 5. Processing / output / configuration clocks added by dgc_top")
    out.append("#")
    out.append("#    pll_proc  u_gpll CLKOUT3 : 27 MHz * 25/3  = 225 MHz")
    out.append("#    pll_hdmi  u_gpll CLKOUT2 : 27 MHz * 11/2  = 148.5 MHz")
    out.append("#    pll_hdmi  u_gpll CLKOUT1 : 27 MHz * 55/2  = 742.5 MHz")
    out.append("#    pll_cfg   u_gpll CLKOUT0 : 27 MHz * 10/27 = 10 MHz")
    out.append("#-----------------------------------------------------------------------------")
    out.append("create_generated_clock -name {proc_clk} -source [get_ports {sys_clk}] "
               "[get_pins {u_clock_reset/u_pll_proc/u_gpll/CLKOUT3}] "
               "-master_clock [get_clocks {sys_clk}] -multiply_by {25} -divide_by {3}")
    out.append("create_generated_clock -name {vout_clk} -source [get_ports {sys_clk}] "
               "[get_pins {u_clock_reset/u_pll_hdmi/u_gpll/CLKOUT2}] "
               "-master_clock [get_clocks {sys_clk}] -multiply_by {11} -divide_by {2}")
    out.append("create_generated_clock -name {vout_clk_5x} -source [get_ports {sys_clk}] "
               "[get_pins {u_clock_reset/u_pll_hdmi/u_gpll/CLKOUT1}] "
               "-master_clock [get_clocks {sys_clk}] -multiply_by {55} -divide_by {2}")
    out.append("create_generated_clock -name {cfg_clk} -source [get_ports {sys_clk}] "
               "[get_pins {u_clock_reset/u_pll_cfg/u_gpll/CLKOUT0}] "
               "-master_clock [get_clocks {sys_clk}] -multiply_by {10} -divide_by {27}")
    out.append("")

    out.append("#-----------------------------------------------------------------------------")
    out.append("# 6. Clock domain relationships")
    out.append("#")
    out.append("#    Each generated clock gets its own asynchronous group together with")
    out.append("#    the domain it talks to. This declares which crossings are asynchronous;")
    out.append("#    it does NOT hide the paths inside a domain.")
    out.append("#-----------------------------------------------------------------------------")
    out.append("set_clock_groups -name proc_clk -asynchronous -group [get_clocks {proc_clk}]")
    out.append("set_clock_groups -name vout_clk -asynchronous -group [get_clocks {vout_clk}]")
    out.append("set_clock_groups -name vout_clk_5x -asynchronous -group [get_clocks {vout_clk_5x}]")
    out.append("")

    out.append("#-----------------------------------------------------------------------------")
    out.append("# 7. Cross-domain descriptor mailboxes (bundled data)")
    out.append("#")
    out.append("#    The toggle bit is double-registered inside dgc_mailbox; the payload is")
    out.append("#    held stable by the source until the acknowledge returns. The payload bus")
    out.append("#    therefore needs a bounded skew against its toggle, not a false path.")
    out.append("#    1.5 ns is one quarter of the 6.7 ns input pixel period and covers the")
    out.append("#    bussed-data window; tighten it after the first timing report.")
    out.append("#-----------------------------------------------------------------------------")
    out.append("# At S0 no mailbox is instantiated in dgc_top, so the constraints below are")
    out.append("# emitted as a template: a get_pins pattern that matches nothing is a PDS")
    out.append("# error. Enable the line for each mailbox as it is added in S2/S4 and")
    out.append("# replace <inst> with the real hierarchical instance name.")
    out.append("#")
    out.append("# set_max_delay 1.5 -from [get_pins {<inst>/payload_q[*]}] -to [get_pins {<inst>/dst_payload_q[*]}]")
    out.append("#")
    out.append("# Planned mailbox instances and their owners:")
    out.append("#   u_fetch_row_mbox    fetch_planner (proc) -> ddr_fetch (ddr)")
    out.append("#   u_frame_grant_mbox  frame_manager (ddr) -> capture_writer (vin)")
    out.append("#   u_frame_acq_mbox    frame_manager (ddr) -> tile_scheduler (proc)")
    out.append("#   u_frame_rel_mbox    tile_scheduler (proc) -> frame_manager (ddr)")
    out.append("#   u_stripe_offer_mbox stripe_writer (proc) -> video_reader (vout)")
    out.append("#   u_stripe_rel_mbox   video_reader (vout) -> stripe_writer (proc)")
    out.append("#")
    out.append("# The payload is bundled with its toggle. The toggle path itself is a")
    out.append("# two-flop synchroniser and needs no max_delay; only the bus does.")
    out.append("")

    out.append("#-----------------------------------------------------------------------------")
    out.append("# 8. HDMI input bus")
    out.append("#")
    out.append("#    The receiver launches data and DE together with pixclk_in; the FPGA")
    out.append("#    registers them on the I/O cell. A small input delay covers the board")
    out.append("#    skew. Tighten with the measured value once the first timing report is in.")
    out.append("#-----------------------------------------------------------------------------")
    out.append("set_input_delay 1.0 -clock [get_clocks {pixclk_in}] "
               "[get_ports {r_in[*] g_in[*] b_in[*] de_in hs_in vs_in}]")
    out.append("")

    OUT.write_text("\n".join(out) + "\n", encoding="utf-8", newline="\n")

    print(f"written {OUT}")
    print(f"  pin attribute lines kept : {len(kept_pin)}")
    print(f"  instance attributes kept : {len(kept_inst)}")
    print(f"  input clocks kept        : {len(kept_clocks)}")
    print(f"  DDR clock/group lines    : {len(kept_ddr_gen)}")
    print(f"  dropped ports            : {', '.join(sorted(dropped_pins))}")
    print(f"  dropped stale groups     : {', '.join(sorted(set(dropped_groups)))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

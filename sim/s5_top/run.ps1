$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

# All core_sys RTL and generated IP models (same list as s5_sys).
$src = @(& (Join-Path $root "sim\_s5_sys_compile\sources.ps1"))
# Keep the real stripe RAM wrappers for elaboration (s5_sys replaces them with a
# behavioural model for visibility; here we want the real port list checked).
$src += @(
    "$root\source\top\dgc_clock_reset.v",
    "$root\source\top\dgc_top_sys.v",
    "$root\source\debug\dgc_input_timing.v",
    "$root\source\debug\dgc_snapshot_src.v",
    "$root\source\debug\dgc_snapshot_hub.v",
    "$root\source\rtl\sync_vg.v",
    "$root\source\hdmi\rgb2tmds.v",
    "$root\source\hdmi\tmds_encoder.v",
    "$root\source\hdmi\outputserdes.v",
    "$root\source\hdmi\ms72xx_ctl.v",
    "$root\source\hdmi\ms7200_ctl.v",
    "$root\source\hdmi\ms7210_ctl.v",
    "$root\source\hdmi\iic_dri.v",
    "$root\ipcore\pll_proc\pll_proc.v",
    "$root\ipcore\pll_cfg\pll_cfg.v",
    "$root\ipcore\pll_hdmi\pll_hdmi.v",
    "$PSScriptRoot\..\s0_top\ddr3_test_sim_stub.v",
    "$PSScriptRoot\tb_top_sys.v"
)

& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_top_sys -Name s5_top -Sources $src `
    -IncDirs @("$root\sim\common") `
    -VlogArgs @("+define+DGC_SIM", "-suppress", "2388") -TimeoutSec 1800
exit $LASTEXITCODE

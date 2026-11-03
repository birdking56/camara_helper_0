# S0: top-level clocks / resets / output timing acceptance.
#
# ddr3_test is replaced by sim/s0_top/ddr3_test_sim_stub.v: the vendor PHY is
# IEEE-1735 encrypted and cannot be decrypted by this Questa installation.
# See the S0 acceptance report for the exact limitation and the S2 follow-up.
$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

$src = @(
    "$root\source\common\dgc_rst_sync.v",
    "$root\source\top\dgc_clock_reset.v",
    "$root\source\top\dgc_s0_pattern.v",
    "$root\source\top\dgc_top.v",
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
    "$PSScriptRoot\ddr3_test_sim_stub.v",
    "$PSScriptRoot\tb_dgc_top.v"
)

& (Join-Path $root "sim\tools\run_test.ps1") `
    -Top      tb_dgc_top `
    -Name     s0_top `
    -Sources  $src `
    -IncDirs  @("$root\sim\common") `
    -VlogArgs @("+define+DGC_SIM", "-suppress", "2388") `
    -TimeoutSec 1800
exit $LASTEXITCODE

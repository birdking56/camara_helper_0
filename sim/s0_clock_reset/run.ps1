# S0: clock generation and reset gating (real PLL IP models).
$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

$src = @(
    "$root\source\common\dgc_rst_sync.v",
    "$root\source\top\dgc_clock_reset.v",
    "$root\ipcore\pll_proc\pll_proc.v",
    "$root\ipcore\pll_cfg\pll_cfg.v",
    "$root\ipcore\pll_hdmi\pll_hdmi.v",
    "$PSScriptRoot\tb_clock_reset.v"
)

& (Join-Path $root "sim\tools\run_test.ps1") `
    -Top      tb_clock_reset `
    -Name     s0_clock_reset `
    -Sources  $src `
    -IncDirs  @("$root\sim\common") `
    -TimeoutSec 900
exit $LASTEXITCODE

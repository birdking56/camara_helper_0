# S0: 1080p60 output timing generator acceptance.
$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

$src = @(
    "$root\source\rtl\sync_vg.v",
    "$PSScriptRoot\tb_out_timing.v"
)

& (Join-Path $root "sim\tools\run_test.ps1") `
    -Top      tb_out_timing `
    -Name     s0_out_timing `
    -Sources  $src `
    -IncDirs  @("$root\sim\common") `
    -TimeoutSec 900
exit $LASTEXITCODE

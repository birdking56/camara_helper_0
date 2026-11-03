# S1: directed boundary and error cases for map_pipeline.
$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

$src = @(
    "$root\source\geometry\dgc_mul_pipe.v",
    "$root\source\geometry\dgc_map_pipeline.v",
    "$PSScriptRoot\tb_map_edge.v"
)

& (Join-Path $root "sim\tools\run_test.ps1") `
    -Top      tb_map_edge `
    -Name     s1_map_edge `
    -Sources  $src `
    -IncDirs  @("$root\sim\common") `
    -TimeoutSec 600
exit $LASTEXITCODE

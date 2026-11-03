$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$src = @(
    "$root\source\geometry\dgc_mul_pipe.v",
    "$root\source\geometry\dgc_map_pipeline.v",
    "$PSScriptRoot\tb_map_single.v"
)
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_map_single -Name _map_single `
    -Sources $src -IncDirs @("$root\sim\common") -TimeoutSec 300
exit $LASTEXITCODE

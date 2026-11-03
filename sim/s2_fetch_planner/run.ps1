$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$src = @(
    "$root\source\fetch\dgc_fetch_walk.v",
    "$root\source\fetch\dgc_fetch_row_plan.v",
    "$root\source\fetch\dgc_fetch_planner.v",
    "$PSScriptRoot\tb_fetch_planner.v"
)
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_fetch_planner -Name s2_fetch_planner -Sources $src -IncDirs @("$root\sim\common") -TimeoutSec 600
exit $LASTEXITCODE

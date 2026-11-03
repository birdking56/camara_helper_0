$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_fetch_row_plan -Name s2_fetch_row -Sources @("$root\source\fetch\dgc_fetch_row_plan.v","$PSScriptRoot\tb_fetch_row_plan.v") -IncDirs @("$root\sim\common") -TimeoutSec 300
exit $LASTEXITCODE

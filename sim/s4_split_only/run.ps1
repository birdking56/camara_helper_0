$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_split_only -Name s4_split_only -Sources @("$root\source\control\dgc_tile_scheduler.v","$PSScriptRoot\tb_split_only.v") -IncDirs @("$root\sim\common") -TimeoutSec 300
exit $LASTEXITCODE

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_split_nested -Name s4_split_nested -Sources @("$root\source\control\dgc_tile_scheduler.v","$PSScriptRoot\tb_split_nested.v") -IncDirs @("$root\sim\common") -TimeoutSec 300
exit $LASTEXITCODE

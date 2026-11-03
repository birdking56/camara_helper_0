$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$src = @("$root\source\control\dgc_tile_scheduler.v", "$PSScriptRoot\tb_tile_sched.v")
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_tile_sched -Name s4_tile_sched -Sources $src -IncDirs @("$root\sim\common") -TimeoutSec 300
exit $LASTEXITCODE

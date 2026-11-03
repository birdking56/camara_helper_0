$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_x -Name probe_fail -Sources @("$PSScriptRoot\tb_x.v") -IncDirs @("$root\sim\common") -TimeoutSec 60
exit $LASTEXITCODE

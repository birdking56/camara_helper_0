$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_fetch_walk -Name s2_fetch_walk -Sources @("$root\source\fetch\dgc_fetch_walk.v","$PSScriptRoot\tb_fetch_walk.v") -IncDirs @("$root\sim\common") -TimeoutSec 200
exit $LASTEXITCODE

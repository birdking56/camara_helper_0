$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_counters -Name s2_counters -Sources @("$root\source\control\dgc_counters.v","$PSScriptRoot\tb_counters.v") -IncDirs @("$root\sim\common") -TimeoutSec 300
exit $LASTEXITCODE

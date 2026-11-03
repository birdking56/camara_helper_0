$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_rlast_check -Name s2_rlast_check -Sources @("$root\source\fetch\dgc_rlast_check.v","$PSScriptRoot\tb_rlast_check.v") -IncDirs @("$root\sim\common") -TimeoutSec 300
exit $LASTEXITCODE

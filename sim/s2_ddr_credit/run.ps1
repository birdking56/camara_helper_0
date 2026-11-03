$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_ddr_credit -Name s2_ddr_credit -Sources @("$root\source\fetch\dgc_ddr_credit.v","$PSScriptRoot\tb_ddr_credit.v") -IncDirs @("$root\sim\common") -TimeoutSec 300
exit $LASTEXITCODE

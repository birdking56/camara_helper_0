$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_credit_probe -Name s2_credit_probe -Sources @("$root\source\fetch\dgc_ddr_credit.v","$PSScriptRoot\tb_credit_probe.v") -IncDirs @("$root\sim\common") -TimeoutSec 200
exit $LASTEXITCODE

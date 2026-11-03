$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_stripe_scan -Name s4_stripe_scan -Sources @("$root\source\display\dgc_stripe_scan.v","$PSScriptRoot\tb_stripe_scan.v") -IncDirs @("$root\sim\common") -TimeoutSec 300
exit $LASTEXITCODE

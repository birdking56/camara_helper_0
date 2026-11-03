$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_native_split -Name s2_native_split -Sources @("$root\source\fetch\dgc_native_split.v","$PSScriptRoot\tb_native_split.v") -IncDirs @("$root\sim\common") -TimeoutSec 300
exit $LASTEXITCODE

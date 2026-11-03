$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_capture_pack -Name s2_capture_pack -Sources @("$root\source\capture\dgc_capture_pack.v","$PSScriptRoot\tb_capture_pack.v") -IncDirs @("$root\sim\common") -TimeoutSec 300
exit $LASTEXITCODE

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_capture_writer -Name s2_capture_writer -Sources @("$root\source\capture\dgc_capture_writer.v","$root\source\capture\dgc_capture_pack.v","$PSScriptRoot\tb_capture_writer.v") -IncDirs @("$root\sim\common") -TimeoutSec 200
exit $LASTEXITCODE

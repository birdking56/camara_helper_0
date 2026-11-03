$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_sample_dedup -Name s2_sample_dedup -Sources @("$root\source\cache\dgc_sample_dedup.v","$PSScriptRoot\tb_sample_dedup.v") -IncDirs @("$root\sim\common") -TimeoutSec 300
exit $LASTEXITCODE

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_src_addr -Name s2_src_addr -Sources @("$root\source\cache\dgc_src_addr.v","$PSScriptRoot\tb_src_addr.v") -IncDirs @("$root\sim\common") -TimeoutSec 300
exit $LASTEXITCODE

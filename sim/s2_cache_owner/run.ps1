$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_cache_owner -Name s2_cache_owner -Sources @("$root\source\cache\dgc_cache_owner.v","$PSScriptRoot\tb_cache_owner.v") -IncDirs @("$root\sim\common") -TimeoutSec 200
exit $LASTEXITCODE

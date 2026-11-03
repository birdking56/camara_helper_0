$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_neighbour_calc -Name s2_neighbour -Sources @("$root\source\cache\dgc_neighbour_calc.v","$PSScriptRoot\tb_neighbour_calc.v") -IncDirs @("$root\sim\common") -TimeoutSec 300
exit $LASTEXITCODE

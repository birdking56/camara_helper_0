$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$src = @("$root\source\cache\dgc_neighbour_calc.v","$root\source\cache\dgc_sample_dedup.v",
         "$PSScriptRoot\tb_sampler_path.v")
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_sampler_path -Name s2_sampler_path -Sources $src -IncDirs @("$root\sim\common") -TimeoutSec 200
exit $LASTEXITCODE

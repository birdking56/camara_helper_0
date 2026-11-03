$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$src = @("$root\source\geometry\dgc_mul_pipe.v",
    "$root\source\geometry\dgc_map_pipeline.v",
         "$root\source\process\dgc_gamma_stage.v",
         "$root\source\process\dgc_bilinear.v",
         "$PSScriptRoot\tb_cascade.v")
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_cascade -Name s4_cascade -Sources $src -IncDirs @("$root\sim\common") -TimeoutSec 600
exit $LASTEXITCODE

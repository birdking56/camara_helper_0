# S1: map_pipeline vs the golden model.
#
# P1 identity sweep (42,625 records) then P2 static k1/k2 over a whole 1080p
# frame (2,073,600 records), both bit compared against model/gen_vectors.py.
$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

$src = @(
    "$root\source\geometry\dgc_mul_pipe.v",
    "$root\source\geometry\dgc_map_pipeline.v",
    "$PSScriptRoot\tb_map_pipeline.v"
)

# The testbench opens the vector files with a path relative to sim/build/<name>,
# which is where run_test.ps1 runs vsim from.
& (Join-Path $root "sim\tools\run_test.ps1") `
    -Top      tb_map_pipeline `
    -Name     s1_map_pipeline `
    -Sources  $src `
    -IncDirs  @("$root\sim\common") `
    -PlusArgs ("+VEC0=" + ($root -replace "\\","/") + "/sim/s1_map_pipeline/vectors/coords_mode0_sweep.vec +VEC1=" + ($root -replace "\\","/") + "/sim/s1_map_pipeline/vectors/coords_mode1_full.vec") `
    -TimeoutSec 3600
exit $LASTEXITCODE

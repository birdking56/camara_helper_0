# S3: bilinear interpolation against the direct four-term formula.
$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

$src = @(
    "$root\source\geometry\dgc_mul_pipe.v",
    "$root\source\process\dgc_bilinear.v",
    "$PSScriptRoot\tb_bilinear.v"
)

& (Join-Path $root "sim\tools\run_test.ps1") `
    -Top      tb_bilinear `
    -Name     s3_bilinear `
    -Sources  $src `
    -IncDirs  @("$root\sim\common") `
    -TimeoutSec 600
exit $LASTEXITCODE

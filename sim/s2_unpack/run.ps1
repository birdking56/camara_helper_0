# S2: unpack byte stream -> pixels.
$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

$src = @(
    "$root\source\fetch\dgc_unpack.v",
    "$PSScriptRoot\tb_unpack.v"
)

& (Join-Path $root "sim\tools\run_test.ps1") `
    -Top      tb_unpack `
    -Name     s2_unpack `
    -Sources  $src `
    -IncDirs  @("$root\sim\common") `
    -TimeoutSec 600
exit $LASTEXITCODE

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$src = @("$root\source\fetch\dgc_unpack.v", "$PSScriptRoot\tb_unpack_matrix.v")
& (Join-Path $root 'sim\tools\run_test.ps1') -Top tb_unpack_matrix -Name s2_unpack_matrix -Sources $src -VlogArgs @('+define+DGC_SIM') -TimeoutSec 600
exit $LASTEXITCODE

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$src = @(
    "$root\source\fetch\dgc_ddr_wr_adapter.v",
    "$PSScriptRoot\tb_ddr_wr_adapter.v"
)
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_ddr_wr_adapter -Name s2_ddr_wr_adapter -Sources $src -IncDirs @("$root\sim\common") -VlogArgs @("+define+DGC_SIM") -TimeoutSec 600
exit $LASTEXITCODE

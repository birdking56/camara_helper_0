# S2: coord FIFO wrapper on the real generated IP.
$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

$src = @(
    "$root\source\cache\dgc_coord_fifo.v",
    "$root\source\common\dgc_fifo_rd_port.v",
    "$root\ipcore\coord_fifo\rtl\ipm2l_fifo_ctrl_v1_1_coord_fifo.v",
    "$root\ipcore\coord_fifo\rtl\ipm2l_sdpram_v1_6a_coord_fifo.v",
    "$root\ipcore\coord_fifo\rtl\ipm2l_fifo_v1_7_coord_fifo.v",
    "$root\ipcore\coord_fifo\coord_fifo.v",
    "$PSScriptRoot\tb_coord_fifo.v"
)

& (Join-Path $root "sim\tools\run_test.ps1") `
    -Top      tb_coord_fifo `
    -Name     s2_coord_fifo `
    -Sources  $src `
    -IncDirs  @("$root\sim\common") `
    -VlogArgs @("+define+DGC_SIM") `
    -TimeoutSec 600
exit $LASTEXITCODE

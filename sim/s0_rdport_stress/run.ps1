# S0: randomised stress of the read-port wrappers (600 beats each, random fire/ready).
$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

$src = @(
    "$root\source\common\dgc_ram_rd_port.v",
    "$root\source\common\dgc_fifo_rd_port.v",
    "$root\ipcore\src_tile_bank_0\rtl\ipm2l_sdpram_v1_6a_src_tile_bank_0.v",
    "$root\ipcore\src_tile_bank_0\src_tile_bank_0.v",
    "$root\ipcore\coord_fifo\rtl\ipm2l_fifo_ctrl_v1_1_coord_fifo.v",
    "$root\ipcore\coord_fifo\rtl\ipm2l_sdpram_v1_6a_coord_fifo.v",
    "$root\ipcore\coord_fifo\rtl\ipm2l_fifo_v1_7_coord_fifo.v",
    "$root\ipcore\coord_fifo\coord_fifo.v",
    "$PSScriptRoot\tb_rdport_stress.v"
)

& (Join-Path $root "sim\tools\run_test.ps1") `
    -Top      tb_rdport_stress `
    -Name     s0_rdport_stress `
    -Sources  $src `
    -IncDirs  @("$root\sim\common") `
    -VlogArgs @("+define+DGC_SIM") `
    -TimeoutSec 900
exit $LASTEXITCODE

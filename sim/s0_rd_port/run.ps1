# S0: DRM / FIFO read-port wrapper acceptance (real Pango IP models).
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
    "$root\ipcore\ddr_read_fifo\rtl\ipm2l_fifo_ctrl_v1_1_ddr_read_fifo.v",
    "$root\ipcore\ddr_read_fifo\rtl\ipm2l_sdpram_v1_6a_ddr_read_fifo.v",
    "$root\ipcore\ddr_read_fifo\rtl\ipm2l_fifo_v1_7_ddr_read_fifo.v",
    "$root\ipcore\ddr_read_fifo\ddr_read_fifo.v",
    "$PSScriptRoot\tb_rd_port.v"
)

& (Join-Path $root "sim\tools\run_test.ps1") `
    -Top     tb_rd_port `
    -Name    s0_rd_port `
    -Sources $src `
    -IncDirs @("$root\sim\common") `
    -VlogArgs @("+define+DGC_SIM")
exit $LASTEXITCODE

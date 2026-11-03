# S0: read-timing probe for the four generated IPs (real Pango behavioural models).
$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

$src = @(
    "$root\ipcore\src_tile_bank_0\rtl\ipm2l_sdpram_v1_6a_src_tile_bank_0.v",
    "$root\ipcore\src_tile_bank_0\src_tile_bank_0.v",
    "$root\ipcore\out_stripe_ram\rtl\ipm2l_sdpram_v1_6a_out_stripe_ram.v",
    "$root\ipcore\out_stripe_ram\out_stripe_ram.v",
    "$root\ipcore\coord_fifo\rtl\ipm2l_fifo_ctrl_v1_1_coord_fifo.v",
    "$root\ipcore\coord_fifo\rtl\ipm2l_sdpram_v1_6a_coord_fifo.v",
    "$root\ipcore\coord_fifo\rtl\ipm2l_fifo_v1_7_coord_fifo.v",
    "$root\ipcore\coord_fifo\coord_fifo.v",
    "$root\ipcore\ddr_read_fifo\rtl\ipm2l_fifo_ctrl_v1_1_ddr_read_fifo.v",
    "$root\ipcore\ddr_read_fifo\rtl\ipm2l_sdpram_v1_6a_ddr_read_fifo.v",
    "$root\ipcore\ddr_read_fifo\rtl\ipm2l_fifo_v1_7_ddr_read_fifo.v",
    "$root\ipcore\ddr_read_fifo\ddr_read_fifo.v",
    "$PSScriptRoot\tb_ip_probe.v"
)

& (Join-Path $root "sim\tools\run_test.ps1") `
    -Top    tb_ip_probe `
    -Name   s0_ip_probe `
    -Sources $src `
    -IncDirs @("$root\sim\common")
exit $LASTEXITCODE

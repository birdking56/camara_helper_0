param([switch]$Tput, [switch]$Radial, [switch]$BoardProbe)
$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$bank = @()
foreach ($b in 0..3) {
    $bank += "$root\ipcore\src_tile_bank_$b\rtl\ipm2l_sdpram_v1_6a_src_tile_bank_$b.v"
    $bank += "$root\ipcore\src_tile_bank_$b\src_tile_bank_$b.v"
}
$src = @(
    "$root\source\common\dgc_fifo_rd_port.v",
    "$root\ipcore\ddr_read_fifo\rtl\ipm2l_fifo_ctrl_v1_1_ddr_read_fifo.v",
    "$root\ipcore\ddr_read_fifo\rtl\ipm2l_sdpram_v1_6a_ddr_read_fifo.v",
    "$root\ipcore\ddr_read_fifo\rtl\ipm2l_fifo_v1_7_ddr_read_fifo.v",
    "$root\ipcore\ddr_read_fifo\ddr_read_fifo.v",
    "$root\source\geometry\dgc_mul_pipe.v",
    "$root\source\geometry\dgc_map_pipeline.v",
    "$root\source\geometry\dgc_coord_stage.v",
    "$root\source\control\dgc_bbox_acc.v",
    "$root\source\control\dgc_tile_scheduler.v",
    "$root\source\control\dgc_block_split.v",
    "$root\source\cache\dgc_coord_fifo.v",

    "$root\source\cache\dgc_cache_owner.v",
    "$root\source\cache\dgc_cache_set4.v",
    "$root\source\cache\dgc_source_cache4.v",
    "$root\source\cache\dgc_src_addr.v",
    "$root\source\cache\dgc_neighbour_calc.v",
    "$root\source\cache\dgc_read_issue.v",
    "$root\source\cache\dgc_sample_dedup.v",
    "$root\source\cache\dgc_source_sampler.v",
    "$root\source\cache\dgc_fill_ctrl.v",
    "$root\source\fetch\dgc_fetch_walk.v",
    "$root\source\fetch\dgc_fetch_row_plan.v",
    "$root\source\fetch\dgc_fetch_planner.v",
    "$root\source\fetch\dgc_unpack.v",
    "$root\source\process\dgc_gamma_stage.v",
    "$root\source\process\dgc_bilinear.v",
    "$root\source\display\dgc_stripe_writer.v",
    "$root\source\top\dgc_core.v",
    "$root\ipcore\coord_fifo\rtl\ipm2l_fifo_ctrl_v1_1_coord_fifo.v",
    "$root\ipcore\coord_fifo\rtl\ipm2l_sdpram_v1_6a_coord_fifo.v",
    "$root\ipcore\coord_fifo\rtl\ipm2l_fifo_v1_7_coord_fifo.v",
    "$root\ipcore\coord_fifo\coord_fifo.v",
    "$root\ipcore\out_stripe_ram\rtl\ipm2l_sdpram_v1_6a_out_stripe_ram.v",
    "$root\ipcore\out_stripe_ram\out_stripe_ram.v",
    "$root\ipcore\out_stripe_ram_1\rtl\ipm2l_sdpram_v1_6a_out_stripe_ram_1.v",
    "$root\ipcore\out_stripe_ram_1\out_stripe_ram_1.v"
) + $bank + @("$PSScriptRoot\tb_dgc_core.v")
if ($Radial -or $BoardProbe) {
    $expected = Join-Path $PSScriptRoot 'vectors\radial_expected.hex'
    if (-not (Test-Path -LiteralPath $expected)) {
        throw 'Generate the reference first: python model/audit_radial.py'
    }
    $testName = 's4_core_radial'
    $defines = @('+define+DGC_RADIAL_TEST')
    $plus = '+EXPECT=' + $expected.Replace('\','/')
    if ($BoardProbe) {
        $testName = 's4_core_radial_board_probe'
        $defines += '+define+DGC_BOARD_RATE_TEST'
        $plus += ' +TPUT'
    }
    elseif ($Tput) { $plus += ' +TPUT' }
    & (Join-Path $root "sim\tools\run_test.ps1") -Top tb_dgc_core -Name $testName `
        -Sources $src -IncDirs @("$root\sim\common") -VlogArgs $defines `
        -PlusArgs $plus -TimeoutSec 1800
}
elseif ($Tput) {
    & (Join-Path $root "sim\tools\run_test.ps1") -Top tb_dgc_core -Name s4_core_tput `
        -Sources $src -IncDirs @("$root\sim\common") -PlusArgs "+TPUT" -TimeoutSec 1800
}
else {
    & (Join-Path $root "sim\tools\run_test.ps1") -Top tb_dgc_core -Name s4_core `
        -Sources $src -IncDirs @("$root\sim\common") -TimeoutSec 1800
}
exit $LASTEXITCODE



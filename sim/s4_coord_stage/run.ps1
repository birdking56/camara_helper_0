$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$src = @(
    "$root\source\geometry\dgc_mul_pipe.v",
    "$root\source\geometry\dgc_map_pipeline.v",
    "$root\source\control\dgc_bbox_acc.v",
    "$root\source\geometry\dgc_coord_stage.v",
    "$root\source\cache\dgc_coord_fifo.v",
    "$root\source\common\dgc_fifo_rd_port.v",
    "$root\ipcore\coord_fifo\rtl\ipm2l_fifo_ctrl_v1_1_coord_fifo.v",
    "$root\ipcore\coord_fifo\rtl\ipm2l_sdpram_v1_6a_coord_fifo.v",
    "$root\ipcore\coord_fifo\rtl\ipm2l_fifo_v1_7_coord_fifo.v",
    "$root\ipcore\coord_fifo\coord_fifo.v",
    "$PSScriptRoot\tb_coord_stage.v"
)
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_coord_stage -Name s4_coord_stage -Sources $src -IncDirs @("$root\sim\common") -VlogArgs @("+define+DGC_SIM") -TimeoutSec 900
exit $LASTEXITCODE

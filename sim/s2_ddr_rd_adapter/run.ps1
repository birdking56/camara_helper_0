$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$src = @(
    "$root\source\fetch\dgc_native_split.v",
    "$root\source\fetch\dgc_rlast_check.v",
    "$root\source\fetch\dgc_ddr_credit.v",
    "$root\source\fetch\dgc_ddr_fetch.v",
    "$root\source\fetch\dgc_ddr_rd_adapter.v",
    "$root\source\common\dgc_fifo_rd_port.v",
    "$root\ipcore\ddr_read_fifo\rtl\ipm2l_fifo_ctrl_v1_1_ddr_read_fifo.v",
    "$root\ipcore\ddr_read_fifo\rtl\ipm2l_sdpram_v1_6a_ddr_read_fifo.v",
    "$root\ipcore\ddr_read_fifo\rtl\ipm2l_fifo_v1_7_ddr_read_fifo.v",
    "$root\ipcore\ddr_read_fifo\ddr_read_fifo.v",
    "$PSScriptRoot\tb_ddr_rd_adapter.v"
)
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_ddr_rd_adapter -Name s2_ddr_rd_adapter -Sources $src -IncDirs @("$root\sim\common") -VlogArgs @("+define+DGC_SIM") -TimeoutSec 900
exit $LASTEXITCODE

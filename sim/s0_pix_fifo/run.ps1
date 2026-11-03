$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$src = @(
    "$root\ipcore\pix_beat_fifo\rtl\ipm2l_fifo_ctrl_v1_1_pix_beat_fifo.v",
    "$root\ipcore\pix_beat_fifo\rtl\ipm2l_sdpram_v1_6a_pix_beat_fifo.v",
    "$root\ipcore\pix_beat_fifo\rtl\ipm2l_fifo_v1_7_pix_beat_fifo.v",
    "$root\ipcore\pix_beat_fifo\pix_beat_fifo.v",
    "$PSScriptRoot\tb_pix_fifo.v"
)
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_pix_fifo -Name s0_pix_fifo -Sources $src -IncDirs @("$root\sim\common") -TimeoutSec 600
exit $LASTEXITCODE

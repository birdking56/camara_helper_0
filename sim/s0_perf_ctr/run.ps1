$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$src = @(
    "$root\source\debug\dgc_debug_uart.v",
    "$root\source\rtl\uart_tx_simple.v",
    "$PSScriptRoot\tb_perf_ctr.v"
)
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_perf_ctr -Name s0_perf_ctr `
    -Sources $src -IncDirs @("$root\sim\common") -TimeoutSec 600
exit $LASTEXITCODE

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_debug_uart -Name s0_debug_uart `
    -Sources @("$root\source\debug\dgc_debug_uart.v", "$root\source\rtl\uart_tx_simple.v", "$PSScriptRoot\tb_debug_uart.v") `
    -IncDirs @("$root\sim\common") -TimeoutSec 600
exit $LASTEXITCODE

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$src = @(
    "$root\source\rtl\uart_tx_simple.v",
    "$root\source\debug\dgc_debug_uart.v",
    "$PSScriptRoot\tb_debug_uart.v"
)
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_debug_uart -Name _uart_probe `
    -Sources $src -IncDirs @("$root\sim\common") -TimeoutSec 300
exit $LASTEXITCODE

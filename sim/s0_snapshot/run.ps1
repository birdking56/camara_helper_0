$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_snapshot -Name s0_snapshot `
    -Sources @("$root\source\debug\dgc_snapshot_src.v", "$root\source\debug\dgc_snapshot_hub.v", "$root\source\debug\dgc_debug_uart.v", "$root\source\rtl\uart_tx_simple.v", "$PSScriptRoot\tb_snapshot.v") `
    -IncDirs @("$root\sim\common") -TimeoutSec 300
exit $LASTEXITCODE

# S0: reset synchroniser + cross-domain mailbox acceptance.
$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

$src = @(
    "$root\source\common\dgc_rst_sync.v",
    "$root\source\common\dgc_mailbox.v",
    "$PSScriptRoot\tb_rst_mailbox.v"
)

& (Join-Path $root "sim\tools\run_test.ps1") `
    -Top     tb_rst_mailbox `
    -Name    s0_rst_mbox `
    -Sources $src `
    -IncDirs @("$root\sim\common") `
    -VlogArgs @("+define+DGC_SIM")
exit $LASTEXITCODE

# S0: mailbox CDC robustness under jittered, unrelated clocks.
$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

$src = @(
    "$root\source\common\dgc_rst_sync.v",
    "$root\source\common\dgc_mailbox.v",
    "$PSScriptRoot\tb_mbox_cdc_stress.v"
)

& (Join-Path $root "sim\tools\run_test.ps1") `
    -Top      tb_mbox_cdc_stress `
    -Name     s0_cdc_stress `
    -Sources  $src `
    -IncDirs  @("$root\sim\common") `
    -VlogArgs @("+define+DGC_SIM") `
    -TimeoutSec 900
exit $LASTEXITCODE

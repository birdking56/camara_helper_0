$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$src = @(
    "$root\source\display\dgc_stripe_writer.v",
    "$root\sim\common\dgc_stripe_ram_sim.v",
    "$PSScriptRoot\tb_stripe_owner.v"
)
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_stripe_owner -Name s4_stripe_owner `
    -Sources $src -IncDirs @("$root\sim\common") -TimeoutSec 300
exit $LASTEXITCODE

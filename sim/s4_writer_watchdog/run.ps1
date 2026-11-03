$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$src = @(
    "$root\source\display\dgc_stripe_writer.v",
    "$root\sim\common\dgc_stripe_ram_sim.v",
    "$PSScriptRoot\tb_writer_watchdog.v"
)
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_writer_watchdog -Name s4_writer_watchdog `
    -Sources $src -IncDirs @("$root\sim\common") -TimeoutSec 300
exit $LASTEXITCODE

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
# Behavioural stripe RAM (the generated IP is covered separately by s4_stripe_ram).
$src = @(
  "$root\source\display\dgc_stripe_writer.v",
  "$root\sim\common\dgc_stripe_ram_sim.v",
  "$PSScriptRoot\tb_stripe_writer.v")
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_stripe_writer -Name s4_stripe_writer `
    -Sources $src -IncDirs @("$root\sim\common") -TimeoutSec 300
exit $LASTEXITCODE

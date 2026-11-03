$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$src = @(
    "$root\ipcore\out_stripe_ram\rtl\ipm2l_sdpram_v1_6a_out_stripe_ram.v",
    "$root\ipcore\out_stripe_ram\out_stripe_ram.v",
    "$PSScriptRoot\tb_stripe_ram.v"
)
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_stripe_ram -Name s4_stripe_ram -Sources $src -IncDirs @("$root\sim\common") -TimeoutSec 600
exit $LASTEXITCODE

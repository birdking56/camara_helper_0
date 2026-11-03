$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$src = @(
    "$root\source\display\dgc_video_reader.v",
    "$root\ipcore\out_stripe_ram\rtl\ipm2l_sdpram_v1_6a_out_stripe_ram.v",
    "$root\ipcore\out_stripe_ram\out_stripe_ram.v",
    "$root\ipcore\out_stripe_ram_1\rtl\ipm2l_sdpram_v1_6a_out_stripe_ram_1.v",
    "$root\ipcore\out_stripe_ram_1\out_stripe_ram_1.v",
    "$PSScriptRoot\tb_video_reader.v"
)
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_video_reader -Name s4_video_reader -Sources $src -IncDirs @("$root\sim\common") -TimeoutSec 900
exit $LASTEXITCODE

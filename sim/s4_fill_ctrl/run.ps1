$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$bank = @()
foreach ($b in 0..3) {
    $bank += "$root\ipcore\src_tile_bank_$b\rtl\ipm2l_sdpram_v1_6a_src_tile_bank_$b.v"
    $bank += "$root\ipcore\src_tile_bank_$b\src_tile_bank_$b.v"
}
$src = @(
    "$root\source\fetch\dgc_fetch_walk.v",
    "$root\source\fetch\dgc_fetch_row_plan.v",
    "$root\source\fetch\dgc_fetch_planner.v",
    "$root\source\fetch\dgc_unpack.v",
    "$root\source\cache\dgc_cache_owner.v",
    "$root\source\cache\dgc_cache_set4.v",
    "$root\source\cache\dgc_source_cache4.v",
    "$root\source\cache\dgc_fill_ctrl.v"
) + $bank + @("$PSScriptRoot\tb_fill_ctrl.v")
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_fill_ctrl -Name s4_fill_ctrl -Sources $src -IncDirs @("$root\sim\common") -TimeoutSec 900
exit $LASTEXITCODE

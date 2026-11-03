$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$bank = @()
foreach ($b in 0..3) {
    $bank += "$root\ipcore\src_tile_bank_$b\rtl\ipm2l_sdpram_v1_6a_src_tile_bank_$b.v"
    $bank += "$root\ipcore\src_tile_bank_$b\src_tile_bank_$b.v"
}
$src = @(
    "$root\source\cache\dgc_neighbour_calc.v",
    "$root\source\cache\dgc_read_issue.v",
    "$root\source\cache\dgc_sample_dedup.v",
    "$root\source\cache\dgc_src_addr.v",
    "$root\source\cache\dgc_cache_set4.v",
    "$root\source\cache\dgc_source_cache4.v",
    "$root\source\cache\dgc_source_sampler.v"
) + $bank + @("$PSScriptRoot\tb_source_sampler.v")
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_source_sampler -Name s4_source_sampler -Sources $src -IncDirs @("$root\sim\common") -TimeoutSec 600
exit $LASTEXITCODE

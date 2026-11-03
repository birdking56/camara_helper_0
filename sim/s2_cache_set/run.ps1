$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$src = @("$root\source\cache\dgc_cache_set.v",
         "$root\ipcore\src_tile_bank_0\rtl\ipm2l_sdpram_v1_6a_src_tile_bank_0.v",
         "$root\ipcore\src_tile_bank_0\src_tile_bank_0.v",
         "$root\ipcore\src_tile_bank_1\rtl\ipm2l_sdpram_v1_6a_src_tile_bank_1.v",
         "$root\ipcore\src_tile_bank_1\src_tile_bank_1.v",
         "$root\ipcore\src_tile_bank_2\rtl\ipm2l_sdpram_v1_6a_src_tile_bank_2.v",
         "$root\ipcore\src_tile_bank_2\src_tile_bank_2.v",
         "$root\ipcore\src_tile_bank_3\rtl\ipm2l_sdpram_v1_6a_src_tile_bank_3.v",
         "$root\ipcore\src_tile_bank_3\src_tile_bank_3.v",
         "$PSScriptRoot\tb_cache_set.v")
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_cache_set -Name s2_cache_set -Sources $src -IncDirs @("$root\sim\common") -TimeoutSec 600
exit $LASTEXITCODE

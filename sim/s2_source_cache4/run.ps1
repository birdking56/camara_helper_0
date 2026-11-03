$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$src = @("$root\source\cache\dgc_source_cache4.v","$root\source\cache\dgc_cache_set4.v"
         ,"$root\ipcore\src_tile_bank_0\rtl\ipm2l_sdpram_v1_6a_src_tile_bank_0.v"
         ,"$root\ipcore\src_tile_bank_0\src_tile_bank_0.v"
         ,"$root\ipcore\src_tile_bank_1\rtl\ipm2l_sdpram_v1_6a_src_tile_bank_1.v"
         ,"$root\ipcore\src_tile_bank_1\src_tile_bank_1.v"
         ,"$root\ipcore\src_tile_bank_2\rtl\ipm2l_sdpram_v1_6a_src_tile_bank_2.v"
         ,"$root\ipcore\src_tile_bank_2\src_tile_bank_2.v"
         ,"$root\ipcore\src_tile_bank_3\rtl\ipm2l_sdpram_v1_6a_src_tile_bank_3.v"
         ,"$root\ipcore\src_tile_bank_3\src_tile_bank_3.v"
         ,"$root\ipcore\src_tile_bank_4\rtl\ipm2l_sdpram_v1_6a_src_tile_bank_4.v"
         ,"$root\ipcore\src_tile_bank_4\src_tile_bank_4.v"
         ,"$root\ipcore\src_tile_bank_5\rtl\ipm2l_sdpram_v1_6a_src_tile_bank_5.v"
         ,"$root\ipcore\src_tile_bank_5\src_tile_bank_5.v"
         ,"$root\ipcore\src_tile_bank_6\rtl\ipm2l_sdpram_v1_6a_src_tile_bank_6.v"
         ,"$root\ipcore\src_tile_bank_6\src_tile_bank_6.v"
         ,"$root\ipcore\src_tile_bank_7\rtl\ipm2l_sdpram_v1_6a_src_tile_bank_7.v"
         ,"$root\ipcore\src_tile_bank_7\src_tile_bank_7.v"
         ,"$PSScriptRoot\tb_source_cache4.v")
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_source_cache4 -Name s2_source_cache4 -Sources $src -IncDirs @("$root\sim\common") -TimeoutSec 1200
exit $LASTEXITCODE


$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$bank = @()
foreach ($b in 0..3) {
    $bank += "$root\ipcore\src_tile_bank_$b\rtl\ipm2l_sdpram_v1_6a_src_tile_bank_$b.v"
    $bank += "$root\ipcore\src_tile_bank_$b\src_tile_bank_$b.v"
}
$src = @(& (Join-Path $root "sim\_s5_sys_compile\sources.ps1")) + @("$PSScriptRoot\tb_sys_compile.v")
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_sys_compile -Name s5_sys_compile -Sources $src -IncDirs @("$root\sim\common") -TimeoutSec 1200
exit $LASTEXITCODE

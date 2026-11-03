# S2 prerequisite: real DDR3 IP + real Micron memory model, native port read/write.
#
# Compiles the vendor PHY from its simulation set (rtl/*.v + sim_lib encrypted
# sim models) against the Pango primitive library, plus the staged memory model
# from sim/ddr3_sim/mem (see prepare_mem_model.ps1).
$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$ip   = Join-Path $root "ipcore\ddr3_test"
$mem  = Join-Path $PSScriptRoot "mem"

if (-not (Test-Path (Join-Path $mem "ddr3.v"))) {
    throw "run sim\ddr3_sim\prepare_mem_model.ps1 first"
}

$src = @()
$src += "$ip\ddr3_test.v"
$src += "$ip\ddr3_test_ddrphy_top.v"
$src += (Get-ChildItem "$ip\rtl" -Recurse -File -Filter "*.v" | ForEach-Object { $_.FullName })
$src += (Get-ChildItem "$ip\sim_lib" -Recurse -File | Where-Object { $_.Extension -in @(".vp",".v") } | ForEach-Object { $_.FullName })
$src += "$mem\ddr3.v"
$src += "$PSScriptRoot\tb_ddr3_native.v"

& (Join-Path $root "sim\tools\run_test.ps1") `
    -Top       tb_ddr3_native `
    -Name      s2_ddr3_native `
    -Sources   $src `
    -IncDirs   @("$root\sim\common", $mem) `
    -VlogArgs  @("-sv", "+define+x8", "+define+den4096Mb") `
    -TimeoutSec 3600
exit $LASTEXITCODE

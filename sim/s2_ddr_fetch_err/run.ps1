$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$src = @("$root\source\fetch\dgc_ddr_fetch.v","$root\source\fetch\dgc_ddr_credit.v",
         "$root\source\fetch\dgc_native_split.v","$root\source\fetch\dgc_rlast_check.v",
         "$PSScriptRoot\tb_ddr_fetch_err.v")
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_ddr_fetch_err -Name s2_ddr_fetch_err -Sources $src -IncDirs @("$root\sim\common") -TimeoutSec 200
exit $LASTEXITCODE

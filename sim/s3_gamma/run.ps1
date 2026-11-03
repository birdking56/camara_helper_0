$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$src = @("$root\source\process\dgc_gamma_stage.v", "$PSScriptRoot\tb_gamma_stage.v")
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_gamma_stage -Name s3_gamma -Sources $src -IncDirs @("$root\sim\common") -VlogArgs @("+define+DGC_SIM") -TimeoutSec 600
exit $LASTEXITCODE

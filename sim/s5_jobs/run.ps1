$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$src = @(& (Join-Path $root "sim\_s5_sys_compile\sources.ps1")) | Where-Object { $_ -notmatch "out_stripe_ram" }
$src += @("$root\sim\common\dgc_stripe_ram_sim.v", "$PSScriptRoot\tb_jobs.v")
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_jobs -Name s5_jobs -Sources $src -IncDirs @("$root\sim\common") -TimeoutSec 2400
exit $LASTEXITCODE

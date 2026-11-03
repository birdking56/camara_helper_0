$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$src = @(& (Join-Path $root "sim\_s5_sys_compile\sources.ps1")) | Where-Object { $_ -notmatch "out_stripe_ram" }
$src += @("$root\sim\common\dgc_stripe_ram_sim.v", "$PSScriptRoot\tb_jobs.v")
# ALIGN_TO_FRAME=1: the acquire is early, the job start must land on a frame_tick.
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_jobs -Name s5_jobs_align -Sources $src -IncDirs @("$root\sim\common") -VlogArgs @("+define+DGC_ALIGN_TEST") -TimeoutSec 2400
exit $LASTEXITCODE

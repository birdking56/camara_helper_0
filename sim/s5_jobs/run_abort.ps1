$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$src = @(& (Join-Path $root "sim\_s5_sys_compile\sources.ps1")) | Where-Object { $_ -notmatch "out_stripe_ram" }
$src += @("$root\sim\common\dgc_stripe_ram_sim.v", "$PSScriptRoot\tb_jobs.v")
# DGC_ABORT_TEST: the job watchdog is shortened to 60k cycles, the test parks bank3
# in READING so the watchdog fires, and it requires the next job to run all 4080
# blocks. This is the end-to-end regression for the 2026-11-02 abort contract.
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_jobs -Name s5_jobs_abort -Sources $src -IncDirs @("$root\sim\common") -VlogArgs @("+define+DGC_ABORT_TEST") -TimeoutSec 2400
exit $LASTEXITCODE

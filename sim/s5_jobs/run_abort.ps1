param([switch]$FillActive)
$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$src = @(& (Join-Path $root "sim\_s5_sys_compile\sources.ps1")) | Where-Object { $_ -notmatch "out_stripe_ram" }
$src += @("$root\sim\common\dgc_stripe_ram_sim.v", "$PSScriptRoot\tb_jobs.v")
# MODE=1 recovery: either strand bank3 until the watchdog fires, or expire the
# watchdog during an active DDR fill. The next job must emit all 2,073,600 pixels
# exactly, starting with a fresh descriptor, after the old read stream drains.
$expected = "$root\sim\s4_core\vectors\radial_expected.hex".Replace('\', '/')
$name = 's5_jobs_abort'
$plus = "+EXPECT=$expected"
if ($FillActive) { $name = 's5_jobs_abort_fill'; $plus += ' +FILL_ABORT' }
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_jobs -Name $name -Sources $src -IncDirs @("$root\sim\common") -VlogArgs @("+define+DGC_ABORT_TEST") -PlusArgs $plus -TimeoutSec 2400
exit $LASTEXITCODE

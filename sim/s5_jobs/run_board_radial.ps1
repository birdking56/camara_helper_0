param([switch]$FailFast, [int]$ReadDelay=4, [switch]$ExpectUnderflow)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$src = @(& (Join-Path $root 'sim\_s5_sys_compile\sources.ps1')) | Where-Object { $_ -notmatch 'out_stripe_ram' }
$src += @("$root\sim\common\dgc_stripe_ram_sim.v", "$PSScriptRoot\tb_jobs.v")
$expected = "$root\sim\s4_core\vectors\radial_expected.hex".Replace('\', '/')
$plus = "+EXPECT=$expected"
$plus += " +RD_DELAY=$ReadDelay"
if ($FailFast) { $plus += ' +FAIL_FAST' }
if ($ExpectUnderflow) { $plus += ' +EXPECT_UF' }
$name = 's5_jobs_board_radial'
if ($ReadDelay -ne 4) { $name += "_d$ReadDelay" }
if ($ExpectUnderflow) { $name += '_uf' }
& (Join-Path $root 'sim\tools\run_test.ps1') -Top tb_jobs -Name $name -Sources $src -IncDirs @("$root\sim\common") -VlogArgs @('+define+DGC_ALIGN_TEST', '+define+DGC_BOARD_RADIAL_TEST') -PlusArgs $plus -TimeoutSec 2400
exit $LASTEXITCODE

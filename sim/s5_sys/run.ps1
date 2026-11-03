$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$src = @(& (Join-Path $root "sim\_s5_sys_compile\sources.ps1")) | Where-Object { $_ -notmatch "out_stripe_ram" }
$src += @("$root\sim\common\dgc_stripe_ram_sim.v", "$PSScriptRoot\tb_sys.v")
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_sys -Name s5_sys -Sources $src -IncDirs @("$root\sim\common") -TimeoutSec 2400
exit $LASTEXITCODE

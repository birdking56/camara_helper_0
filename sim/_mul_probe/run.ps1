$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$src = @("$root\source\geometry\dgc_mul_pipe.v", "$PSScriptRoot\tb_mul.v")
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_mul -Name _mul_probe -Sources $src `
    -IncDirs @("$root\sim\common") -TimeoutSec 300
exit $LASTEXITCODE

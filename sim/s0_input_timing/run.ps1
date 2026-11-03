$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_input_timing -Name s0_input_timing `
    -Sources @("$root\source\debug\dgc_input_timing.v", "$PSScriptRoot\tb_input_timing.v") `
    -IncDirs @("$root\sim\common") -TimeoutSec 300
exit $LASTEXITCODE

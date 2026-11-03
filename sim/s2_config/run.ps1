# S2: configuration manager against the frozen register map.
$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

$src = @(
    "$root\source\control\dgc_config_manager.v",
    "$PSScriptRoot\tb_config_manager.v"
)

& (Join-Path $root "sim\tools\run_test.ps1") `
    -Top      tb_config_manager `
    -Name     s2_config `
    -Sources  $src `
    -IncDirs  @("$root\sim\common") `
    -TimeoutSec 600
exit $LASTEXITCODE

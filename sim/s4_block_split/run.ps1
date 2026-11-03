$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$src = @("$root\source\control\dgc_block_split.v", "$PSScriptRoot\tb_block_split.v")
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_block_split -Name s4_block_split -Sources $src -IncDirs @("$root\sim\common") -TimeoutSec 300
exit $LASTEXITCODE

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$src = @(
    "$root\source\display\dgc_video_reader.v",
    "$PSScriptRoot\tb_reader_last.v"
)
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_reader_last -Name s4_reader_last `
    -Sources $src -IncDirs @("$root\sim\common") -TimeoutSec 300
exit $LASTEXITCODE

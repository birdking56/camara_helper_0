$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_reader_boundary -Name s4_reader_boundary `
    -Sources @("$root\source\display\dgc_video_reader.v", "$PSScriptRoot\tb_reader_boundary.v") `
    -IncDirs @("$root\sim\common") -TimeoutSec 300
exit $LASTEXITCODE

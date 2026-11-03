$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
& (Join-Path $root "sim\tools\run_test.ps1") -Top tb_frame_manager_liveness -Name s2_frame_mgr_liveness -Sources @("$root\source\frame\dgc_frame_manager.v","$PSScriptRoot\tb_frame_manager_liveness.v") -IncDirs @("$root\sim\common") -TimeoutSec 300
exit $LASTEXITCODE

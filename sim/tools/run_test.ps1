<#
    dgc unified Questa test runner.

    Usage (from any directory):
        powershell -File sim\tools\run_test.ps1 -Top tb_xxx -Name ip_rd `
                 -Sources @("path\to\a.v","path\to\tb.v")

    Behaviour:
      1. Builds sim\lib\pango_sim once (all Pango primitive behavioural models).
      2. Creates a clean work library under sim\build\<Name>.
      3. Compiles Sources against pango_sim.
      4. Runs vsim in batch mode with a generated do-file (no quoting issues).
      5. Parses the transcript and writes sim\build\<Name>\result.txt.
      6. Exits 0 only when the testbench printed TEST_PASS and Questa saw 0 errors.

    Every testbench must:
      * declare  integer dgc_errors = 0;
      * include sim\common\dgc_tb.vh
      * instantiate  DGC_GRS_INST  when Pango DRAM/FIFO models are used
      * end with  `DGC_FINISH
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]   $Top,
    [Parameter(Mandatory = $true)][string[]] $Sources,
    [Parameter(Mandatory = $true)][string]   $Name,
    [string[]] $IncDirs = @(),
    [string]   $PlusArgs = "",
    [int]      $TimeoutSec = 1200,
    [string[]] $VlogArgs = @(),
    [string[]] $VsimArgs = @()
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------- environment
$root      = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$simDir    = Join-Path $root "sim"
$libDir    = Join-Path $simDir "lib"
$pangoLib  = Join-Path $libDir "pango_sim"
$buildRoot = Join-Path $simDir "build"
$work      = Join-Path $buildRoot $Name
if ($Name -notmatch '^[A-Za-z0-9_-]+$') { throw "Invalid simulation name: $Name" }
$buildPrefix = [IO.Path]::GetFullPath($buildRoot).TrimEnd('\') + '\'
$work = [IO.Path]::GetFullPath($work)
if (-not $work.StartsWith($buildPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Simulation work directory escapes build root: $work"
}
$libPrefix = [IO.Path]::GetFullPath($libDir).TrimEnd('\') + '\'
if (-not ([IO.Path]::GetFullPath($pangoLib)).StartsWith($libPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Pango library directory escapes library root: $pangoLib"
}
$pangoSim  = "C:\pango\PDS_2022.2-SP3\arch\vendor\pango\verilog\simulation"

function Write-Step($msg) { Write-Host "[run_test] $msg" -ForegroundColor Cyan }
function Write-Bad ($msg) { Write-Host "[run_test] $msg" -ForegroundColor Red }

# ---------------------------------------------------------------- pango library
if (-not (Test-Path (Join-Path $pangoLib "_lib.qdb"))) {
    Write-Step "Building Pango primitive simulation library (one time, ~11 s)"
    New-Item -ItemType Directory -Force -Path $libDir | Out-Null
    Push-Location $libDir
    try {
        Remove-Item -LiteralPath $pangoLib -Recurse -Force -ErrorAction SilentlyContinue
        & vlib pango_sim | Out-Null
        $files = Get-ChildItem $pangoSim -File -Filter "*.v" | ForEach-Object { $_.FullName }
        $out   = & vlog -work pango_sim @files 2>&1
        $out | Select-String -Pattern "^Errors:" | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) { throw "Pango library compile failed" }
    }
    finally { Pop-Location }
}

# ---------------------------------------------------------------- work library
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Force -Path $work | Out-Null
New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null

Push-Location $work
try {
    & vlib work | Out-Null

    $log = Join-Path $work "compile.log"
    $compileArgs = @("-work", "work", "-L", $pangoLib)
    foreach ($d in $IncDirs) { $compileArgs += @("+incdir+$d") }
    $compileArgs += $VlogArgs
    $compileArgs += $Sources
    $cout = & vlog @compileArgs 2>&1
    $cout | Set-Content -Encoding utf8 -Path $log
    $compileErrs = ($cout | Select-String -Pattern "^Errors:" | Select-Object -Last 1)
    if ($compileErrs -and $compileErrs.Line -notmatch "^Errors: 0,") {
        $cout | Select-Object -Last 40 | ForEach-Object { Write-Host $_ }
        throw "Compilation failed (see $log)"
    }

    # ------------------------------------------------------------ do file
    $do = Join-Path $work "run.do"
    @(
        "onerror {resume}",
        "run -all",
        "quit -f"
    ) | Set-Content -Encoding ascii -Path $do

    # ------------------------------------------------------------ simulate
    $vsimArgs = @("-batch")
    $vsimArgs += @("-L", $pangoLib)
    $vsimArgs += $VsimArgs
    if ($PlusArgs -ne "") { $vsimArgs += $PlusArgs.Split(" ") }
    $vsimArgs += @("-l", (Join-Path $work "vsim_stream.log"))
    $vsimArgs += @("-do", "do run.do")
    $vsimArgs += "work.$Top"

    $transcript = Join-Path $work "vsim.log"
    # vsim must not be started via Start-Process+-RedirectStandardOutput here:
    # this shell pipes program output for us, so use a background-free direct call
    # with a wall-clock guard implemented through a job.
    $job = Start-Job -ScriptBlock {
        param($exe, $args_, $wd)
        Set-Location $wd
        $o = & $exe @args_ 2>&1
        $o | Out-String
    } -ArgumentList "vsim.exe", $vsimArgs, $work

    if (-not (Wait-Job $job -Timeout $TimeoutSec)) {
        # The job's own output is only delivered when it finishes, so a timeout
        # used to throw away everything the simulation had printed - which made
        # every hang undebuggable. vsim now writes its own transcript with -l,
        # so salvage that file and show its tail before giving up.
        $partial = Join-Path $work "vsim_stream.log"
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        Write-Bad "TIMEOUT after ${TimeoutSec}s"
        if (Test-Path $partial) {
            Write-Bad "--- last 40 lines of the transcript ---"
            Get-Content $partial -Tail 40 | ForEach-Object { Write-Host $_ }
        }
        else {
            Write-Bad "no transcript was produced at all"
        }
        "TIMEOUT" | Set-Content -Path (Join-Path $work "result.txt")
        exit 2
    }
    $simout = Receive-Job $job
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    $simout | Set-Content -Encoding utf8 -Path $transcript

    # ------------------------------------------------------------ verdict
    $lines    = $simout -split "`r?`n"
    $hasPass  = ($lines | Where-Object { $_ -match "TEST_PASS" }).Count -gt 0
    $fails    = $lines | Where-Object { $_ -match "TEST_FAIL|TEST_TIMEOUT" }
    $elabErr  = ($lines | Where-Object { $_ -match "\*\* Error" -or $_ -match "Error loading design" }).Count -gt 0

    $vsimErrLine = $lines | Where-Object { $_ -match "^# Errors: (\d+)" } | Select-Object -Last 1
    $vsimErrCnt  = 0
    if ($vsimErrLine -and ($vsimErrLine -match "^# Errors: (\d+)")) { $vsimErrCnt = [int]$Matches[1] }

    $ok = $hasPass -and (-not $elabErr) -and ($fails.Count -eq 0) -and ($vsimErrCnt -eq 0)

    $result = @(
        "test   : $Name",
        "top    : $Top",
        "pass   : $ok",
        "vsim_err_count : $vsimErrCnt",
        "fail_lines : $($fails.Count)"
    ) -join "`n"
    $result | Set-Content -Path (Join-Path $work "result.txt")

    if (-not $ok) {
        Write-Bad "FAIL  ($Name)"
        if ($elabErr) { $lines | Where-Object { $_ -match "\*\* Error|Error loading" } | Select-Object -First 10 | ForEach-Object { Write-Host $_ } }
        # Print the TEST_INFO progress lines even on failure. Without them a
        # failing run only showed the assertion text, so it was impossible to
        # tell how far the testbench had got - which cost several debugging
        # rounds on the tile scheduler.
        $infos = $lines | Where-Object { $_ -match "TEST_INFO" }
        if ($infos.Count -gt 0) {
            Write-Bad "--- TEST_INFO progress before the failure ---"
            $infos | Select-Object -Last 15 | ForEach-Object { Write-Host $_ }
        }
        $fails | Select-Object -First 20 | ForEach-Object { Write-Host $_ }
        if (-not $hasPass -and $fails.Count -eq 0) {
            $lines | Select-Object -Last 25 | ForEach-Object { Write-Host $_ }
        }
        exit 1
    }

    Write-Host "[run_test] PASS  ($Name)" -ForegroundColor Green
    $lines | Where-Object { $_ -match "TEST_INFO" } | ForEach-Object { Write-Host $_ }
    exit 0
}
finally { Pop-Location }

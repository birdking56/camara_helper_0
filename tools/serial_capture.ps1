#-----------------------------------------------------------------------------
# serial_capture.ps1 - read the DGC3 report from the board, read-only.
#
#   pwsh -File tools\serial_capture.ps1                     # COM3, 12 s
#   pwsh -File tools\serial_capture.ps1 -Port COM3 -Seconds 30
#
# The port is opened 115200 8N1 with DTR/RTS deasserted (the CP2102 on this
# board resets the FPGA if they toggle), nothing is written to the board, and
# every line is copied verbatim to tools\uart_<timestamp>.log. Then the log is
# decoded with tools\dgc3_decode.py if a Python interpreter is available.
#
# This script only observes. It does not build, program, or reset anything.
#-----------------------------------------------------------------------------
param(
    [string] $Port    = "COM3",
    [int]    $Seconds = 12,
    [string] $OutFile = ""
)

$ErrorActionPreference = "Stop"

if ($OutFile -eq "") {
    $stamp   = Get-Date -Format "yyyyMMdd_HHmmss"
    $OutFile = Join-Path $PSScriptRoot "uart_$stamp.log"
}

$sp = [System.IO.Ports.SerialPort]::new(
    $Port,
    115200,
    [System.IO.Ports.Parity]::None,
    8,
    [System.IO.Ports.StopBits]::One)
$sp.DtrEnable   = $false
$sp.RtsEnable   = $false
$sp.ReadTimeout = 500
$sp.NewLine     = "`n"

Write-Host "[capture] $Port 115200 8N1, ${Seconds}s -> $OutFile" -ForegroundColor Cyan

$lines = New-Object System.Collections.Generic.List[string]
$sp.Open()
try {
    $deadline = (Get-Date).AddSeconds($Seconds)
    $pending  = ""
    while ((Get-Date) -lt $deadline) {
        try {
            $chunk = $sp.ReadExisting()
        }
        catch {
            $chunk = ""
        }
        if ($chunk -ne "") {
            $pending += $chunk
            while ($pending.Contains("`n")) {
                $i = $pending.IndexOf("`n")
                $line = $pending.Substring(0, $i).TrimEnd("`r")
                $pending = $pending.Substring($i + 1)
                if ($line -ne "") {
                    $lines.Add($line)
                    Write-Host $line
                }
            }
        }
        else {
            Start-Sleep -Milliseconds 50
        }
    }
}
finally {
    $sp.Close()
    $sp.Dispose()
}

$lines | Set-Content -Encoding ascii -Path $OutFile
Write-Host "[capture] $($lines.Count) lines saved" -ForegroundColor Green

$py = $null
foreach ($cand in @("python", "py")) {
    $cmd = Get-Command $cand -ErrorAction SilentlyContinue
    if ($cmd) { $py = $cmd.Source; break }
}
if ($py) {
    & $py (Join-Path $PSScriptRoot "dgc3_decode.py") $OutFile
}
else {
    Write-Host "[capture] python not found; decode later with tools\dgc3_decode.py" -ForegroundColor Yellow
}

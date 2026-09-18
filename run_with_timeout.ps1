param(
    [Parameter(Mandatory=$true)][string]$ExePath,
    [Parameter(Mandatory=$true)][string]$ExeArgs,
    [Parameter(Mandatory=$true)][string]$LogFile,
    [int]$TimeoutMs = 8000
)

# File-based redirection (via Start-Process), not pipe/event-based capture -
# this mirrors cmd.exe's own `> file 2>&1` behavior, which is proven to
# capture esptool's full output reliably. An earlier version of this script
# used ProcessStartInfo + Register-ObjectEvent (pipe-based async capture),
# but that lost most of esptool's output: events queued while WaitForExit()
# blocks aren't dispatched until the pipeline yields, so by the time the
# builder was read, only the first couple of lines had been delivered -
# confirmed directly (exit code 0 / success, but log showed only the
# banner). Redirecting straight to files, like cmd's `>`, sidesteps that
# race entirely.
$stdoutFile = "$LogFile.stdout.tmp"
$stderrFile = "$LogFile.stderr.tmp"

Remove-Item -Path $stdoutFile -ErrorAction SilentlyContinue
Remove-Item -Path $stderrFile -ErrorAction SilentlyContinue

$proc = Start-Process -FilePath $ExePath -ArgumentList $ExeArgs `
    -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile `
    -PassThru -NoNewWindow

$finished = $proc.WaitForExit($TimeoutMs)

if (-not $finished) {
    try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
    # Give the OS a moment to flush whatever the killed process had already
    # written to its redirected output files before we read them.
    Start-Sleep -Milliseconds 300
}

$stdoutText = ""
$stderrText = ""
if (Test-Path $stdoutFile) { $stdoutText = Get-Content -Path $stdoutFile -Raw -ErrorAction SilentlyContinue }
if (Test-Path $stderrFile) { $stderrText = Get-Content -Path $stderrFile -Raw -ErrorAction SilentlyContinue }

Set-Content -Path $LogFile -Value ($stdoutText + $stderrText) -Encoding UTF8

Remove-Item -Path $stdoutFile -ErrorAction SilentlyContinue
Remove-Item -Path $stderrFile -ErrorAction SilentlyContinue

if (-not $finished) {
    Add-Content -Path $LogFile -Value "`n[WATCHDOG] Process did not respond within $TimeoutMs ms and was forcibly terminated."
    exit 2
} else {
    exit $proc.ExitCode
}

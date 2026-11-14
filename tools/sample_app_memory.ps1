<#
.SYNOPSIS
Samples MailBurrow's memory on a USB-connected Android phone and reports the peak.

.DESCRIPTION
Prints the app's resident memory (RSS) about four times a second until you
press Ctrl+C, then prints the starting value, the peak and the kernel's
high-water mark (VmHWM, the highest RSS since the app started). Run it once
per test case: start it, open the message in the app, wait until it is shown,
go back, then press Ctrl+C.

Reads only /proc/<pid>/status of the MailBurrow process through adb. It sends
nothing anywhere and prints no message content, addresses or keys.

.PARAMETER Label
A short name for the case, printed with the summary (for example near-limit).

.PARAMETER Package
The app's package name. Defaults to the release app.

.PARAMETER Adb
Path to adb.exe. Defaults to the Android SDK copy under %LOCALAPPDATA%.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File tools\sample_app_memory.ps1 -Label text-1m
#>
param(
    [string]$Label = "case",
    [string]$Package = "com.kuncarlos91.mailburrow",
    [string]$Adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path $Adb)) { $Adb = "adb" }

$appPid = (& $Adb shell pidof $Package 2>$null | Out-String).Trim()
if (-not $appPid) {
    Write-Host "MailBurrow is not running on the phone. Open it first, then run this again."
    exit 1
}
$probe = (& $Adb shell "grep VmRSS /proc/$appPid/status" 2>$null | Out-String).Trim()
if (-not $probe) {
    Write-Host "This phone does not allow reading the app's memory this way."
    Write-Host "Use instead, before and after opening the message:"
    Write-Host "  & `"$Adb`" shell dumpsys meminfo $Package | findstr TOTAL"
    exit 1
}

function Read-Kb([string]$line) {
    if ($line -match '(\d+)\s*kB') { return [int64]$Matches[1] }
    return $null
}

$start = $null; $peak = 0; $hwm = 0
Write-Host "Sampling $Package (pid $appPid) for '$Label'. Open the message now; press Ctrl+C when done."
# One adb call runs the sampling loop on the phone, so samples aren't slowed
# by starting adb each time.
$loop = "while kill -0 $appPid 2>/dev/null; do grep -E 'VmRSS|VmHWM' /proc/$appPid/status | tr '\n' ' '; echo; sleep 0.25; done"
try {
    & $Adb shell $loop | ForEach-Object {
        $parts = $_ -split 'VmHWM:'
        $rss = Read-Kb ($parts[0])
        if ($parts.Count -gt 1) { $h = Read-Kb ($parts[1]); if ($h) { $hwm = $h } }
        if ($rss) {
            if ($null -eq $start) { $start = $rss }
            if ($rss -gt $peak) {
                $peak = $rss
                Write-Host ("  new peak {0,8:N1} MB" -f ($peak / 1024))
            }
        }
    }
    Write-Host "The app stopped (it may have been closed or run out of memory)."
}
finally {
    if ($null -ne $start) {
        Write-Host ""
        Write-Host ("Case: {0}" -f $Label)
        Write-Host ("  start RSS   {0,8:N1} MB" -f ($start / 1024))
        Write-Host ("  peak RSS    {0,8:N1} MB  (growth {1:N1} MB)" -f ($peak / 1024), (($peak - $start) / 1024))
        Write-Host ("  VmHWM       {0,8:N1} MB  (highest since the app started)" -f ($hwm / 1024))
    }
}

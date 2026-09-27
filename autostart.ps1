# Keep solocam running in the background, so "OBS Virtual Camera" is always live.
# A shortcut in the user's Startup folder (no admin needed) starts it at logon via pythonw (no console).
#   autostart.bat install [solocam args]   create the shortcut and start now (args are baked in)
#   autostart.bat remove                   stop and delete the shortcut
#   autostart.bat start | stop | status
# Log: solocam.log next to this file.
param([string]$cmd = "status", [Parameter(ValueFromRemainingArguments)][string[]]$rest)
$dir = $PSScriptRoot
$lnk = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\solocam.lnk"
$pyw = "$dir\.venv\Scripts\pythonw.exe"
function Procs { Get-CimInstance Win32_Process | ? { $_.CommandLine -match 'solocam\.py' -and $_.Name -like 'python*' } }
function Stop-All { Procs | % { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }
function Start-It {
    if (Procs) { "already running"; return }
    $args = if (Test-Path $lnk) { (New-Object -ComObject WScript.Shell).CreateShortcut($lnk).Arguments } else { "solocam.py" }
    Start-Process -FilePath $pyw -ArgumentList $args -WorkingDirectory $dir
}
switch ($cmd) {
    "install" {
        $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
        $s.TargetPath = $pyw; $s.Arguments = ("solocam.py " + ($rest -join " ")).Trim()
        $s.WorkingDirectory = $dir; $s.WindowStyle = 7; $s.Save()
        Stop-All; Start-Sleep 1; Start-It; "installed: $lnk"
    }
    "remove"  { Stop-All; Remove-Item $lnk -ErrorAction SilentlyContinue; "removed" }
    "start"   { Start-It }
    "stop"    { Stop-All; "stopped" }
    default   {
        "autostart: " + $(if (Test-Path $lnk) { "on (" + (New-Object -ComObject WScript.Shell).CreateShortcut($lnk).Arguments + ")" } else { "off" })
        $p = Procs; if ($p) { "running, pid $($p.ProcessId)" } else { "not running" }
    }
}

# Keep solocam running in the background, so the "solocam" camera is always in the system.
# A shortcut in the user's Startup folder (no admin needed) starts it at logon via pythonw (no console).
#   autostart.bat install [solocam args]   create the shortcuts (solocam + tray panel) and start now (args are baked in)
#   autostart.bat remove                   stop both and delete the shortcuts
#   autostart.bat start | stop | status
# Log: solocam.log next to this file.
param([string]$cmd = "status", [Parameter(ValueFromRemainingArguments)][string[]]$rest)
$dir = $PSScriptRoot
$lnk = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\solocam.lnk"
$trayLnk = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\solocam-tray.lnk"
$trayVbs = "$dir\tray\solocam-tray.vbs"
function Tray-Procs { Get-CimInstance Win32_Process | ? { $_.CommandLine -match 'solocam-tray\.ps1' -and $_.Name -eq 'powershell.exe' } }
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
        $t = (New-Object -ComObject WScript.Shell).CreateShortcut($trayLnk)
        $t.TargetPath = "$env:WINDIR\System32\wscript.exe"; $t.Arguments = "`"$trayVbs`""; $t.Save()
        Stop-All; Start-Sleep 1; Start-It
        if (-not (Tray-Procs)) { Start-Process "$env:WINDIR\System32\wscript.exe" "`"$trayVbs`"" }
        "installed: $lnk, $trayLnk"
    }
    "remove"  { Stop-All; Tray-Procs | % { Stop-Process -Id $_.ProcessId -Force }; Remove-Item $lnk, $trayLnk -ErrorAction SilentlyContinue; "removed" }
    "start"   { Start-It }
    "stop"    { Stop-All; "stopped" }
    default   {
        "autostart: " + $(if (Test-Path $lnk) { "on (" + (New-Object -ComObject WScript.Shell).CreateShortcut($lnk).Arguments + ")" } else { "off" })
        $p = Procs; if ($p) { "running, pid $($p.ProcessId)" } else { "not running" }
    }
}

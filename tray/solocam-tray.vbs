Set s = CreateObject("WScript.Shell")
s.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & Replace(WScript.ScriptFullName, ".vbs", ".ps1") & """", 0, False

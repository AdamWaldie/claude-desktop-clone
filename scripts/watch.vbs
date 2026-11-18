' Runs Watch-ClaudeUpdates.ps1 fully hidden (no PowerShell console flash).
' The .ps1 is expected to live next to this .vbs file. Setup.ps1 registers a
' per-user scheduled task that runs:  wscript.exe watch.vbs

Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = fso.BuildPath(scriptDir, "Watch-ClaudeUpdates.ps1")

Set sh = CreateObject("WScript.Shell")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """"

' 0 = hidden window, False = don't wait.
sh.Run cmd, 0, False

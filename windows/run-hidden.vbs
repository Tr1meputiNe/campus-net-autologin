' campus-net-autologin: launch a PowerShell script with no visible window.
'
' Why: the scheduled task fires every minute. Launching powershell.exe directly
' (even with -WindowStyle Hidden) still creates a console window that flashes.
' wscript.exe is a GUI host with no console of its own, and WshShell.Run with
' window style 0 starts the child process hidden.
'
' Usage:  wscript.exe run-hidden.vbs "C:\path\to\script.ps1"

Option Explicit

Dim args, script, cmd, sh
Set args = WScript.Arguments

If args.Count < 1 Then
    WScript.Quit 2
End If

script = args(0)
cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & script & """"

Set sh = CreateObject("WScript.Shell")
' 0 = hidden window, False = do not wait for it to finish
sh.Run cmd, 0, False

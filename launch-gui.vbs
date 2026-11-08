' launch-gui.vbs - start the llmctl GUI with no console window
' Uses Chr(34) for quotes so the command line needs no "" escaping.
' Keep this file ASCII-only: wscript reads .vbs as ANSI, so UTF-8 text breaks parsing.

Dim sh, q, cmd
Set sh = CreateObject("WScript.Shell")

q = Chr(34)
' Resolve the script's own folder so the launcher works wherever the project is copied.
Dim fso, here
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)

cmd = "pwsh.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File " & q & here & "\llmctl.ps1" & q & " gui"

On Error Resume Next
sh.Run cmd, 0, False
If Err.Number <> 0 Then
    MsgBox "Failed to start llmctl GUI: " & Err.Description & vbCrLf & vbCrLf & _
           "Make sure PowerShell 7 (pwsh.exe) is installed and on PATH.", 16, "llmctl"
End If
On Error GoTo 0


' GsController local console launcher (production entry).
' Asks the user once through UAC ("runas") and then runs product/gs-console.ps1
' through the 64-bit Windows PowerShell 5.1 with a hidden window, WITHOUT
' relying on PATH: a 32-bit wscript.exe cannot see System32, so the launcher
' targets Sysnative first (only valid on 64-bit Windows) and falls back to
' the System32 path. The server itself refuses to start on anything but
' 64-bit Windows / 64-bit Windows PowerShell 5.1 Desktop. It never registers
' a URL ACL, a firewall rule, a scheduled task or a service.
'
' Optional argument (STRICT whitelist): Sunshine or Legacy. It is forwarded
' to the server as a fixed -Backend <value>. With NO argument the server
' decides from the build-generated gs-install-profile.json (a missing file
' means Legacy). Any other argument is refused with a message and no launch:
' argument text is never concatenated into the command line. The installed
' Start-menu shortcut runs this VBS without arguments (the build profile
' decides); the Sunshine source-tree entry passes the fixed argument
' Sunshine.
Option Explicit
Dim fso, shell, shellApp, scriptDir, psPath, command, backendArgument
Set fso = CreateObject("Scripting.FileSystemObject")
' WScript.Shell is used ONLY for environment-variable expansion: it has no
' ShellExecute method. The "runas" verb belongs to Shell.Application.
Set shell = CreateObject("WScript.Shell")
Set shellApp = CreateObject("Shell.Application")
backendArgument = ""
If WScript.Arguments.Count > 1 Then
    MsgBox "Use no argument, Sunshine or Legacy only.", 16, "GsController"
    WScript.Quit 1
End If
If WScript.Arguments.Count > 0 Then
    If LCase(WScript.Arguments(0)) = "sunshine" Then
        backendArgument = " -Backend Sunshine"
    ElseIf LCase(WScript.Arguments(0)) = "legacy" Then
        backendArgument = " -Backend Legacy"
    Else
        MsgBox "Unsupported launch argument. Use no argument, Sunshine or Legacy.", 16, "GsController"
        WScript.Quit 1
    End If
End If
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
If fso.FolderExists(shell.ExpandEnvironmentStrings("%SystemRoot%\Sysnative\WindowsPowerShell\v1.0")) Then
    psPath = shell.ExpandEnvironmentStrings("%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe")
Else
    psPath = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
End If
If Not fso.FileExists(psPath) Then
    MsgBox "Windows PowerShell 5.1 (64-bit) was not found on this computer.", 16, "GsController"
    WScript.Quit 1
End If
command = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & scriptDir & "\gs-console.ps1"" -ShowStartupErrors" & backendArgument
' ShellExecute on Shell.Application with the "runas" verb asks UAC once;
' window style 0 keeps the console hidden.
shellApp.ShellExecute psPath, command, "", "runas", 0

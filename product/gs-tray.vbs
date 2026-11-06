' GsController tray UI launcher.
' Runs product/gs-tray.ps1 (next to this file) through powershell.exe with a
' hidden window (window style 0) and without waiting, so no console window
' ever appears.
Option Explicit
Dim fso, shell, scriptDir, command
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & scriptDir & "\gs-tray.ps1"""
shell.Run command, 0, False

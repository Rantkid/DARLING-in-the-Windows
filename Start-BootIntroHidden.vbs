Option Explicit

Dim shell
Dim fso
Dim scriptDir
Dim powershellExe
Dim bootScript
Dim command

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
powershellExe = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
bootScript = scriptDir & "\Start-BootIntro.ps1"

command = """" & powershellExe & """" & " -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File " & """" & bootScript & """"
shell.Run command, 0, False

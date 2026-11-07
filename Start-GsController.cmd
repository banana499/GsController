@echo off
setlocal
set "GsConsole=%~dp0product\gs-console.vbs"
if not exist "%GsConsole%" (
  echo GsController console launcher was not found.
  echo Open this launcher from a complete source checkout.
  pause
  exit /b 1
)
set "GsScriptHost=%SystemRoot%\System32\wscript.exe"
if defined PROCESSOR_ARCHITEW6432 set "GsScriptHost=%SystemRoot%\Sysnative\wscript.exe"
start "" "%GsScriptHost%" "%GsConsole%"
endlocal

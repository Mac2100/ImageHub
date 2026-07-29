@echo off
REM Launches Provision.ps1 at first logon.
REM
REM This exists for the same reason as Stage.cmd: the answer file's command
REM strings are length-limited, and the PowerShell that used to be inlined here
REM came to 302 characters. An over-length value invalidates the whole unattend
REM file, and Windows only reports it after the image is applied.
REM
REM Prefers the staged copy on C:, falls back to searching the drives in case
REM Stage.cmd never ran — provisioning should still work off the media.

REM The answer file scans every drive letter for this script, so it can be
REM invoked more than once when a staged copy and the media copy both exist.
REM The marker makes the second invocation a no-op instead of provisioning twice.
if exist "C:\ImageHub\.launched" exit /b 0
if not exist "C:\ImageHub" mkdir "C:\ImageHub"
echo %DATE% %TIME%>"C:\ImageHub\.launched"

setlocal enabledelayedexpansion
set "PS1=C:\ImageHub\Provision.ps1"

if not exist "%PS1%" (
  for %%d in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist "%%d:\ImageHub\Provision.ps1" (
      set "PS1=%%d:\ImageHub\Provision.ps1"
      goto :found
    )
  )
)

:found
if not exist "%PS1%" (
  echo Provision.ps1 was not found on any drive.
  exit /b 0
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
exit /b %errorlevel%

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

REM FirstLogonCommands runs with the logged-on user's *filtered* token, so even
REM though ITAdmin is an administrator, privileges like SeRestorePrivilege are
REM stripped. Loading C:\Users\Default\NTUSER.DAT then fails with "Attempted to
REM perform an unauthorized operation" and every default-user setting is lost.
REM
REM A scheduled task registered for the current user with /rl HIGHEST runs with
REM the full token and *no* UAC prompt, and still runs inside the interactive
REM session -- which matters, because the splash screen has to be visible. Running
REM it as SYSTEM would elevate too, but land in session 0 where nobody sees it.
set "TASK=ImageHubProvision"
set "CMD=powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"%PS1%\""

schtasks /create /tn "%TASK%" /tr "%CMD%" /sc ONCE /st 00:00 /rl HIGHEST /f >nul 2>&1
if errorlevel 1 goto :direct

schtasks /run /tn "%TASK%" >nul 2>&1
if errorlevel 1 (
  schtasks /delete /tn "%TASK%" /f >nul 2>&1
  goto :direct
)

REM Wait for it to finish. Status is "Running" while it works; anything else means
REM it has stopped. No overall cap: provisioning legitimately takes 10-40 minutes
REM and the individual steps have their own timeouts.
:wait
timeout /t 10 /nobreak >nul 2>&1
schtasks /query /tn "%TASK%" /fo LIST 2>nul | find "Running" >nul 2>&1
if not errorlevel 1 goto :wait

schtasks /delete /tn "%TASK%" /f >nul 2>&1
exit /b 0

:direct
REM Elevation was unavailable, so run it directly and let Provision.ps1 report
REM which steps it could not complete rather than silently skipping them.
echo Could not register the elevated task; running provisioning directly.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
exit /b %errorlevel%

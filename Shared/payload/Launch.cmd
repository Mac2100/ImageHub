@echo off
REM Launches Provision.ps1 at first logon.
REM
REM This exists for the same reason as Stage.cmd: the answer file's command
REM strings are length-limited, and the PowerShell that used to be inlined here
REM came to 302 characters. An over-length value invalidates the whole unattend
REM file, and Windows only reports it after the image is applied.
REM
REM Prefers the staged copy on C:, falls back to searching the drives in case
REM Stage.cmd never ran - provisioning should still work off the media.
REM
REM Every decision goes to C:\ImageHub\launch.log. A machine came back with no
REM provisioning and no logs at all, and there was nothing to read, because this
REM script trusted schtasks: it waited ten seconds, and if the task did not report
REM "Running" by then it deleted the task and exited 0 without a word. The state
REM is briefly something other than "Running" while a task starts, so on a machine
REM slower to get going that was a coin flip. It now waits for proof that
REM provisioning really started - its own log file - and runs it directly if that
REM proof never arrives.

if not exist "C:\ImageHub" mkdir "C:\ImageHub"
set "LOG=C:\ImageHub\launch.log"
echo ---------------------------------------------->>"%LOG%"
echo %DATE% %TIME% Launch.cmd started, invoked as %~f0>>"%LOG%"

REM The answer file scans every drive letter for this script, so it can be invoked
REM more than once when a staged copy and the media copy both exist -- and now
REM RunOnce can invoke it at the same moment as FirstLogonCommands. The marker
REM makes every call after the first a no-op instead of provisioning twice.
REM
REM It is a directory, not a file, because mkdir either creates it or fails: that
REM is atomic, so two callers arriving together cannot both win. "if exist" then
REM "create" has a gap between the two, which is all a race needs.
mkdir "C:\ImageHub\.launched" 2>nul
if errorlevel 1 (
  echo %DATE% %TIME% Another launcher already claimed this run - nothing to do.>>"%LOG%"
  exit /b 0
)

setlocal enabledelayedexpansion
set "PS1=C:\ImageHub\Provision.ps1"

if not exist "%PS1%" (
  echo %DATE% %TIME% No staged copy on C:, searching the drives.>>"%LOG%"
  for %%d in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist "%%d:\ImageHub\Provision.ps1" (
      set "PS1=%%d:\ImageHub\Provision.ps1"
      goto :found
    )
  )
)

:found
if not exist "!PS1!" (
  echo %DATE% %TIME% Provision.ps1 was not found on any drive. Giving up.>>"%LOG%"
  REM Release the claim: this launcher achieved nothing, so the other one -- or
  REM the next logon -- should still get its turn.
  rmdir "C:\ImageHub\.launched" 2>nul
  exit /b 0
)
echo %DATE% %TIME% Using !PS1!>>"%LOG%"

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
set "CMD=powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"!PS1!\""

schtasks /create /tn "%TASK%" /tr "!CMD!" /sc ONCE /st 00:00 /rl HIGHEST /f >>"%LOG%" 2>&1
if errorlevel 1 (
  echo %DATE% %TIME% schtasks /create failed, running directly instead.>>"%LOG%"
  goto :direct
)

schtasks /run /tn "%TASK%" >>"%LOG%" 2>&1
if errorlevel 1 (
  echo %DATE% %TIME% schtasks /run failed, running directly instead.>>"%LOG%"
  schtasks /delete /tn "%TASK%" /f >nul 2>&1
  goto :direct
)

REM Proof, not trust. Provision.ps1 creates its log as its first act, so that file
REM appearing is the only reliable signal that it is really running. Two minutes
REM is far longer than starting PowerShell can take and far shorter than
REM provisioning itself.
set /a PROOF=0
:proof
timeout /t 5 /nobreak >nul 2>&1
if exist "C:\ImageHub\logs\provision-*.log" goto :started
set /a PROOF+=1
if !PROOF! lss 24 goto :proof

echo %DATE% %TIME% The task started but produced no log within 120s. Running directly.>>"%LOG%"
schtasks /delete /tn "%TASK%" /f >nul 2>&1
goto :direct

:started
echo %DATE% %TIME% Provisioning is running under the scheduled task.>>"%LOG%"

REM Wait for it to finish. Status is "Running" while it works; anything else means
REM it has stopped. No overall cap: provisioning legitimately takes 10-40 minutes
REM and the individual steps have their own timeouts.
:wait
timeout /t 10 /nobreak >nul 2>&1
schtasks /query /tn "%TASK%" /fo LIST 2>nul | find "Running" >nul 2>&1
if not errorlevel 1 goto :wait

echo %DATE% %TIME% The scheduled task has finished.>>"%LOG%"
schtasks /delete /tn "%TASK%" /f >nul 2>&1
exit /b 0

:direct
REM Elevation was unavailable, so run it directly and let Provision.ps1 report
REM which steps it could not complete rather than silently skipping them.
echo %DATE% %TIME% Running provisioning directly, without the elevated task.>>"%LOG%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "!PS1!"
echo %DATE% %TIME% Direct run exited with !errorlevel!.>>"%LOG%"
exit /b 0

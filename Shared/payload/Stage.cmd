@echo off
REM Copies the ImageHub payload from the boot media to C:\ImageHub during Setup's
REM specialize pass, so provisioning keeps working after the drive is unplugged.
REM
REM This exists because RunSynchronousCommand/Path is capped at 259 characters.
REM The staging logic used to be an inline PowerShell one-liner in the answer
REM file; at 324 characters Windows rejected the entire unattend file with
REM "Value is invalid" (0x80220005) *after* the image was applied, which left the
REM machine looping on "The computer restarted unexpectedly".
REM
REM %~dp0 is this script's own folder -- i.e. <media>\ImageHub\ -- so the drive
REM letter never has to be guessed. The answer file only has to be short enough
REM to find and call this.

setlocal
set "SRC=%~dp0"
set "DEST=C:\ImageHub"

if not exist "%DEST%" mkdir "%DEST%"

REM /E all subdirectories including empty, /I assume dir, /Y overwrite,
REM /Q quiet, /H include hidden. Exclude this script copying over itself.
xcopy "%SRC%*" "%DEST%\" /E /I /Y /Q /H >"%DEST%\stage.log" 2>&1

if errorlevel 1 (
  echo xcopy returned %errorlevel% >>"%DEST%\stage.log"
) else (
  echo Staged payload from %SRC% >>"%DEST%\stage.log"
)

REM A second, independent way in.
REM
REM Provisioning is normally started by FirstLogonCommands in the answer file. If
REM that never fires -- and a machine came back with an intact C:\ImageHub, no
REM provisioning, and no launch log, which is exactly what that looks like -- then
REM nothing else was going to start it and the machine strands with a staged
REM payload it never used. RunOnce fires at the first interactive logon by a
REM different mechanism entirely, so it covers that case; Launch.cmd's .launched
REM marker means whichever gets there first wins and the other is a no-op.
REM
REM RunOnce runs with the user's filtered token, same as FirstLogonCommands, which
REM is fine: Launch.cmd re-launches itself elevated through a scheduled task.
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v ImageHubProvision ^
  /t REG_SZ /d "\"%DEST%\Launch.cmd\"" /f >>"%DEST%\stage.log" 2>&1
if errorlevel 1 (
  echo Could not register the RunOnce fallback. >>"%DEST%\stage.log"
) else (
  echo Registered the RunOnce fallback for Launch.cmd. >>"%DEST%\stage.log"
)

REM Never fail the Setup pass: a missing payload is recoverable by hand, a failed
REM specialize command is not.
exit /b 0

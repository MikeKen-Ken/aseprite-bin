@echo off
setlocal

set "SOURCE=%~dp0"
set "DESTINATION=%~1"
set "CLEANUP_SCRIPT=%SOURCE%cleanup-update-source.ps1"

if "%DESTINATION%"=="" (
  echo Usage:
  echo   Drag your existing Aseprite folder onto update-existing.cmd
  echo.
  echo This updates the program and bundled extensions without replacing
  echo the existing aseprite.ini portable configuration.
  echo After success, the extracted update source is removed automatically.
  if not defined ASEPRITE_UPDATE_NO_PAUSE pause
  exit /b 2
)

for %%I in ("%DESTINATION%") do set "DESTINATION=%%~fI"
for %%I in ("%SOURCE%.") do set "SOURCE_FULL=%%~fI"

if not exist "%DESTINATION%\aseprite.exe" (
  echo ERROR: The selected folder does not contain aseprite.exe:
  echo   %DESTINATION%
  if not defined ASEPRITE_UPDATE_NO_PAUSE pause
  exit /b 2
)

if not exist "%CLEANUP_SCRIPT%" (
  echo ERROR: The update package is missing cleanup-update-source.ps1.
  if not defined ASEPRITE_UPDATE_NO_PAUSE pause
  exit /b 2
)

powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass ^
  -File "%CLEANUP_SCRIPT%" ^
  -SourceDirectory "%SOURCE_FULL%" ^
  -DestinationDirectory "%DESTINATION%" ^
  -ValidateOnly
if errorlevel 1 (
  echo ERROR: The source and destination folder arrangement is unsafe.
  if not defined ASEPRITE_UPDATE_NO_PAUSE pause
  exit /b 2
)

echo Updating:
echo   From: %SOURCE_FULL%
echo   To:   %DESTINATION%
echo.
echo Preserving:
echo   %DESTINATION%\aseprite.ini
echo.

robocopy "%SOURCE_FULL%" "%DESTINATION%" /E /R:2 /W:1 /XF aseprite.ini /NFL /NDL /NJH /NJS /NP
set "ROBOCOPY_EXIT=%ERRORLEVEL%"

rem Robocopy exit codes 0-7 indicate success, including files copied or skipped.
if %ROBOCOPY_EXIT% GEQ 8 (
  echo.
  echo ERROR: Update failed. Robocopy exit code: %ROBOCOPY_EXIT%
  echo The extracted update source was kept so you can retry.
  if not defined ASEPRITE_UPDATE_NO_PAUSE pause
  exit /b %ROBOCOPY_EXIT%
)

echo.
echo Update complete. Your existing aseprite.ini and user files were preserved.

if defined ASEPRITE_UPDATE_KEEP_SOURCE (
  echo The extracted update source was kept by ASEPRITE_UPDATE_KEEP_SOURCE.
  if not defined ASEPRITE_UPDATE_NO_PAUSE pause
  exit /b 0
)

if not defined ASEPRITE_UPDATE_NO_PAUSE (
  echo Press any key to close this window and remove the extracted update source.
  pause
)

echo Removing the extracted update source in the background.
start "" /b powershell.exe -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden ^
  -ExecutionPolicy Bypass ^
  -File "%CLEANUP_SCRIPT%" ^
  -SourceDirectory "%SOURCE_FULL%" ^
  -DestinationDirectory "%DESTINATION%"

exit /b 0

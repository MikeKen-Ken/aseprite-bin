@echo off
setlocal

set "SOURCE=%~dp0"
set "DESTINATION=%~1"

if "%DESTINATION%"=="" (
  echo Usage:
  echo   Drag your existing Aseprite folder onto update-existing.cmd
  echo.
  echo This updates the program and bundled extensions without replacing
  echo the existing aseprite.ini portable configuration.
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

if /I "%SOURCE_FULL%"=="%DESTINATION%" (
  echo ERROR: The source and destination folders are the same.
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

robocopy "%SOURCE_FULL%" "%DESTINATION%" /E /R:2 /W:1 /XF aseprite.ini
set "ROBOCOPY_EXIT=%ERRORLEVEL%"

rem Robocopy exit codes 0-7 indicate success, including files copied or skipped.
if %ROBOCOPY_EXIT% GEQ 8 (
  echo.
  echo ERROR: Update failed. Robocopy exit code: %ROBOCOPY_EXIT%
  if not defined ASEPRITE_UPDATE_NO_PAUSE pause
  exit /b %ROBOCOPY_EXIT%
)

echo.
echo Update complete. Your existing aseprite.ini was preserved.
if not defined ASEPRITE_UPDATE_NO_PAUSE pause
exit /b 0

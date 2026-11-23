@echo off
rem Starts the Gladius home-network relay. Double-click this file.
cd /d "%~dp0..\.."
where node >nul 2>nul
if errorlevel 1 (
  echo Node.js was not found. Install Node.js, then try again.
  pause
  exit /b 2
)
if not exist "build\web\index.html" (
  echo build\web\index.html was not found. Export the Web preset first.
  pause
  exit /b 2
)
node tools\lan\gladius_lan.mjs
echo.
echo The relay has stopped.
pause

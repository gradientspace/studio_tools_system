@echo off
rem Starts the Studio Tools dev server. Double-click this file, or run it from a terminal.
setlocal
title Studio Tools dev server
cd /d "%~dp0"

where node >nul 2>nul
if errorlevel 1 (
  echo Node.js was not found on PATH. Install Node 20 or newer from https://nodejs.org/
  pause
  exit /b 1
)

node server/server.js
if errorlevel 1 (
  echo.
  echo The dev server exited with an error.
  pause
)
endlocal

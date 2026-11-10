@echo off
setlocal
cd /d "%~dp0"
title FiveCross Data Platform

echo [FiveCross] Starting from %CD%
if not exist ".venv\Scripts\python.exe" (
  echo [ERROR] Missing platform virtual environment: .venv\Scripts\python.exe
  echo Run this once from the project directory:
  echo   uv venv --python 3.11 .venv
  echo   uv pip install --python .venv\Scripts\python.exe -r requirements.txt
  pause
  exit /b 1
)

for /f "tokens=5" %%a in ('netstat -ano ^| findstr ":8000 " ^| findstr "LISTENING"') do (
  echo [FiveCross] Stopping old process %%a on port 8000
  taskkill /F /T /PID %%a >nul 2>&1
)

echo [FiveCross] Launching platform with the project Python environment...
".venv\Scripts\python.exe" -m uvicorn backend.main:app --host 127.0.0.1 --port 8000
set "EXIT_CODE=%ERRORLEVEL%"
echo.
echo [FiveCross] Server stopped with exit code %EXIT_CODE%.
pause
exit /b %EXIT_CODE%


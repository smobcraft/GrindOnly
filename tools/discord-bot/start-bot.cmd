@echo off
setlocal
cd /d "%~dp0"

if not exist ".venv\Scripts\python.exe" (
    echo Bot virtual environment not found. See README.md.
    exit /b 1
)

".venv\Scripts\python.exe" bot.py
exit /b %ERRORLEVEL%

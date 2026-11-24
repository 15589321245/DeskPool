@echo off
setlocal
cd /d "%~dp0"
where py >nul 2>nul
if not errorlevel 1 (
    py -3 deskpool.py %*
) else (
    python deskpool.py %*
)
if errorlevel 1 pause

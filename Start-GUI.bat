@echo off
setlocal
cd /d "%~dp0"

:: Check for Administrator permissions
net session >nul 2>&1
if %errorLevel% neq 0 (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process cmd.exe -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)

:: Run GUI with Administrator rights in STA mode
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Start-GUI.ps1"

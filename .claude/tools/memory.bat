@echo off
setlocal enabledelayedexpansion

REM Wrapper script for memory.py using uv

REM Force UTF-8 encoding for Python output
set "PYTHONIOENCODING=utf-8"

set "SCRIPT_DIR=%~dp0"

REM Check if uv is available
where uv >nul 2>nul
if %ERRORLEVEL% neq 0 (
    echo Installing uv... >&2
    powershell -ExecutionPolicy ByPass -Command "irm https://astral.sh/uv/install.ps1 | iex"
    set "PATH=%USERPROFILE%\.local\bin;%PATH%"
)

REM Clear PYTHONPATH to avoid conflicts with system Python
set "PYTHONPATH="

REM Run with inline dependencies
REM Use forward slashes for Python script path
set "SCRIPT_PATH=%SCRIPT_DIR%memory.py"
set "SCRIPT_PATH=%SCRIPT_PATH:\=/%"

uv run "%SCRIPT_PATH%" %*

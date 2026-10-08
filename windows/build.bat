@echo off
setlocal
echo ===================================================
echo   DeskIsle - Windows x64 Native Build
echo ===================================================

cd /d "%~dp0DeskIsle"

echo [1/2] Checking .NET SDK...
dotnet --version >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo [ERROR] .NET SDK is not found in PATH!
    pause
    exit /b %ERRORLEVEL%
)

echo [2/2] Publishing Release win-x64...
dotnet publish -c Release -r win-x64 --self-contained false -o "..\dist\DeskIsle"
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Build failed!
    pause
    exit /b %ERRORLEVEL%
)

echo ===================================================
echo [SUCCESS] Build completed!
echo Output: %~dp0dist\DeskIsle\DeskIsle.exe
echo ===================================================
pause

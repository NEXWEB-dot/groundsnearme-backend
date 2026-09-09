@echo off
echo ===================================================
echo Pushing groundsnearme-backend to GitHub...
echo Target: https://github.com/NEXWEB-dot/groundsnearme-backend.git
echo ===================================================
cd /d "%~dp0"
"D:\Git\cmd\git.exe" push -u origin main
if %ERRORLEVEL% equ 0 (
    echo.
    echo ===================================================
    echo [SUCCESS] Backend repository pushed successfully!
    echo ===================================================
) else (
    echo.
    echo ===================================================
    echo [NOTE] If connection times out, please turn on your
    echo VPN / WARP and run this script again.
    echo ===================================================
)
pause

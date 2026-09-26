@echo off
setlocal enabledelayedexpansion
set MAX=5
set COUNT=0

:retry
set /a COUNT+=1
echo === Attempt %COUNT% ===
E:\CoEvo\backend\target\release\e2e-k12-runner.exe --subject 数学 --grade g5-6 --concurrency 1
if %ERRORLEVEL%==0 (
    echo === SUCCESS ===
    exit /b 0
)
if %COUNT% lss %MAX% (
    echo === Failed (exit=%ERRORLEVEL%), retrying in 5s ===
    timeout /t 5 /nobreak >nul
    goto retry
)
echo === ALL %MAX% ATTEMPTS FAILED ===
exit /b 1

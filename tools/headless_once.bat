@echo off
for %%I in ("%~dp0..") do set "ROOT=%%~fI"
cd /d "%ROOT%"
"%ROOT%\builds\mangrove\mangrove.exe" --headless cache-check --json builds/cache_check.json > "%ROOT%\builds\headless.out" 2>&1
echo === HL_EXIT=%ERRORLEVEL% === >> "%ROOT%\builds\headless.out"

@echo off
rem Run the release build and mirror progress into builds\build.log.
rem Called by tools\run_build_task.py (which polls this file for BUILD_OK).
rem
rem KEEP ALL COMMENTS ASCII-ONLY (see build_mangrove_release.bat for why).
rem
rem 2026-10-08: the conclusion line is written by THIS wrapper from the inner
rem script's exit code. The inner script's own output cannot be captured here
rem (child output never reaches this file), so waiting for the inner script to
rem print BUILD_OK would time out at 900s on every run even when the build
rem itself succeeded. The inner script now writes builds\step_*.log itself;
rem read those to see what flutter actually said.
for %%I in ("%~dp0..") do set "ROOT=%%~fI"
if not exist "%ROOT%\builds" mkdir "%ROOT%\builds"

echo === wrapper start %date% %time% >> "%ROOT%\builds\build.log"
call "%~dp0build_mangrove_release.bat" >> "%ROOT%\builds\build.log" 2>&1
set "RCODE=%errorlevel%"
if "%RCODE%"=="0" (
  echo === BUILD_OK === >> "%ROOT%\builds\build.log"
) else (
  echo === BUILD_FAIL rc=%RCODE% === >> "%ROOT%\builds\build.log"
)
echo === wrapper end rc=%RCODE% %date% %time% >> "%ROOT%\builds\build.log"
exit /b %RCODE%

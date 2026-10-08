@echo off
rem Build Mangrove release: pub get, analyze, build windows, cmake install.
rem
rem KEEP THIS FILE ASCII-ONLY AND FREE OF PARENTHESES. Four cmd.exe traps, all
rem hit on 2026-10-08, all producing errors that look nothing like the cause:
rem   1. cmd still parses redirection operators (greater-than, and 2
rem      greater-than ampersand 1) even inside a rem line.
rem   2. Non-ASCII UTF-8 bytes make cmd split lines into bogus commands.
rem   3. A left or right paren inside a parenthesised if-block is parsed as a
rem      nested command group, so any echo text containing parens breaks it.
rem   4. The file must use CRLF line endings. LF-only makes cmd mis-parse.
rem
rem Project root is derived from this script's own location, parent of tools,
rem because the project directory will be renamed later.
rem
rem Each step redirects its OWN output to builds\step_*.log. Reason: the outer
rem wrapper cannot capture child output, so flutter's error text stayed
rem invisible and a failed build looked exactly like a slow one.
for %%I in ("%~dp0..") do set "ROOT=%%~fI"

set PATH=C:\Flutter\bin;D:\dev\tools;D:\dev\rust\cargo\bin;%PATH%
set HTTP_PROXY=http://127.0.0.1:7890
set HTTPS_PROXY=http://127.0.0.1:7890
set NO_PROXY=localhost,127.0.0.1
set RUSTUP_HOME=D:\dev\rust\rustup
set CARGO_HOME=D:\dev\rust\cargo

if not exist "%ROOT%\builds" mkdir "%ROOT%\builds"
set "L=%ROOT%\builds\step"
del /q "%L%_*.log" 2>nul
set "P=%ROOT%\builds\_inner_probe.txt"

rem Probe: proves this script really started. If it is missing, nothing ran.
echo inner started %date% %time% > "%P%"

cd /d "%ROOT%\Mangrove"

echo === flutter pub get ===
call flutter pub get > "%L%_1_pubget.log" 2>&1
set "RCODE=%errorlevel%"
echo rc pubget = %RCODE%
if not "%RCODE%"=="0" goto fail_pubget

echo === flutter analyze ===
call flutter analyze --no-fatal-infos --no-fatal-warnings > "%L%_2_analyze.log" 2>&1
set "RCODE=%errorlevel%"
echo rc analyze = %RCODE%
if not "%RCODE%"=="0" goto fail_analyze

echo === flutter build windows --release --no-pub ===
call flutter build windows --release --no-pub > "%L%_3_build.log" 2>&1
set "RCODE=%errorlevel%"
echo rc build = %RCODE%
if not "%RCODE%"=="0" goto fail_build

echo === cmake --install ===
"D:\Visual Studio Windows\Visual Studio 2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe" --install "%ROOT%\Mangrove\build\windows\x64" > "%L%_4_install.log" 2>&1
set "RCODE=%errorlevel%"
echo rc install = %RCODE%
if not "%RCODE%"=="0" goto fail_install

echo === BUILD_OK ===
echo inner ok %date% %time% >> "%P%"
exit /b 0

:fail_pubget
echo === BUILD_FAIL pubget rc=%RCODE% ===
echo === BUILD_FAIL pubget rc=%RCODE% === >> "%P%"
exit /b 1

:fail_analyze
echo === BUILD_FAIL analyze rc=%RCODE% ===
echo === BUILD_FAIL analyze rc=%RCODE% === >> "%P%"
exit /b 1

:fail_build
echo === BUILD_FAIL build rc=%RCODE% ===
echo === BUILD_FAIL build rc=%RCODE% === >> "%P%"
exit /b 1

:fail_install
echo === BUILD_FAIL install rc=%RCODE% ===
echo === BUILD_FAIL install rc=%RCODE% === >> "%P%"
exit /b 1

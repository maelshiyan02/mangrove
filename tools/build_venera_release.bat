@echo off
rem ============================================================================
rem 构建 VeneraX release（analyze -> build --release --no-pub -> cmake --install）
rem
rem 🔴 不要写死项目绝对路径：项目根目录将来会改名/搬迁。
rem    项目根 = 本脚本所在目录（tools）的上一级，由 %~dp0 推导。
rem    （下面 C:\Flutter / D:\dev\... / Visual Studio 是"机器级"外部工具链，保留绝对路径）
rem ============================================================================
for %%I in ("%~dp0..") do set "ROOT=%%~fI"

set PATH=C:\Flutter\bin;D:\dev\tools;D:\dev\rust\cargo\bin;%PATH%
set HTTP_PROXY=http://127.0.0.1:7890
set HTTPS_PROXY=http://127.0.0.1:7890
set NO_PROXY=localhost,127.0.0.1
set RUSTUP_HOME=D:\dev\rust\rustup
set CARGO_HOME=D:\dev\rust\cargo

cd /d "%ROOT%\VeneraX"

echo === flutter pub get ===
call flutter pub get
if errorlevel 1 goto fail

echo === flutter analyze ===
call flutter analyze --no-fatal-infos --no-fatal-warnings
if errorlevel 1 goto fail

echo === flutter build windows --release --no-pub ===
call flutter build windows --release --no-pub
if errorlevel 1 goto fail

echo === cmake --install ===
"D:\Visual Studio Windows\Visual Studio 2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe" --install "%ROOT%\VeneraX\build\windows\x64"
if errorlevel 1 goto fail

echo === BUILD_OK ===
exit /b 0
:fail
echo === BUILD_FAIL ===
exit /b 1

@echo off
rem 构建并把全过程日志落 builds/build.log（由 tools/run_build_task.py 调用）
rem 项目根由脚本自身位置推导（tools 的上一级），不要写死绝对路径。
for %%I in ("%~dp0..") do set "ROOT=%%~fI"
if not exist "%ROOT%\builds" mkdir "%ROOT%\builds"
call "%~dp0build_venera_release.bat" > "%ROOT%\builds\build.log" 2>&1

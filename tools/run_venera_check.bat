@echo off
rem 一次性 flutter analyze / test（结果落 tools/ 下）
rem 项目根由脚本自身位置推导（tools 的上一级），不要写死绝对路径。
for %%I in ("%~dp0..") do set "ROOT=%%~fI"
set PATH=C:\Flutter\bin;D:\dev\tools;%PATH%
cd /d "%ROOT%\VeneraX"
call flutter analyze > "%~dp0analyze_out.txt" 2>&1
call flutter test > "%~dp0test_out.txt" 2>&1

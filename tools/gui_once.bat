@echo off
for %%I in ("%~dp0..") do set "ROOT=%%~fI"
cd /d "%ROOT%\builds\mangrove"
start "" "%ROOT%\builds\mangrove\mangrove.exe"

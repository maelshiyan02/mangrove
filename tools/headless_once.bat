@echo off
for %%I in ("%~dp0..") do set "ROOT=%%~fI"
cd /d "%ROOT%"
"%ROOT%\builds\mangrove\mangrove.exe" --headless edit-check D:/Mangrove_Windows/ComicLibrary/projects/MDGH-ch1/imgtrans_MDGH-ch1.json > "%ROOT%\builds\headless.out" 2>&1
echo === HL_EXIT=%ERRORLEVEL% === >> "%ROOT%\builds\headless.out"

@echo off
for %%I in ("%~dp0..") do set "ROOT=%%~fI"
cd /d "%ROOT%"
"%ROOT%\builds\venera\venera.exe" --headless edit-check ComicLibrary/projects/S9Fixture/imgtrans_S9Fixture.json > "%ROOT%\builds\headless.out" 2>&1
echo === HL_EXIT=%ERRORLEVEL% === >> "%ROOT%\builds\headless.out"

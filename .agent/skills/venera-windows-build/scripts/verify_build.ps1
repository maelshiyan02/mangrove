# verify_build.ps1 - Verify the builds/venera release artifact after a build.
# Run from anywhere:
#   powershell -ExecutionPolicy Bypass -File <skill>\scripts\verify_build.ps1 [-SmokeSeconds 8]
# Exit code 0 = all checks passed and smoke process stayed alive.
param(
    [int]$SmokeSeconds = 8
)

$ErrorActionPreference = 'Stop'

# scripts/ -> skill/ -> skills/ -> .trae/ -> workspace root
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
$dist = Join-Path $root 'builds\venera'
$exe  = Join-Path $dist 'venera.exe'

function Fail($msg) { Write-Host "FAIL: $msg" -ForegroundColor Red; exit 1 }

if (-not (Test-Path $dist)) { Fail "missing $dist" }

$required = @(
    'venera.exe',
    'data\icudtl.dat',
    'data\app.so',
    'data\flutter_assets'
)
foreach ($rel in $required) {
    if (-not (Test-Path (Join-Path $dist $rel))) { Fail "missing $rel" }
}

$files = Get-ChildItem $dist -Recurse -File
$mb = [math]::Round((($files | Measure-Object Length -Sum).Sum / 1MB), 1)
$dllCount = (Get-ChildItem $dist -Filter *.dll).Count
$appSo = Get-Item (Join-Path $dist 'data\app.so')

# The runner exe is a ~0.2 MB shell that does not rebuild on Dart changes;
# app.so is the AOT snapshot and its timestamp proves the new code compiled.
Write-Host "files      : $($files.Count)"
Write-Host "size       : $mb MB"
Write-Host "dlls       : $dllCount"
Write-Host "app.so     : $($appSo.LastWriteTime) ($([math]::Round($appSo.Length/1MB,2)) MB)"
Write-Host "exe        : $((Get-Item $exe).LastWriteTime)"

$age = (Get-Date) - $appSo.LastWriteTime
if ($age.TotalHours -gt 2) {
    Write-Host "WARN: app.so is $([int]$age.TotalHours)h old - was this a fresh build?" -ForegroundColor Yellow
}

$proc = Start-Process -FilePath $exe -PassThru
Start-Sleep -Seconds $SmokeSeconds
if ($proc.HasExited) {
    Fail "venera.exe exited during smoke test (code $($proc.ExitCode))"
}
Stop-Process -Id $proc.Id -Force
Write-Host "SMOKE PASS : process alive after ${SmokeSeconds}s, terminated" -ForegroundColor Green
Write-Host "ALL CHECKS PASSED" -ForegroundColor Green

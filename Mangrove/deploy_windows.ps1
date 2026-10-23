# deploy_windows.ps1 — Flutter Windows 构建后自动部署所有依赖
# 用法: ./deploy_windows.ps1 [-BuildType Debug|Release]
# 坑: flutter build windows 不会自动复制 DLL、app.so、icudtl.dat 到 runner/

param(
    [ValidateSet("Debug","Release")]
    [string]$BuildType = "Debug"
)

Set-Location $PSScriptRoot
$buildRoot = "$PSScriptRoot\build\windows\x64"
$pluginsDir = "$buildRoot\plugins"
$runnerDir = "$buildRoot\runner\$BuildType"
$dataDir = "$runnerDir\data"
$flutterWindowsDll = "C:\Flutter\bin\cache\artifacts\engine\windows-x64\flutter_windows.dll"
$icudtlDat = "C:\Flutter\bin\cache\artifacts\engine\windows-x64\icudtl.dat"

Write-Host "=== Mangrove Windows Deploy ($BuildType) ===" -ForegroundColor Cyan
Write-Host "Runner dir: $runnerDir"
Write-Host ""

if(-not (Test-Path $runnerDir)) {
    Write-Host "❌ $runnerDir 不存在！先跑 flutter build windows --$($BuildType.ToLower())" -ForegroundColor Red
    exit 1
}

# 1. 创建 data/ 目录
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null

# 2. 复制 Flutter SDK 的 icudtl.dat
if(Test-Path $icudtlDat) {
    Copy-Item $icudtlDat -Destination "$dataDir\icudtl.dat" -Force
    Write-Host "✅ icudtl.dat ($([math]::Round((Get-Item "$dataDir\icudtl.dat").Length/1KB,1))KB)" -ForegroundColor Green
} else { Write-Host "⚠️ icudtl.dat 找不到！" -ForegroundColor Yellow }

# 3. 复制 flutter_windows.dll（引擎核心）
if(Test-Path $flutterWindowsDll) {
    Copy-Item $flutterWindowsDll -Destination "$runnerDir\flutter_windows.dll" -Force
    Write-Host "✅ flutter_windows.dll ($([math]::Round((Get-Item "$runnerDir\flutter_windows.dll").Length/1MB,1))MB)" -ForegroundColor Green
}

# 3. 复制 flutter_assets（翻译、shader、asset bundle — 141MB）
$flutterAssets = "$PSScriptRoot\build\flutter_assets"
if(Test-Path $flutterAssets) {
    Copy-Item $flutterAssets -Destination "$dataDir\flutter_assets" -Recurse -Force
    Write-Host "✅ flutter_assets ($([math]::Round((Get-ChildItem "$dataDir\flutter_assets" -Recurse | Measure-Object Length -Sum).Sum/1MB,1))MB)" -ForegroundColor Green
} else { Write-Host "⚠️ flutter_assets 找不到！先 flutter build windows --$($BuildType.ToLower())" -ForegroundColor Yellow }

# 4. 复制 AOT snapshot (app.so)
# Release 版: 由 flutter build windows --release 生成在 build/windows/app.so
# Debug 版: 也需要（引擎硬要找 data/app.so），用 Release 版的即可
$appSoCandidates = @(
    "$PSScriptRoot\build\windows\app.so",
    "$buildRoot\runner\Release\data\app.so",
    "$buildRoot\runner\Debug\data\app.so"
)
$appSo = $appSoCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if($appSo) {
    Copy-Item $appSo -Destination "$dataDir\app.so" -Force
    Write-Host "✅ data/app.so ($([math]::Round((Get-Item "$dataDir\app.so").Length/1MB,1))MB)" -ForegroundColor Green
} else { Write-Host "⚠️ app.so 找不到！先 flutter build windows --release 生成 AOT" -ForegroundColor Yellow }

# 5. 复制所有插件 DLL
$pluginCount = 0
$pluginSuffix = "*_plugin.dll"
Get-ChildItem $pluginsDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $btDir = Join-Path $_.FullName $BuildType
    if(Test-Path $btDir) {
        Get-ChildItem $btDir -Filter "*.dll" -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item $_.FullName -Destination (Join-Path $runnerDir $_.Name) -Force
            $pluginCount++
        }
    }
}
Write-Host "✅ $pluginCount 个插件 DLL 已复制" -ForegroundColor Green

# 6. 复制其他共享 DLL (dartjni, sqlite3, onnxruntime, zip_flutter 等)
$sharedDllSources = @(
    "$pluginsDir\jni\$BuildType\dartjni.dll",
    "$pluginsDir\sqlite3_flutter_libs\$BuildType\sqlite3.dll",
    "$pluginsDir\flutter_onnxruntime\$BuildType\onnxruntime.dll",
    "$pluginsDir\flutter_7zip\shared\$BuildType\flutter_7zip.dll",
    "$pluginsDir\lodepng_flutter\shared\$BuildType\lodepng_flutter.dll",
    "$pluginsDir\zip_flutter\shared\$BuildType\zip_flutter.dll"
)
foreach($dll in $sharedDllSources) {
    if(Test-Path $dll) {
        Copy-Item $dll -Destination (Join-Path $runnerDir (Split-Path $dll -Leaf)) -Force
    }
}
Write-Host "✅ 共享运行时 DLL 已复制" -ForegroundColor Green

Write-Host ""
Write-Host "=== 最终目录结构 ===" -ForegroundColor Cyan
Get-ChildItem $runnerDir -Force | ForEach-Object {
    if($_.PSIsContainer) { "$($_.Name)/" }
    else { "  $($_.Name) ($([math]::Round($_.Length/1KB,1))KB)" }
}
if(Test-Path $dataDir) {
    Write-Host "data/"
    Get-ChildItem $dataDir -Force | ForEach-Object { "  $($_.Name) ($([math]::Round($_.Length/1KB,1))KB)" }
}

Write-Host ""
Write-Host "=== 完成！启动: Start-Process '$runnerDir\mangrove.exe' ===" -ForegroundColor Cyan

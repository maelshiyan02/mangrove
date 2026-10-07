# build_venera.ps1 — Venera Windows 绿色版一键构建
# 用法（普通 PowerShell 窗口）：
#   powershell -ExecutionPolicy Bypass -File .\build_venera.ps1
#
# 环境前提（均为绿色安装，不写系统 PATH）：
#   C:\Flutter                     Flutter SDK 3.47.5
#   D:\dev\tools\nuget.exe         flutter_inappwebview_windows 恢复 NuGet 包用
#   D:\dev\rust                    Rust MSVC 工具链（rhttp 插件 cargokit 编译用）
#   D:\dev\tools\sqlite3-src       sqlite3 源码种子（跳过 CMake 配置期的慢速下载）
#   127.0.0.1:7890                 Clash 代理（GitHub/pub.dev 拉取走它）

$ErrorActionPreference = 'Stop'

$env:HTTP_PROXY  = 'http://127.0.0.1:7890'
$env:HTTPS_PROXY = 'http://127.0.0.1:7890'
$env:NO_PROXY    = 'localhost,127.0.0.1'
$env:RUSTUP_HOME = 'D:\dev\rust\rustup'
$env:CARGO_HOME  = 'D:\dev\rust\cargo'
$env:Path        = "D:\dev\tools;D:\dev\rust\cargo\bin;$env:Path"

$proj = Join-Path $PSScriptRoot 'VeneraX'
if (-not (Test-Path (Join-Path $proj 'pubspec.yaml'))) {
    throw "找不到工程目录：$proj"
}
Set-Location $proj

# sqlite3 种子注入：全新构建（flutter clean 后）先预置 CMakeCache，
# 让 FetchContent 直接用本地源码，不去访问 sqlite.org。
$bd        = Join-Path $proj 'build\windows\x64'
$cacheFile = Join-Path $bd 'CMakeCache.txt'
if (-not (Test-Path $cacheFile)) {
    if (-not (Test-Path 'D:\dev\tools\sqlite3-src\sqlite3.c')) {
        throw "sqlite3 种子缺失：D:\dev\tools\sqlite3-src（从 D:\dev\tools\sqlite-autoconf-3520000.tar.gz 解压，tar -xzf <tarball> -C <dest> --strip-components=1）"
    }
    New-Item -ItemType Directory -Force -Path $bd | Out-Null
    $projUnix = ($proj -replace '\\', '/')
    $content  = "FETCHCONTENT_SOURCE_DIR_SQLITE3:PATH=D:/dev/tools/sqlite3-src`nCMAKE_HOME_DIRECTORY:PATH=$projUnix/windows`n"
    [System.IO.File]::WriteAllText($cacheFile, $content, (New-Object System.Text.ASCIIEncoding))
    Write-Host "已注入 sqlite3 本地种子到 CMakeCache" -ForegroundColor Green
}

flutter pub get
if ($LASTEXITCODE -ne 0) { throw "flutter pub get 失败" }

flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw "flutter build windows 失败" }

Write-Host ""
Write-Host "构建完成。绿色成品目录：$PSScriptRoot\builds\venera" -ForegroundColor Green
Write-Host "整个 builds\venera 文件夹拷到任意位置即可运行（无需安装、无注册表依赖）。"

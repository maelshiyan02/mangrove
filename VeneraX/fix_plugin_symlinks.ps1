# Fix Flutter plugin symlinks using NTFS Junctions (no Windows DevMode needed)
# Usage: cd VeneraX; powershell -ExecutionPolicy Bypass -File fix_plugin_symlinks.ps1
param([string]$ProjectRoot = ".")

$ErrorActionPreference = "SilentlyContinue"
Set-Location $ProjectRoot

$depFile = ".flutter-plugins-dependencies"
if (-not (Test-Path $depFile)) {
    Write-Error "No .flutter-plugins-dependencies found. Run 'flutter pub get' first."
    exit 1
}

$json = Get-Content $depFile -Raw | ConvertFrom-Json
$platforms = $json.plugins.PSObject.Properties
$total = 0

foreach ($p in $platforms) {
    $platName = $p.Name
    $plugins = $p.Value
    $symDir = Join-Path (Resolve-Path ".") "$platName\flutter\ephemeral\.plugin_symlinks"
    New-Item -ItemType Directory -Path $symDir -Force | Out-Null

    $created = 0
    foreach ($plugin in $plugins) {
        $name = $plugin.name
        $target = $plugin.path.TrimEnd("\")
        $link = Join-Path $symDir $name

        if (Test-Path $link) {
            Remove-Item $link -Force -ErrorAction SilentlyContinue
        }

        try {
            New-Item -ItemType Junction -Path $link -Target $target -Force -ErrorAction Stop | Out-Null
            $created++
        } catch {
            Write-Warning "$platName/$name FAIL: $($_.Exception.Message.Substring(0, [Math]::Min(50, $_.Exception.Message.Length)))"
        }
    }
    $total += $created
    Write-Host "$platName : $created / $($plugins.Count) junctions"
}

Write-Host "`nTotal: $total junctions created."
Write-Host "Now run: flutter build windows --debug"

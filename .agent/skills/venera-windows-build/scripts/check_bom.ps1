# ⚠️ 本脚本位于 .agent/skills/venera-windows-build/scripts/ 下，用「自身位置向上 4 级」推导项目根：
#    scripts → venera-windows-build → skills → .agent → 项目根
# 🔴 不要写死项目绝对路径（项目根目录将来会改名/搬迁）。
$root = $PSScriptRoot
1..4 | ForEach-Object { $root = Split-Path -Parent $root }
$p = Join-Path $root 'build_venera.ps1'

$b = [System.IO.File]::ReadAllBytes($p)
if (-not ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) {
    $c = Get-Content -Raw -Encoding UTF8 $p
    [System.IO.File]::WriteAllText($p, $c, (New-Object System.Text.UTF8Encoding($true)))
    Write-Output 'BOM added'
} else {
    Write-Output 'BOM already present'
}

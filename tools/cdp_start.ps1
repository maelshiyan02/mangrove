# CDP Chrome 启动脚本（让用户手动养 cookie）
# 右键用 PowerShell 运行，或在终端执行: ./cdp_start.ps1
#
# 步骤：
#   1. 关闭所有 Chrome 窗口（重要！不能跟正常 Chrome 共享 profile）
#   2. 运行此脚本
#   3. 在打开的 Chrome 窗口里手动操作：
#      - 等 CF challenge 自动过（或手动过）
#      - 浏览首页 → 点几个漫画 → 确保页面完全加载
#      - 搜索 Overgeared → 确保有搜索结果
#   4. 保持 Chrome 开着，启动 Mangrove 测试

$profileDir = "C:\Temp\comix_cdp_final"
Remove-Item $profileDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $profileDir -Force | Out-Null

Write-Host ""
Write-Host "============================================="
Write-Host "  CDP Chrome 启动中..."
Write-Host "  Profile: $profileDir"
Write-Host "  Port: 9222"
Write-Host "============================================="
Write-Host ""
Write-Host "⚠️  不要关闭此 Chrome 窗口！"
Write-Host "   在里面手动浏览 comix.to 建立 cookie 会话"
Write-Host ""

# 用 Start-Process 避免续行符问题
$chromeArgs = @(
    "--remote-debugging-port=9222",
    "--user-data-dir=$profileDir",
    "--no-first-run",
    "--disable-blink-features=AutomationControlled",
    "https://comix.to"
)
Start-Process "C:\Program Files\Google\Chrome\Application\chrome.exe" -ArgumentList $chromeArgs -NoNewWindow -PassThru | Out-Null

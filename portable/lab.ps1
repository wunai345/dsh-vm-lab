# One switch: VM running -> shut everything down; otherwise start everything. Explains what it found.
. "$PSScriptRoot\lib.ps1"

$state = VmState
$vmRun = ($state -eq 'running'); $k = Listening $keyPort; $w = Listening $webPort
$on = $vmRun   # proxies alone do not count: a half-finished start can simply be run again (start-lab skips proxies already up)

Write-Host ""
Write-Host "当前状态:" -ForegroundColor Cyan
Write-Host ("  虚拟机:   " + $(if ($vmRun) { "运行中" } else { "没在运行($state)" }))
Write-Host ("  Key 代理: " + $(if ($k) { "运行中" } else { "没运行" }))
Write-Host ("  网页代理: " + $(if ($w) { "运行中" } else { "没运行" }) + "(模式:$mode)")
Write-Host ""
if ($on) {
    Write-Host "判断:虚拟机正在运行,所以这次是【关闭】整套。" -ForegroundColor Cyan
    Write-Host "(想开而不是关?等它关完,再双击一次 lab.cmd 就是启动。)" -ForegroundColor DarkGray
    & "$dir\stop-lab.ps1"
} else {
    Write-Host "判断:虚拟机没在运行,所以这次是【启动】它(已经开着的代理会自动跳过,不用重复输入)。" -ForegroundColor Cyan
    & "$dir\start-lab.ps1"
}

# Stops the lab: shuts the VM down cleanly and closes both proxy windows. Prints progress (Chinese).
. "$PSScriptRoot\lib.ps1"
function Hint($t) { Write-Host "    >> $t" -ForegroundColor Yellow }
function Good($t) { Write-Host "    OK  $t" -ForegroundColor Green }

Write-Host ""
Write-Host "[1/2] 关闭虚拟机" -ForegroundColor Cyan
$state = VmState
if ($state -eq 'running') {
    Hint "正在给虚拟机发关机信号,通常 10~40 秒,请等一下,不用操作。"
    & $vb controlvm $vmName acpipowerbutton 2>$null | Out-Null
    $done = $false
    for ($i = 1; $i -le 12; $i++) {
        Start-Sleep 5
        if ((VmState) -eq 'poweroff') { $done = $true; break }
        Write-Host "    ... 还在关机(已等 $($i * 5) 秒,最多等 60 秒)" -ForegroundColor DarkGray
    }
    if ($done) { Good "虚拟机已正常关机" }
    else {
        Hint "60 秒还没关好(虚拟机可能卡住了),改为强制关机。这不会损坏东西。"
        & $vb controlvm $vmName poweroff 2>$null | Out-Null
        Start-Sleep 3
        Good "虚拟机已强制关机"
    }
} else {
    Good "虚拟机本来就没在运行(状态: $state)"
}

Write-Host ""
Write-Host "[2/2] 关闭两个代理窗口(Key 和网页代理)" -ForegroundColor Cyan
Get-CimInstance Win32_Process |
    Where-Object { $_.CommandLine -like '*keyproxy.py*' -or $_.CommandLine -like '*webproxy.py*' -or
                   $_.CommandLine -like '*start-proxy.cmd*' -or $_.CommandLine -like '*start-webproxy.cmd*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Good "代理已关闭,真实 Key 已从内存清除"

Write-Host ""
Write-Host "全部关闭完成。要重新使用:再双击一次 lab.cmd。" -ForegroundColor Green

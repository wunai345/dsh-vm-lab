# Health check: shows what works, what does not, and what to do about it (Chinese).
. "$PSScriptRoot\lib.ps1"
$script:abnormal = @()
function Row($ok, $name, $fix) {
    if ($ok) { Write-Host ("  [正常] " + $name) -ForegroundColor Green }
    else { Write-Host ("  [异常] " + $name) -ForegroundColor Red; Write-Host ("         -> " + $fix) -ForegroundColor Yellow; $script:abnormal += $name }
}

Write-Host ""
Write-Host "dsh 实验室体检(网页代理模式:$mode)" -ForegroundColor Cyan
$info = & $vb showvminfo $vmName --machinereadable
$state = ($info | Select-String '^VMState="(.*)"').Matches.Groups[1].Value
$cable2 = ($info | Select-String '^cableconnected2="(.*)"').Matches.Groups[1].Value
$cable1 = ($info | Select-String '^cableconnected1="(.*)"').Matches.Groups[1].Value

Row ($state -eq 'running') "虚拟机在运行(现在: $state)" "没开就双击 lab.cmd 启动。"
Row ($cable2 -eq 'on') "虚拟机的内网线已接上(host-only)" "重新用 lab.cmd 启动,它会自动接上。"
Row ($cable1 -ne 'on') "虚拟机直连外网的线是断开的(应该断着,这样才安全)" "它被接上了,会绕过代理直接上网:马上双击 net-off.cmd,再双击 lab.cmd。"
Row (SshUp) "虚拟机的 SSH 能连上" "虚拟机开机卡住就双击 lab.cmd 关掉整套再开;或等 1~3 分钟。"
Row (Listening $keyPort) "Key 代理在运行($keyPort)" "双击 keyproxy\start-proxy.cmd 并粘贴 Key。"
Row (Listening $webPort) "网页代理在运行($webPort)" "双击 keyproxy\start-webproxy.cmd。"
Row (Listening 3080 '127.0.0.1') "dsh 隧道在运行(3080)" "双击 dsh.cmd。"

if (Listening $keyPort) {
    try {
        $null = Invoke-WebRequest "http://${hostIp}:${keyPort}/v1/models" -Headers @{ Authorization = 'Bearer lab-dummy-key' } -UseBasicParsing -TimeoutSec 15
        Row $true "DeepSeek 接受了这个 Key" ""
    } catch {
        $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch {}
        Row $false "DeepSeek 没接受这个 Key(状态码 $code)" "401 = Key 不对/已删除/没余额:关掉 keyproxy 窗口,重新运行 keyproxy\start-proxy.cmd 贴正确的 Key。"
    }
}
if ($mode -eq 'direct') { Write-Host "  [提示] 当前是真实 IP 模式:虚拟机访问的网站能看到你的真实 IP。" -ForegroundColor Yellow }
Write-Host ""
Write-Host "上面全是 [正常] 还不行?双击 diagnose.cmd,把生成的那句话发给你的 AI 助手。" -ForegroundColor Cyan
if ($script:abnormal.Count) { & "$PSScriptRoot\diagnose.ps1" -Reason ("check-lab abnormal: " + ($script:abnormal -join "; ")) }

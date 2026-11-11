# One-click start for the dsh lab, with step-by-step hints (Chinese). All values come from config.json.
. "$PSScriptRoot\lib.ps1"
. "$PSScriptRoot\remote-cmd.ps1"   # defines $remote

function Step($t) { Write-Host ""; Write-Host $t -ForegroundColor Cyan }
function Hint($t) { Write-Host "    >> $t" -ForegroundColor Yellow }
function Good($t) { Write-Host "    OK  $t" -ForegroundColor Green }
function Bad($t, $fix) {
    Write-Host ""
    Write-Host "    出问题了: $t" -ForegroundColor Red
    Write-Host "    怎么办:   $fix" -ForegroundColor Yellow
    & "$PSScriptRoot\diagnose.ps1" -Reason "$t | $fix"
}
function WaitFor([scriptblock]$test, [int]$secs, [string]$msg) {
    $t0 = Get-Date; $n = 0
    while (((Get-Date) - $t0).TotalSeconds -lt $secs) {
        if (& $test) { return $true }
        Start-Sleep 3; $n++
        if ($n % 5 -eq 0) { Write-Host "    ... $msg (已等 $([int]((Get-Date) - $t0).TotalSeconds) 秒)" -ForegroundColor DarkGray }
    }
    return $false
}

# ---- 0. start the VM right away: its boot overlaps with you pasting the key ----
$state = VmState
if ($state -ne 'running') {
    Step "[0/4] 先在后台启动虚拟机(开机和你贴 Key 同时进行,节省时间)"
    & $vb startvm $vmName --type headless | Out-Null
    $vmStart = Get-Date
}
if (-not $vmStart) { $vmStart = (Get-Date).AddSeconds(-600) }   # VM was already running: no extra boot wait
# the NAT cable stays unplugged on purpose; plug the host-only one in
& $vb controlvm $vmName setlinkstate2 on 2>$null | Out-Null

# ---- 1. key proxy ----
Step "[1/4] Key 代理"
if (-not (Listening $keyPort)) {
    Start-Proxy 'start-proxy.cmd'
    Hint "刚弹出一个黑窗口(标题含 keyproxy)。在里面粘贴一次性 Key,回车。输入时会显示 * 号。"
}
if (-not (WaitFor { Listening $keyPort } 600 "还在等你在 keyproxy 窗口粘贴 Key")) {
    Bad "10 分钟内没有在 keyproxy 窗口输入 Key" "去任务栏找 keyproxy 窗口粘贴 Key 回车;找不到窗口就再双击 lab.cmd 重来。"
    return
}
Good "Key 代理已就绪($keyPort)"
try {
    $null = Invoke-WebRequest "http://${hostIp}:${keyPort}/v1/models" -Headers @{ Authorization = 'Bearer lab-dummy-key' } -UseBasicParsing -TimeoutSec 15
    Good "Key 有效(DeepSeek 已接受)"
} catch {
    $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch {}
    if ($code -eq 401) {
        Bad "DeepSeek 拒绝了这个 Key(401):粘贴有误、Key 已被删除或没有余额" "关掉 keyproxy 窗口 -> 双击 $dir\keyproxy\start-proxy.cmd 重新粘贴正确的 Key -> 再继续。"
        return
    }
    Hint "Key 暂时没法验证(状态码 $code),先继续。如果之后 dsh 提示'API 密钥无效',就重贴 Key。"
}

# ---- 2. web proxy ----
Step "[2/4] 网页代理(给虚拟机上网用,当前模式:$mode)"
if (-not (Listening $webPort)) {
    Start-Proxy 'start-webproxy.cmd'
    if ($mode -eq 'direct') {
        Hint "又弹出一个黑窗口。第一次会提醒:虚拟机访问的网站会看到你的真实 IP。要继续请按窗口里的提示输入 I UNDERSTAND。"
    } else {
        Hint "又弹出一个黑窗口。如果它问 'Type YES':看上面的 IP,是你 VPN 的 IP(不是家里宽带 IP)就输入 YES 回车;不问就不用管。"
    }
}
if (-not (WaitFor { Listening $webPort } 180 "还在等网页代理窗口(如果它在等你确认,请在那个窗口输入)")) {
    Bad "网页代理没有启动" "看网页代理窗口里的提示。如果是端口被占用或被系统保留,重新双击 setup.cmd 让它自动换一个端口。"
    return
}
Good "网页代理已就绪($webPort)"

# ---- 3. VM ----
Step "[3/4] 虚拟机"
$up = WaitFor { SshUp } ([int][Math]::Max(20, 300 - ((Get-Date) - $vmStart).TotalSeconds)) "等虚拟机开机(正常 1~3 分钟)"
if (-not $up) {
    Hint "5 分钟还没开好,多半是开机卡住了。正在自动重启虚拟机一次..."
    & $vb controlvm $vmName reset 2>$null | Out-Null
    Start-Sleep 5
    & $vb controlvm $vmName setlinkstate2 on 2>$null | Out-Null
    $up = WaitFor { SshUp } 300 "重启后等虚拟机开机"
}
if (-not $up) {
    Bad "虚拟机连续两次没开好" "双击 lab.cmd 关掉整套,过几分钟再试;还不行就双击 check-lab.cmd 看哪一项异常。"
    return
}
Good "虚拟机已开好,可以登录"

# ---- 4. dsh ----
Step "[4/4] 登录虚拟机并启动 dsh"
Write-Host ""
Write-Host "  接下来只剩 3 件事:" -ForegroundColor Green
if ($hasKey) { Write-Host "   1. 已启用密钥登录,不会问密码,直接往下走" -ForegroundColor Green } else { Write-Host "   1. 下面会停在一个看不见的密码提示:盲输虚拟机 $vmUser 用户的密码,回车(屏幕不显示字是正常的)" -ForegroundColor Green }
Write-Host "   2. 10~60 秒后出现 'dsh web: http://127.0.0.1:3080/?token=...' :复制整行网址,在浏览器【新标签页】打开" -ForegroundColor Green
Write-Host "   3. 如果出现 'Ok to proceed? (y)' :敲 y 回车" -ForegroundColor Green
Write-Host ""
Write-Host "  网页打不开/输入框不见:按 F5 刷新,或 Ctrl+- 缩小页面;还是不行就关掉旧标签页,用新网址再开。" -ForegroundColor Yellow
Write-Host "  这个窗口要一直开着,关掉它 dsh 就停了。想关整套:再双击一次 lab.cmd。" -ForegroundColor Yellow
Write-Host ""
& ssh @sshKey -t -L 3080:127.0.0.1:3080 $sshTarget $remote
Write-Host ""
Write-Host "dsh 已经退出(ssh 连接断了)。" -ForegroundColor Yellow
Write-Host "要重新进 dsh:双击 dsh.cmd(不用关虚拟机)。要关整套:双击 lab.cmd。出了问题想自检:双击 check-lab.cmd。" -ForegroundColor Yellow
Write-Host "不是你主动退出的?双击 diagnose.cmd,把生成的那句话发给你的 AI 助手,它会带着诊断信息帮你修。" -ForegroundColor Yellow

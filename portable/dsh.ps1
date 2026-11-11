# Re-enter dsh only (VM and proxies already running).
. "$PSScriptRoot\lib.ps1"
. "$PSScriptRoot\remote-cmd.ps1"
Write-Host ""
if ($hasKey) { Write-Host "已启用密钥登录,不用输密码。" -ForegroundColor Green } else { Write-Host "盲输虚拟机 $vmUser 用户的密码(屏幕不显示字是正常的),回车。" -ForegroundColor Green }
Write-Host "出现 'dsh web: http://127.0.0.1:3080/?token=...' 后,复制整行网址,在浏览器【新标签页】打开。" -ForegroundColor Green
Write-Host "如果出现 'Ok to proceed? (y)',敲 y 回车。这个窗口要一直开着。" -ForegroundColor Green
Write-Host "如果提示 Connection closed:虚拟机刚重启过,等 30 秒再双击一次 dsh.cmd。" -ForegroundColor Yellow
Write-Host ""
& ssh @sshKey -t -L 3080:127.0.0.1:3080 $sshTarget $remote
Write-Host ""
Write-Host "dsh 已退出。再双击 dsh.cmd 重新进入,或双击 lab.cmd 关闭整套。" -ForegroundColor Yellow
Write-Host "不是你主动退出的?双击 diagnose.cmd,把生成的那句话发给你的 AI 助手。" -ForegroundColor Yellow

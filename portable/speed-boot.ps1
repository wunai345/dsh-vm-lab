# One-time: stop the VM waiting ~2 minutes at every boot for the NAT cable that stays unplugged on purpose.
. "$PSScriptRoot\lib.ps1"
Write-Host ""
Write-Host "这一步会问一次 sudo 密码(虚拟机 $vmUser 用户的密码,盲输回车)。" -ForegroundColor Green
$cmd = 'sudo systemctl disable systemd-networkd-wait-online.service; sudo systemctl mask systemd-networkd-wait-online.service; systemctl is-enabled systemd-networkd-wait-online.service; echo DONE'
& ssh @sshKey -t $sshTarget $cmd
Write-Host ""
Write-Host "看到 masked 和 DONE 就成功了。下次开机会快很多。" -ForegroundColor Yellow

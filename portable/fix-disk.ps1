# One-time fix if npm fails with ENOSPC: the Ubuntu installer only gives the root volume about half of the virtual disk.
. "$PSScriptRoot\lib.ps1"
Write-Host ""
Write-Host "这一步会问 sudo 密码(虚拟机 $vmUser 用户的密码,盲输回车)。过程:显示磁盘 -> 扩容 -> 清理残留缓存 -> 再显示磁盘。" -ForegroundColor Green
$cmd = 'df -h /; echo ---; sudo vgs; sudo lvs; echo ---; sudo lvextend -r -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv; echo ---; npm cache clean --force; rm -rf ~/.npm/_npx ~/.npm/_logs ~/dsh-app; sudo apt-get clean; df -h /'
& ssh @sshKey -t $sshTarget $cmd
Write-Host ""
Write-Host "把前后两次 df 里 Avail 那一列和任何红字反馈即可。" -ForegroundColor Yellow

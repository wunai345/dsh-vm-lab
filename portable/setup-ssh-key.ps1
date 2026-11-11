# One-time: create a dedicated ssh key for the VM and install it, so the VM password is not needed any more.
. "$PSScriptRoot\lib.ps1"
$key = if ($sshKeyFile) { $sshKeyFile } else { "$env:USERPROFILE\.ssh\$vmName" }
New-Item -ItemType Directory -Force (Split-Path $key) | Out-Null
if (-not (Test-Path $key)) { & ssh-keygen -t ed25519 -f $key -N '""' -q }
Write-Host ""
Write-Host "下面会问一次虚拟机 $vmUser 用户的密码(盲输,回车)。这是最后一次。" -ForegroundColor Green
Write-Host ""
$pub = Get-Content "$key.pub" -Raw
$pub | & ssh $sshTarget 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && echo KEY-INSTALLED'
Write-Host ""
Write-Host "看到 KEY-INSTALLED 就成功了。没看到就把这个窗口截图反馈。" -ForegroundColor Yellow

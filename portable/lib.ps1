# Shared by every script in this folder. Loads config.json (written by setup.ps1) and defines the helpers.
$dir = $PSScriptRoot
$cfgPath = Join-Path $dir 'config.json'
if (-not (Test-Path $cfgPath)) {
    Write-Host "还没有 config.json。请先双击 setup.cmd 做一次环境检测。" -ForegroundColor Red
    throw "config.json missing"
}
$cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
$vb         = $cfg.vboxmanage
$vmName     = $cfg.vm_name
$vmUser     = $cfg.vm_user
$vmIp       = $cfg.vm_ip
$hostIp     = $cfg.host_ip
$keyPort    = [int]$cfg.key_port
$webPort    = [int]$cfg.web_port
$mode       = $cfg.mode                      # 'vpn' (upstream proxy, egress IP checked) or 'direct' (real IP)
$sshKeyFile = $cfg.ssh_key

function Listening($port, $addr = $hostIp) {
    # TCP connect test: Get-NetTCPConnection -State Listen is unreliable on the host-only adapter (blank state)
    $c = New-Object Net.Sockets.TcpClient
    try { $a = $c.BeginConnect($addr, $port, $null, $null); return ($a.AsyncWaitHandle.WaitOne(1500) -and $c.Connected) } catch { return $false } finally { $c.Close() }
}
function SshUp {
    # ready = sshd answers with its banner (an open port alone is not enough: sshd can lag by minutes)
    $c = New-Object Net.Sockets.TcpClient
    try {
        $a = $c.BeginConnect($vmIp, 22, $null, $null)
        if (-not ($a.AsyncWaitHandle.WaitOne(2000) -and $c.Connected)) { return $false }
        $s = $c.GetStream(); $s.ReadTimeout = 4000; $b = New-Object byte[] 16
        $n = $s.Read($b, 0, 16)
        return ($n -gt 0 -and [Text.Encoding]::ASCII.GetString($b, 0, $n).StartsWith('SSH-'))
    } catch { return $false } finally { $c.Close() }
}
function VmState { (& $vb showvminfo $vmName --machinereadable | Select-String '^VMState="(.*)"').Matches.Groups[1].Value }
function Start-Proxy($script, $title) {
    # starts the .py through its own .cmd so a window stays open with the output
    $cmd = Join-Path $dir "keyproxy\$script"
    Start-Process -FilePath $cmd -WorkingDirectory (Join-Path $dir 'keyproxy') -WindowStyle Normal
}
$sshKey = if ($sshKeyFile -and (Test-Path $sshKeyFile)) { @('-i', $sshKeyFile, '-o', 'IdentitiesOnly=yes') } else { @() }
$hasKey = [bool]($sshKey.Count)
$sshTarget = "$vmUser@$vmIp"

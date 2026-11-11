# Collects a diagnosis file (diagnose.txt) for the user's AI assistant, with personal data masked.
# Works with or without config.json. Never includes passwords or API keys.
# Usage: diagnose.ps1 [-Reason "what went wrong"] [-Quiet]
param([string]$Reason = '', [switch]$Quiet)
$ErrorActionPreference = 'Continue'
$dir = $PSScriptRoot
$out = Join-Path $dir 'diagnose.txt'
$cfg = $null
$cfgPath = Join-Path $dir 'config.json'
if (Test-Path $cfgPath) { try { $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
$keepIps = @('127.0.0.1')
if ($cfg) { $keepIps += @($cfg.host_ip, $cfg.vm_ip, ([string]$cfg.subnet -replace '/.*', '')) }

function Mask($text) {
    if ($null -eq $text) { return '' }
    $t = [string]$text
    foreach ($n in @($env:USERNAME, $env:COMPUTERNAME)) { if ($n) { $t = $t -ireplace [regex]::Escape($n), '<name>' } }
    $t = [regex]::Replace($t, 'sk-[A-Za-z0-9_\-]{8,}', 'sk-<hidden>')
    $t = [regex]::Replace($t, '\b(\d{1,3}\.){3}\d{1,3}\b', { param($m) if ($keepIps -contains $m.Value) { $m.Value } else { 'x.x.x.x' } })
    return $t
}
$lines = New-Object System.Collections.Generic.List[string]
function Add($t = '') { $script:lines.Add((Mask $t)) }
function Section($t) { Add ''; Add "=== $t ===" }
function Probe($port, $addr) {
    $c = New-Object Net.Sockets.TcpClient
    try { $a = $c.BeginConnect($addr, $port, $null, $null); return ($a.AsyncWaitHandle.WaitOne(1500) -and $c.Connected) } catch { return $false } finally { $c.Close() }
}

Add "dsh-vm-lab diagnosis  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Add "Reason: $Reason"
Add "(IP addresses other than the VM's internal ones, the user name and computer name are masked; no keys or passwords are collected.)"

Section 'System'
$os = Get-CimInstance Win32_OperatingSystem
Add "Windows: $($os.Caption) $($os.Version)"
Add "Hyper-V / virtualization security present: $((Get-CimInstance Win32_ComputerSystem).HypervisorPresent)"
Add "PowerShell: $($PSVersionTable.PSVersion)"
$vbPath = if ($cfg -and $cfg.vboxmanage) { $cfg.vboxmanage } else { "$env:ProgramFiles\Oracle\VirtualBox\VBoxManage.exe" }
if (Test-Path $vbPath) { Add "VirtualBox: $(& $vbPath --version)" } else { Add 'VirtualBox: NOT FOUND' }
if (Get-Command py -ErrorAction SilentlyContinue) { Add "Python: $(& py -I -c 'import sys; print(sys.version.split()[0])' 2>&1)" } elseif (Get-Command python -ErrorAction SilentlyContinue) { Add "Python: $(& python -I -c 'import sys; print(sys.version.split()[0])' 2>&1)" } else { Add 'Python: NOT FOUND' }
Add "ssh: $(if (Get-Command ssh -ErrorAction SilentlyContinue) { 'found' } else { 'NOT FOUND' })"
$free = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -ne $null -and $_.Name.Length -eq 1 } | ForEach-Object { "{0}: {1:N0} GB free" -f $_.Name, ($_.Free / 1GB) }
Add "Disks: $($free -join '; ')"

Section 'Configuration (config.json)'
if ($cfg) {
    foreach ($p in $cfg.PSObject.Properties) { if ($p.Name -notin 'ssh_key') { Add ("{0} = {1}" -f $p.Name, $p.Value) } }
    Add "ssh key file exists: $([bool]($cfg.ssh_key -and (Test-Path $cfg.ssh_key)))"
} else { Add 'config.json not found: setup.cmd has not been completed.' }

Section 'Windows port reservations'
Add ((netsh int ipv4 show dynamicport tcp) -join ' | ')
Add ((netsh interface ipv4 show excludedportrange protocol=tcp | Select-String '^\s+\d+\s+\d+' | ForEach-Object { $_.Line.Trim() -replace '\s+', '-' }) -join ', ')

if ($cfg -and (Test-Path $vbPath)) {
    $vb = $vbPath; $vm = $cfg.vm_name
    Section 'Virtual machine'
    $info = & $vb showvminfo $vm --machinereadable 2>&1
    if ($LASTEXITCODE -ne 0) { Add "VM '$vm' not found or not readable: $($info | Select-Object -First 3)" }
    else {
        foreach ($k in 'VMState', 'cpus', 'memory', 'paravirtprovider', 'boot1', 'boot2', 'nic1', 'nic2', 'cableconnected1', 'cableconnected2', 'hostonlyadapter2', 'usb') {
            $m = $info | Select-String ("^$k=") | Select-Object -First 1
            if ($m) { Add $m.Line }
        }
    }
    Section 'Reachability'
    Add "key proxy $($cfg.key_port): $(if (Probe $cfg.key_port $cfg.host_ip) { 'up' } else { 'down' })"
    Add "web proxy $($cfg.web_port): $(if (Probe $cfg.web_port $cfg.host_ip) { 'up' } else { 'down' })"
    Add "dsh tunnel 3080: $(if (Probe 3080 '127.0.0.1') { 'up' } else { 'down' })"
    $banner = ''
    $c = New-Object Net.Sockets.TcpClient
    try {
        $a = $c.BeginConnect($cfg.vm_ip, 22, $null, $null)
        if ($a.AsyncWaitHandle.WaitOne(2000) -and $c.Connected) {
            $s = $c.GetStream(); $s.ReadTimeout = 4000; $b = New-Object byte[] 40
            try { $n = $s.Read($b, 0, 40); $banner = [Text.Encoding]::ASCII.GetString($b, 0, $n).Trim() } catch { $banner = '(port open, but sshd gave no banner: still booting or hung)' }
        } else { $banner = '(port 22 not reachable)' }
    } catch { $banner = "(error: $($_.Exception.Message))" } finally { $c.Close() }
    Add "ssh banner: $banner"

    if ($banner -like 'SSH-*' -and $cfg.ssh_key -and (Test-Path $cfg.ssh_key)) {
        Section 'Inside the VM (key login, read-only commands)'
        $r = & ssh -i $cfg.ssh_key -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=15 "$($cfg.vm_user)@$($cfg.vm_ip)" 'df -h / | tail -1; uptime; free -m | head -2; systemctl --failed --no-pager --no-legend | head -5; grep -c PROXY ~/.bashrc; ls ~/dsh-app/node_modules/.bin/dsh 2>&1; node -v 2>&1' 2>&1
        foreach ($l in $r) { Add "$l" }
    }
}

Section 'Proxy logs (only problems: refusals, errors, egress changes, startup lines)'
foreach ($name in 'webproxy.log', 'keyproxy.log') {
    $lp = Join-Path $dir "keyproxy\$name"
    if (Test-Path $lp) {
        Add "--- $name ---"
        $sel = Get-Content $lp -Tail 400 | Where-Object { $_ -match 'listening|EGRESS|egress|Traceback|Error|error|-> (403|50\d)|refused' } | Select-Object -Last 15
        foreach ($l in $sel) { Add $l }
        if (-not $sel) { Add '(nothing unusual in the last 400 lines)' }
    }
}

[IO.File]::WriteAllLines($out, $lines, (New-Object Text.UTF8Encoding $true))
if (-not $Quiet) {
    Write-Host ""
    Write-Host "已生成诊断文件(已把 IP、用户名等打码,不含 Key 和密码):" -ForegroundColor Green
    Write-Host "  $out" -ForegroundColor White
    Write-Host ""
    Write-Host "把下面这句话发给你的 AI 助手,它会带着这些信息帮你排查:" -ForegroundColor Cyan
    Write-Host "  请读取 $out ,按 dsh-vm-lab 技能帮我排查并修复。改动之前先问我,不要让我输入或发送密码和 API Key。" -ForegroundColor Yellow
}

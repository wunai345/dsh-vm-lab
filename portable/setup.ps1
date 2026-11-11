# First-run setup: detects this PC (VirtualBox, Python, ssh, host-only network, free ports, VPN/proxy),
# asks where to install, writes config.json and the .cmd launchers into the install folder.
# Parameters are for testing / unattended use:  -InstallDir X  -Mode auto|vpn|direct  -VmName n  -NoPrompt  -NoDeploy
param(
    [string]$InstallDir = '',
    [ValidateSet('auto', 'vpn', 'direct')][string]$Mode = 'auto',
    [string]$VmName = 'dsh-lab',
    [string]$VmUser = 'lab',
    [switch]$NoPrompt,
    [switch]$NoDeploy
)
$ErrorActionPreference = 'Stop'
function Say($t, $c = 'White') { Write-Host $t -ForegroundColor $c }
function Ok($t) { Say "  [OK]   $t" Green }
function Warn($t) { Say "  [注意] $t" Yellow }
function Fail($t, $fix) { Say "  [缺少] $t" Red; Say "         -> $fix" Yellow; $script:problems += $t }
$script:problems = @()

Say ""
Say "dsh 隔离实验室:环境检测" Cyan

# ---------- 1. tools ----------
Say "`n[1/6] 检查必需软件" Cyan
$vbCandidates = @(
    "$env:ProgramFiles\Oracle\VirtualBox\VBoxManage.exe",
    "${env:ProgramFiles(x86)}\Oracle\VirtualBox\VBoxManage.exe"
)
$vboxKey = Get-ItemProperty 'HKLM:\SOFTWARE\Oracle\VirtualBox' -ErrorAction SilentlyContinue
if ($vboxKey -and $vboxKey.InstallDir) { $vbCandidates = @((Join-Path $vboxKey.InstallDir 'VBoxManage.exe')) + $vbCandidates }
$vb = $vbCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if ($vb) { Ok ("VirtualBox " + (& $vb --version)) } else { Fail "VirtualBox" "到 https://www.virtualbox.org/ 下载安装(要图形界面点安装),装好后重新运行 setup.cmd。" }

$python = $null
if (Get-Command py -ErrorAction SilentlyContinue) { $python = 'py' }
elseif (Get-Command python -ErrorAction SilentlyContinue) { $python = (Get-Command python).Source }
if ($python) {
    $pv = (& $python -I -c "import sys; print(sys.version.split()[0])") 2>$null
    if ($pv) { Ok "Python $pv(命令:$python)" } else { Fail "Python 不能运行" "重新安装 Python 3.8 以上,安装时勾选 Add to PATH。"; $python = $null }
} else { Fail "Python" "到 https://www.python.org/ 安装 Python 3.8 以上,安装时勾选 Add to PATH。" }

if ((Get-Command ssh -ErrorAction SilentlyContinue) -and (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) { Ok "OpenSSH 客户端" }
else { Fail "OpenSSH 客户端" "Windows 设置 -> 系统 -> 可选功能 -> 添加功能 -> OpenSSH 客户端。" }

$hv = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent
if ($hv) { Warn "这台电脑开着 Hyper-V/虚拟化安全。虚拟机建议 1 个 CPU、半虚拟化选 kvm,否则开机容易卡死(详见技能说明)。" }

# ---------- 2. install folder ----------
Say "`n[2/6] 安装位置" Cyan
if (-not $InstallDir) {
    $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -gt 0 -and $_.Name.Length -eq 1 } | Sort-Object Free -Descending
    $best = $drives | Select-Object -First 1
    foreach ($d in $drives) { Say ("  {0}: 盘剩余 {1:N0} GB" -f $d.Name, ($d.Free / 1GB)) }
    $default = if ($best) { "$($best.Name):\VMLab" } else { "$env:USERPROFILE\VMLab" }
    if ($NoPrompt) { $InstallDir = $default }
    else {
        Say "  虚拟机、系统镜像和日志都放在一个文件夹里,删掉它就等于清理干净。至少留 30 GB。"
        $ans = Read-Host "  安装到哪里?直接回车使用 $default"
        $InstallDir = if ($ans.Trim()) { $ans.Trim() } else { $default }
    }
}
$root = [IO.Path]::GetPathRoot($InstallDir)
$free = (New-Object IO.DriveInfo($root)).AvailableFreeSpace / 1GB
if ($free -lt 30) { Warn ("{0} 只剩 {1:N0} GB,建议换一个至少 30 GB 的位置。" -f $root, $free) } else { Ok ("{0}(剩余 {1:N0} GB)" -f $InstallDir, $free) }

# ---------- 3. host-only network ----------
Say "`n[3/6] 虚拟机的内部网络(仅主机网卡)" Cyan
$hostIp = $null; $mask = '255.255.255.0'
if ($vb) {
    $adapterName = $null
    $vmInfo = & $vb showvminfo $VmName --machinereadable 2>$null
    if ($vmInfo) { $adapterName = ($vmInfo | Select-String '^hostonlyadapter\d="(.*)"' | Select-Object -First 1).Matches.Groups[1].Value }
    $blocks = (& $vb list hostonlyifs) -join "`n" -split "(?m)^\s*$" | Where-Object { $_ -match 'IPAddress' }
    $pick = $null
    foreach ($b in $blocks) {
        $n = if ($b -match '(?m)^Name:\s+(.*)$') { $Matches[1].Trim() } else { '' }
        if ($adapterName -and $n -eq $adapterName) { $pick = $b; break }
        if (-not $pick) { $pick = $b }
    }
    if ($pick) {
        if ($pick -match '(?m)^IPAddress:\s+(\S+)') { $hostIp = $Matches[1] }
        if ($pick -match '(?m)^NetworkMask:\s+(\S+)') { $mask = $Matches[1] }
    }
}
if ($hostIp) {
    Ok "仅主机网卡地址 $hostIp(掩码 $mask)"
} else {
    $hostIp = '192.168.56.1'
    Warn "没读到 VirtualBox 的仅主机网卡,先按默认 $hostIp 配置。创建虚拟机时在网络里加一块『仅主机(Host-Only)网络』,然后重新运行 setup.cmd。"
}
$ipBytes = ([Net.IPAddress]::Parse($hostIp)).GetAddressBytes(); $mBytes = ([Net.IPAddress]::Parse($mask)).GetAddressBytes()
$netBytes = 0..3 | ForEach-Object { $ipBytes[$_] -band $mBytes[$_] }
$prefix = 0; foreach ($b in $mBytes) { $x = $b; while ($x) { $prefix += $x -band 1; $x = $x -shr 1 } }
$subnet = ($netBytes -join '.') + "/$prefix"
$vmBytes = $netBytes.Clone(); $vmBytes[3] = if ($ipBytes[3] -eq ($netBytes[3] + 10)) { $netBytes[3] + 11 } else { $netBytes[3] + 10 }
$vmIp = $vmBytes -join '.'
Ok "虚拟机内部网段 $subnet,虚拟机固定地址 $vmIp"
$lan = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -ne $hostIp -and $_.IPAddress -like ($netBytes[0..2] -join '.') + '.*' }
if ($lan) { Warn "你的局域网网段和虚拟机内部网段撞了($($lan.IPAddress -join ', ')):请在 VirtualBox 里把仅主机网络改成别的网段,再重新运行 setup.cmd。" }

# ---------- 4. ports ----------
Say "`n[4/6] 选代理端口(避开 Windows 的保留端口)" Cyan
function Get-Ranges {
    $ex = netsh interface ipv4 show excludedportrange protocol=tcp | Select-String '^\s+\d+\s+\d+' | ForEach-Object { $p = ($_.Line.Trim() -split '\s+'); [pscustomobject]@{ S = [int]$p[0]; E = [int]$p[1] } }
    $dyn = $null
    $o = netsh int ipv4 show dynamicport tcp
    $s = ($o | Select-String 'Start Port\s*:\s*(\d+)'); $n = ($o | Select-String 'Number of Ports\s*:\s*(\d+)')
    if ($s -and $n) { $a = [int]$s.Matches[0].Groups[1].Value; $dyn = [pscustomobject]@{ S = $a; E = $a + [int]$n.Matches[0].Groups[1].Value - 1 } }
    [pscustomobject]@{ Excluded = @($ex); Dynamic = $dyn }
}
function Test-Bindable($ip, $port) {
    try { $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Parse($ip), $port); $l.Start(); $l.Stop(); return $true } catch { return $false }
}
$ranges = Get-Ranges
if ($ranges.Dynamic) { Say ("  系统动态端口范围:{0}-{1};保留区间 {2} 段(每次开机可能变)" -f $ranges.Dynamic.S, $ranges.Dynamic.E, $ranges.Excluded.Count) }
$bindIp = if (Get-NetIPAddress -IPAddress $hostIp -ErrorAction SilentlyContinue) { $hostIp } else { '127.0.0.1' }
if ($bindIp -ne $hostIp) { Warn "仅主机网卡的地址 $hostIp 这台电脑上还不存在,端口先在 127.0.0.1 上试占用;创建好虚拟机网卡后建议重新运行 setup.cmd。" }
function Pick-Port($prefer, $skip) {
    foreach ($p in $prefer..($prefer + 300)) {
        if ($skip -contains $p) { continue }
        if ($ranges.Excluded | Where-Object { $p -ge $_.S -and $p -le $_.E }) { continue }
        if ($ranges.Dynamic -and $p -ge $ranges.Dynamic.S -and $p -le $ranges.Dynamic.E) { continue }
        if (Test-Bindable $bindIp $p) { return $p }
    }
    throw "找不到可用端口"
}
$webPort = Pick-Port 18128 @()
$keyPort = Pick-Port 18787 @($webPort)
Ok "网页代理端口 $webPort,Key 代理端口 $keyPort(都在系统动态范围之外,不会被保留)"

# ---------- 5. internet path ----------
Say "`n[5/6] 上网方式(VPN / 真实 IP)" Cyan
$upstream = ''
$cand = @()
$reg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
if ($reg -and $reg.ProxyEnable -eq 1 -and $reg.ProxyServer) {
    $ps = $reg.ProxyServer
    if ($ps -match 'https=([^;]+)') { $cand += $Matches[1] } elseif ($ps -match 'http=([^;]+)') { $cand += $Matches[1] } else { $cand += ($ps -split ';')[0] }
}
foreach ($v in 'HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy') { $e = [Environment]::GetEnvironmentVariable($v); if ($e) { $cand += $e } }
$cand = $cand | ForEach-Object { ($_ -replace '^\w+://', '').TrimEnd('/') } | Where-Object { $_ -match '^[\w\.\-]+:\d+$' } | Select-Object -Unique
$egress = $null
if ($Mode -ne 'direct') {
    foreach ($c in $cand) {
        try {
            $r = Invoke-WebRequest 'https://api.ipify.org' -Proxy "http://$c" -UseBasicParsing -TimeoutSec 12
            $upstream = $c; $egress = $r.Content.Trim(); break
        } catch { Warn "检测到代理 $c,但试着通过它上网失败:$($_.Exception.Message)" }
    }
}
$direct = $false
try {
    $req = [Net.HttpWebRequest]::Create('https://registry.npmjs.org/-/ping'); $req.Proxy = $null; $req.Timeout = 8000
    $req.GetResponse().Close(); $direct = $true
} catch {}
if ($Mode -eq 'vpn' -and -not $upstream) { Fail "没找到可用的 VPN/系统代理" "先打开你的 VPN 软件并开启『系统代理』,再重新运行 setup.cmd。" }
if ($upstream) {
    $mode = 'vpn'
    Ok "检测到可用的代理 $upstream,通过它看到的出口 IP 是 $egress"
    Say "  第一次启动网页代理时会问『这是不是 VPN 的 IP(不是家里宽带 IP)』,请对照确认。" Gray
} else {
    $mode = 'direct'
    Warn "没有检测到 VPN/代理,将使用【真实 IP 模式】:虚拟机访问的网站会看到你的真实 IP。"
    Say "  Key 不进虚拟机、虚拟机碰不到局域网和本机服务这两层保护仍然有效。第一次启动网页代理时需要你输入 I UNDERSTAND 确认。" Gray
    if (-not $direct) { Warn "而且这台电脑直连国外网站失败(npm 官方仓库连不上),虚拟机里下载 dsh 会失败。需要先开 VPN/代理再重新运行 setup.cmd,或者换一个能直连的网络。" }
    else { Ok "直连 npm 官方仓库正常,真实 IP 模式下载依赖可行。" }
}

# ---------- 6. write config + deploy ----------
Say "`n[6/6] 写入配置" Cyan
if ($script:problems.Count) {
    Say ""
    Say "还有 $($script:problems.Count) 项必需的东西没准备好(见上面红色 [缺少]),先解决再重新运行 setup.cmd。没有写入任何配置。" Red
    & (Join-Path $PSScriptRoot 'diagnose.ps1') -Reason ("setup: missing " + ($script:problems -join ", "))
    exit 1
}
$cfgObj = [ordered]@{
    vboxmanage = $vb; python = $python; install_dir = $InstallDir
    vm_name = $VmName; vm_user = $VmUser; vm_ip = $vmIp; host_ip = $hostIp; subnet = $subnet
    key_port = $keyPort; web_port = $webPort; mode = $mode; upstream = $upstream
    ssh_key = (Join-Path $env:USERPROFILE ".ssh\$VmName")
}
$json = $cfgObj | ConvertTo-Json
$src = $PSScriptRoot
if (-not $NoDeploy) {
    New-Item -ItemType Directory -Force (Join-Path $InstallDir 'keyproxy') | Out-Null
    if ((Resolve-Path $src).Path -ne (Resolve-Path $InstallDir).Path) {
        Get-ChildItem $src -Filter *.ps1 | Copy-Item -Destination $InstallDir -Force
        Get-ChildItem (Join-Path $src 'keyproxy') -Filter *.py | Copy-Item -Destination (Join-Path $InstallDir 'keyproxy') -Force
    }
    [IO.File]::WriteAllText((Join-Path $InstallDir 'config.json'), $json, (New-Object Text.UTF8Encoding $false))
    $ascii = New-Object Text.ASCIIEncoding
    foreach ($n in 'lab', 'start-lab', 'stop-lab', 'dsh', 'check-lab', 'diagnose', 'setup-ssh-key', 'fix-disk', 'speed-boot', 'setup') {
        [IO.File]::WriteAllText((Join-Path $InstallDir "$n.cmd"), "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0$n.ps1`"`r`npause`r`n", $ascii)
    }
    $pyCmd = if ($python -eq 'py') { 'py' } else { "`"$python`"" }
    foreach ($pair in @(@('start-proxy', 'keyproxy'), @('start-webproxy', 'webproxy'))) {
        [IO.File]::WriteAllText((Join-Path $InstallDir "keyproxy\$($pair[0]).cmd"), "@echo off`r`n$pyCmd -I `"%~dp0$($pair[1]).py`"`r`npause`r`n", $ascii)
    }
    # net-off / net-on need the VM name and VBoxManage path
    [IO.File]::WriteAllText((Join-Path $InstallDir 'net-off.cmd'), "@echo off`r`n`"$vb`" controlvm $VmName setlinkstate1 off`r`n`"$vb`" controlvm $VmName setlinkstate2 off`r`necho VM network cut.`r`npause`r`n", $ascii)
    [IO.File]::WriteAllText((Join-Path $InstallDir 'net-on.cmd'), "@echo off`r`n`"$vb`" controlvm $VmName setlinkstate2 on`r`necho Host-only link restored (NAT stays unplugged on purpose).`r`npause`r`n", $ascii)
    $settings = @"
VM-side settings that must match config.json (set them once when you build the VM):

1) Static address for the host-only NIC (Ubuntu netplan, interface name usually enp0s8):
     addresses: [$vmIp/$prefix]     (no gateway, no DNS)

2) Append to ~/.bashrc in the VM:
     export HTTP_PROXY=http://${hostIp}:$webPort HTTPS_PROXY=http://${hostIp}:$webPort http_proxy=http://${hostIp}:$webPort https_proxy=http://${hostIp}:$webPort
     export NO_PROXY=localhost,127.0.0.1,$hostIp no_proxy=localhost,127.0.0.1,$hostIp NODE_USE_ENV_PROXY=1

3) In dsh settings (Model): API key  lab-dummy-key
                            API URL  http://${hostIp}:$keyPort/anthropic
"@
    [IO.File]::WriteAllText((Join-Path $InstallDir 'vm-settings.txt'), $settings, (New-Object Text.UTF8Encoding $false))
    Ok "已写入 $InstallDir(config.json、启动脚本、vm-settings.txt)"
} else {
    Say $json Gray
    Ok "(测试模式:没有写文件)"
}
Say ""
Say "检测完成。要点:" Cyan
Say "  上网方式 : $mode" $(if ($mode -eq 'direct') { 'Yellow' } else { 'Green' })
Say "  代理端口 : 网页 $webPort / Key $keyPort,绑定在 $hostIp"
Say "  下一步   : 按技能里的『搭建虚拟机』步骤建好虚拟机,再把 vm-settings.txt 里的设置填进去,然后双击 lab.cmd。"

<#
.SYNOPSIS
    campus-net-autologin (Windows) —— 校园网掉线自动重连（Dr.COM / 锐捷 eportal）

.DESCRIPTION
    对应 macOS 版的 scripts/portal-login.sh：探活 → 判定 → 自动重新认证 → 写日志。

    用法：
        .\campus-net-autologin.ps1              正常运行（计划任务调它）
        .\campus-net-autologin.ps1 -Diagnose    环境诊断，用来填配置（先跑这个）
        .\campus-net-autologin.ps1 -Force       即使在线也发一次认证请求（验证请求格式）
        .\campus-net-autologin.ps1 -Rotate      立即按保留天数轮转日志

.NOTES
    判定规则与 macOS 版完全一致：
        2xx / 404                → 在线
        3xx 且 Location 是 http→https 同 host 升级 → 在线
        其它 3xx（含认证页重定向）→ 被踢
        裸 3xx（无 Location）    → 被踢
        都不通                   → 链路层问题
#>
[CmdletBinding()]
param(
    [switch]$Diagnose,
    [switch]$Force,
    [switch]$Rotate,
    [string]$Config = ""
)

$ErrorActionPreference = 'Continue'

# ────────────────────────────────────────────────────────────────
#  配置默认值（会被 config.ps1 覆盖）
# ────────────────────────────────────────────────────────────────
$AppDir = Join-Path $env:LOCALAPPDATA 'campus-net'
if (-not $Config) { $Config = Join-Path $AppDir 'config.ps1' }

$CampusUser   = ''                              # 学号，可能带运营商后缀，如 2025001@cmcc
$CampusPass   = ''                              # 密码
$PortalHost   = ''                              # 登录页 IP，如 10.x.x.x
$EportalBase  = ''                              # 留空则用 http://<PortalHost>:801/eportal
$EportalMac   = '000000000000'                  # eportal 标准做法是全 0
$IfIndex      = 0                               # 0 = 自动挑网卡
$IfAlias      = ''                              # 也可按适配器名匹配，如 '以太网'
$RetainDays   = 90                              # 日志保留天数
$HeartbeatSec = 1800                            # 状态没变时最多多久写一条心跳
$Probes       = @('http://223.5.5.5/', 'http://1.1.1.1/')   # IP 直连探针，绕开 DNS
$LogDir       = Join-Path $AppDir 'logs'
$StateDir     = Join-Path $AppDir 'state'

$ConfigExists = Test-Path $Config
if ($ConfigExists) { . $Config }

$LiveLog  = Join-Path $LogDir 'monitor.log'
$StateKey = Join-Path $StateDir 'state.txt'
$StateTime = Join-Path $StateDir 'state.epoch'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$script:HasCurl = [bool](Get-Command curl.exe -ErrorAction SilentlyContinue)

# ────────────────────────────────────────────────────────────────
#  基础工具
# ────────────────────────────────────────────────────────────────
function Write-CnLog {
    param([string]$Message)
    try {
        if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
        $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        [System.IO.File]::AppendAllText($LiveLog, $line + [Environment]::NewLine, $Utf8NoBom)
    } catch { }
}

function Write-StateFiles {
    param([string]$Key)
    try {
        if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
        [System.IO.File]::WriteAllText($StateKey, $Key, $Utf8NoBom)
        [System.IO.File]::WriteAllText($StateTime, ([string](Get-Date -UFormat %s)), $Utf8NoBom)
    } catch { }
}

function Read-StateKey {
    try {
        if (Test-Path $StateKey) { return ([System.IO.File]::ReadAllText($StateKey, $Utf8NoBom)).Trim() }
    } catch { }
    return ''
}

function Read-StateEpoch {
    try {
        if (Test-Path $StateTime) { return [int64]([System.IO.File]::ReadAllText($StateTime, $Utf8NoBom)).Trim() }
    } catch { }
    return 0
}

# ────────────────────────────────────────────────────────────────
#  网卡选择
# ────────────────────────────────────────────────────────────────
$script:ExcludePattern = 'Loopback|Virtual|Hyper-V|WSL|VPN|TAP|TUN|Bluetooth|VMware|VirtualBox|Tailscale|ZeroTier|Npcap|Docker|WAN Miniport'

function Select-CampusAdapter {
    $all = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object {
        $_.NetAdapter.Status -eq 'Up' -and
        $_.InterfaceAlias -notmatch $script:ExcludePattern -and
        $_.InterfaceDescription -notmatch $script:ExcludePattern
    })
    if ($all.Count -eq 0) { return $null }

    # 显式指定优先
    if ($IfIndex -gt 0) {
        $m = @($all | Where-Object { $_.InterfaceIndex -eq $IfIndex })
        if ($m.Count -gt 0) { return $m[0] }
    }
    if ($IfAlias) {
        $m = @($all | Where-Object { $_.InterfaceAlias -like "*$IfAlias*" })
        if ($m.Count -gt 0) { return $m[0] }
    }

    # 优先"有 IP 且有默认网关"的，其次只要有 IP
    $pref = @($all | Where-Object { $_.IPv4Address -and $_.IPv4DefaultGateway })
    if ($pref.Count -gt 0) { return $pref[0] }
    $ipOnly = @($all | Where-Object { $_.IPv4Address })
    if ($ipOnly.Count -gt 0) { return $ipOnly[0] }
    return $all[0]
}

function Get-CampusInfo {
    $a = Select-CampusAdapter
    if (-not $a) { return $null }
    $ip = ''
    if ($a.IPv4Address) { $ip = ($a.IPv4Address | Select-Object -First 1).IPAddress }
    $gw = ''
    if ($a.IPv4DefaultGateway) { $gw = ($a.IPv4DefaultGateway | Select-Object -First 1).NextHop }
    $mac = ''
    try { $mac = (Get-NetAdapter -InterfaceIndex $a.InterfaceIndex -ErrorAction Stop).MacAddress } catch { }
    return [pscustomobject]@{
        Index = $a.InterfaceIndex
        Alias = $a.InterfaceAlias
        Desc  = $a.InterfaceDescription
        IP    = $ip
        GW    = $gw
        Mac   = $mac
    }
}

# ────────────────────────────────────────────────────────────────
#  探针
# ────────────────────────────────────────────────────────────────
function Invoke-ProbeCurl {
    param([string]$Url, [string]$LocalIp)
    $a = @('--noproxy', '*', '-s', '-m', '6', '-o', 'NUL', '-w', '%{http_code}|%{redirect_url}')
    if ($LocalIp) { $a += @('--interface', $LocalIp) }
    $a += $Url
    $raw = (& curl.exe @a 2>$null | Out-String).Trim()
    $parts = $raw -split '\|', 2
    $code = 0
    [void][int]::TryParse($parts[0], [ref]$code)
    $loc = ''
    if ($parts.Count -gt 1) { $loc = $parts[1] }
    return [pscustomobject]@{ Code = $code; Location = $loc }
}

function Invoke-ProbeDotNet {
    param([string]$Url)
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = 'GET'
        $req.AllowAutoRedirect = $false
        $req.Proxy = $null
        $req.Timeout = 6000
        $req.UserAgent = 'campus-net-autologin'
        try {
            $resp = $req.GetResponse()
            $code = [int]$resp.StatusCode
            $loc = [string]$resp.Headers['Location']
            $resp.Close()
            return [pscustomobject]@{ Code = $code; Location = $loc }
        } catch [System.Net.WebException] {
            $r = $_.Exception.Response
            if ($r) {
                $code = [int]$r.StatusCode
                $loc = [string]$r.Headers['Location']
                $r.Close()
                return [pscustomobject]@{ Code = $code; Location = $loc }
            }
            return [pscustomobject]@{ Code = 0; Location = '' }
        }
    } catch {
        return [pscustomobject]@{ Code = 0; Location = '' }
    }
}

function Invoke-Probe {
    param([string]$Url, [string]$LocalIp)
    if ($script:HasCurl) { return Invoke-ProbeCurl -Url $Url -LocalIp $LocalIp }
    return Invoke-ProbeDotNet -Url $Url
}

function Get-HostOf {
    param([string]$Url)
    try { return ([uri]$Url).Host } catch { return '' }
}

# 返回 [pscustomobject]@{ Online = $bool; Detail = '...' }
function Get-OnlineState {
    param([string]$LocalIp)
    foreach ($u in $Probes) {
        $r = Invoke-Probe -Url $u -LocalIp $LocalIp
        if (-not $r.Code -or $r.Code -eq 0) { continue }

        if (($r.Code -ge 200 -and $r.Code -lt 300) -or $r.Code -eq 404) {
            return [pscustomobject]@{ Online = $true; Detail = [string]$r.Code }
        }
        if ($r.Code -ge 300 -and $r.Code -lt 400) {
            if (-not $r.Location) {
                return [pscustomobject]@{ Online = $false; Detail = "PORTAL:裸$($r.Code)(无Location)" }
            }
            $sameHost = (Get-HostOf $r.Location) -eq (Get-HostOf $u)
            $upgrade = ($r.Location -like 'https://*') -and ($u -like 'http://*')
            if ($sameHost -and $upgrade) {
                return [pscustomobject]@{ Online = $true; Detail = [string]$r.Code }
            }
            return [pscustomobject]@{ Online = $false; Detail = "PORTAL:$($r.Location)" }
        }
    }
    return [pscustomobject]@{ Online = $false; Detail = '000' }
}

# ────────────────────────────────────────────────────────────────
#  eportal 认证
# ────────────────────────────────────────────────────────────────
# 返回 'ok' / 'fail' / 'skip'
function Invoke-EportalLogin {
    param([string]$Ip)

    if (-not $Ip) {
        Write-CnLog 'AUTH  SKIP 接口没有 IP，portal 认证无从下手（与密码无关）'
        return 'skip'
    }
    if (-not $CampusUser) {
        Write-CnLog 'AUTH  SKIP config.ps1 里 CampusUser 是空的'
        return 'skip'
    }
    if (-not $CampusPass) {
        Write-CnLog 'AUTH  SKIP config.ps1 里 CampusPass 是空的，不发送（避免触发失败计数）'
        return 'skip'
    }

    $base = $EportalBase
    if (-not $base) {
        if (-not $PortalHost) {
            Write-CnLog 'AUTH  SKIP 未配置 EportalBase / PortalHost（见 config.example.ps1）'
            return 'skip'
        }
        $base = "http://${PortalHost}:801/eportal"
    }

    $ua = [uri]::EscapeDataString($CampusUser)
    $up = [uri]::EscapeDataString($CampusPass)
    $v  = '{0}.{1}' -f (Get-Random -Minimum 1000 -Maximum 9999), (Get-Random -Minimum 100 -Maximum 999)
    $q  = 'callback=dr1003&login_method=1' +
          '&user_account=' + $ua +
          '&user_password=' + $up +
          '&wlan_user_ip=' + $Ip +
          '&wlan_user_ipv6=' +
          '&wlan_user_mac=' + $EportalMac +
          '&wlan_ac_ip=&wlan_ac_name=' +
          '&jsVersion=4.1.3&terminal_type=1&lang=zh-cn&v=' + $v
    $url = "$base/portal/login?$q"

    $body = ''
    if ($script:HasCurl) {
        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            & curl.exe --noproxy '*' -s -m 10 -o $tmp $url 2>$null | Out-Null
            $body = [System.IO.File]::ReadAllText($tmp, [System.Text.Encoding]::UTF8)
        } catch {
            $body = ''
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    } else {
        try {
            $req = [System.Net.HttpWebRequest]::Create($url)
            $req.Proxy = $null
            $req.Timeout = 10000
            $resp = $req.GetResponse()
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
            $body = $sr.ReadToEnd()
            $sr.Close(); $resp.Close()
        } catch {
            $body = ''
        }
    }

    if ($body.Length -gt 200) { $body = $body.Substring(0, 200) }
    Write-CnLog "AUTH  eportal 响应: $body"

    if ($body -match '"result"\s*:\s*1') { return 'ok' }
    if ($body -match '已经在线')          { return 'ok' }
    return 'fail'
}

# ────────────────────────────────────────────────────────────────
#  日志轮转：跨天 rename + 删过期归档，从不重写文件内容
# ────────────────────────────────────────────────────────────────
function Invoke-LogRotation {
    param([switch]$ForceRotate)

    $today = (Get-Date).ToString('yyyy-MM-dd')
    $stamp = Join-Path $StateDir '.last-rotate'

    if (-not $ForceRotate) {
        if (Test-Path $stamp) {
            if ((Get-Content -LiteralPath $stamp -Raw).Trim() -eq $today) { return }
        }
    }

    if (Test-Path $LiveLog) {
        $mday = (Get-Item -LiteralPath $LiveLog).LastWriteTime.ToString('yyyy-MM-dd')
        if ($mday -ne $today) {
            $arc = Join-Path $LogDir "monitor-$mday.log"
            if (Test-Path $arc) { $arc = Join-Path $LogDir "monitor-$mday.$PID.log" }
            try { Move-Item -LiteralPath $LiveLog -Destination $arc -Force } catch { }
        }
    }

    $cutoff = (Get-Date).AddDays(-1 * $RetainDays).ToString('yyyy-MM-dd')
    Get-ChildItem -LiteralPath $LogDir -Filter 'monitor-*.log' -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -match '^monitor-(\d{4}-\d{2}-\d{2})') {
            if ([datetime]$Matches[1] -lt [datetime]$cutoff) {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
    [System.IO.File]::WriteAllText($stamp, $today, $Utf8NoBom)
}

# ────────────────────────────────────────────────────────────────
#  诊断模式
# ────────────────────────────────────────────────────────────────
function Show-Diagnose {
    Write-Output ''
    Write-Output '================ campus-net-autologin 环境诊断 ================'
    Write-Output ("PowerShell  {0}" -f $PSVersionTable.PSVersion)
    Write-Output ("系统        {0}" -f (Get-CimInstance Win32_OperatingSystem).Caption)
    Write-Output ("curl.exe    {0}" -f $(if ($script:HasCurl) { '有（用作探针与认证）' } else { '没有，回退到 .NET（Windows 10 1803+ 自带 curl.exe）' }))
    Write-Output ''
    Write-Output '--- 所有网卡 ---'
    Get-NetIPConfiguration -ErrorAction SilentlyContinue | ForEach-Object {
        $ip = ''; if ($_.IPv4Address) { $ip = ($_.IPv4Address | Select-Object -First 1).IPAddress }
        $gw = ''; if ($_.IPv4DefaultGateway) { $gw = ($_.IPv4DefaultGateway | Select-Object -First 1).NextHop }
        $bad = $_.InterfaceAlias -match $script:ExcludePattern
        Write-Output ("  [{0}] ifIndex={1,-4} {2,-10} ip={3,-16} gw={4,-16} {5}" -f
            $(if ($_.NetAdapter.Status -eq 'Up') { 'up' } else { '--' }),
            $_.InterfaceIndex, $_.InterfaceAlias, $ip, $gw,
            $(if ($bad) { '(虚拟/隧道，已排除)' } else { '' }))
    }
    Write-Output ''
    Write-Output '--- 自动选中的网卡 ---'
    $info = Get-CampusInfo
    if (-not $info) {
        Write-Output '  ✗ 没找到可用网卡（都 Down 或被排除）。如果确实用某个虚拟网卡，请在 config.ps1 里指定 $IfIndex。'
    } else {
        Write-Output ("  ifIndex = {0}" -f $info.Index)
        Write-Output ("  名称    = {0}" -f $info.Alias)
        Write-Output ("  描述    = {0}" -f $info.Desc)
        Write-Output ("  IPv4    = {0}" -f $(if ($info.IP) { $info.IP } else { '<无>' }))
        Write-Output ("  网关    = {0}" -f $(if ($info.GW) { $info.GW } else { '<无>' }))
        Write-Output ("  MAC     = {0}" -f $info.Mac)
    }
    Write-Output ''
    Write-Output '--- 探针（IP 直连，绕开 DNS）---'
    foreach ($u in $Probes) {
        $r = Invoke-Probe -Url $u -LocalIp $(if ($info) { $info.IP } else { '' })
        Write-Output ("  {0,-28} → HTTP {1,-5} Location={2}" -f $u, $r.Code, $r.Location)
    }
    if ($info) {
        $st = Get-OnlineState -LocalIp $info.IP
        Write-Output ("  判定    = {0}   ({1})" -f $(if ($st.Online) { '在线' } else { '被踢 / 不通' }), $st.Detail)
    }
    Write-Output ''
    Write-Output '--- portal 可达性 ---'
    $host_ = $PortalHost
    if (-not $host_ -and $EportalBase) {
        try { $host_ = ([uri]$EportalBase).Host } catch { }
    }
    if (-not $host_) {
        Write-Output '  η 还没填 PortalHost，跳过'
    } else {
        foreach ($u in @("http://$host_/", "http://${host_}:801/eportal")) {
            $r = Invoke-Probe -Url $u -LocalIp $(if ($info) { $info.IP } else { '' })
            Write-Output ("  {0,-40} → HTTP {1}" -f $u, $r.Code)
        }
    }
    Write-Output ''
    Write-Output '--- 配置 ---'
    Write-Output ("  配置文件      {0} {1}" -f $Config, $(if ($ConfigExists) { '(存在)' } else { '(不存在！需要从 config.example.ps1 复制)' }))
    Write-Output ("  CampusUser    {0}" -f $(if ($CampusUser) { $CampusUser } else { '<空>' }))
    Write-Output ("  CampusPass    {0}" -f $(if ($CampusPass) { "已设置($($CampusPass.Length) 位)" } else { '<空>' }))
    Write-Output ("  PortalHost    {0}" -f $(if ($PortalHost) { $PortalHost } else { '<空>' }))
    Write-Output ("  EportalBase   {0}" -f $(if ($EportalBase) { $EportalBase } else { "(留空，将用 http://$PortalHost`:801/eportal)" }))
    Write-Output ("  日志目录      {0}" -f $LogDir)
    Write-Output ("  保留天数      {0}" -f $RetainDays)
    Write-Output ''
    Write-Output '==============================================================='
    Write-Output ''
}

# ────────────────────────────────────────────────────────────────
#  主流程
# ────────────────────────────────────────────────────────────────
function Invoke-Main {
    if ($Diagnose) { Show-Diagnose; return 0 }

    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }

    if ($Rotate) {
        Invoke-LogRotation -ForceRotate
        Write-Output "日志轮转完成（保留 $RetainDays 天）：$LogDir"
        Get-ChildItem -LiteralPath $LogDir -Filter 'monitor*.log' -ErrorAction SilentlyContinue |
            Sort-Object Name | ForEach-Object {
                $n = (Get-Content -LiteralPath $_.FullName -ErrorAction SilentlyContinue | Measure-Object).Count
                Write-Output ("  {0,6} 行  {1}" -f $n, $_.FullName)
            }
        return 0
    }

    Invoke-LogRotation

    $info  = Get-CampusInfo
    $ip    = ''
    $mac   = ''
    $gw    = ''
    if ($info) { $ip = $info.IP; $mac = $info.Mac; $gw = $info.GW }

    $state = Get-OnlineState -LocalIp $ip

    # --force：即使在线也发一次认证请求，验证请求格式被服务端接受
    if ($Force) {
        Write-CnLog ("TEST  --force 手动认证测试  ip={0} mac={1} gw={2} online={3}" -f $ip, $mac, $gw, $state.Detail)
        $rc = Invoke-EportalLogin -Ip $ip
        Write-CnLog ("TEST  --force 结果 rc={0}（ok=服务端接受了该请求）" -f $rc)
        Write-Output "rc=$rc"
        return 0
    }

    $key = 'ip={0} mac={1} online={2}' -f $ip, $mac, $state.Detail

    if ($state.Online) {
        $now = [int64](Get-Date -UFormat %s)
        $prev = Read-StateKey
        $last = Read-StateEpoch
        if ($key -ne $prev -or ($now - $last) -ge $HeartbeatSec) {
            Write-CnLog ("OK    iface={0} ip={1} mac={2} gw={3} online={4}" -f $info.Alias, $ip, $mac, $gw, $state.Detail)
            Write-StateFiles -Key $key
        }
        return 0
    }

    # 掉线：区分"链路层"和"被 portal 拦"
    $linkDown = [string]::IsNullOrEmpty($ip)
    if ($linkDown) {
        Write-CnLog ("DOWN  iface={0} ip= mac={1} online={2}  原因=接口没有 IP（网线拔出/未获取到地址），portal 认证无从下手" -f $(if ($info) { $info.Alias } else { '<无网卡>' }), $mac, $state.Detail)
    } else {
        Write-CnLog ("DOWN  iface={0} ip={1} mac={2} gw={3} online={4}  原因=有 IP 但外网不通（portal 拦截/被踢下线），自动重新认证" -f $info.Alias, $ip, $mac, $gw, $state.Detail)
    }

    $rc = Invoke-EportalLogin -Ip $ip
    if ($rc -eq 'skip') { return 2 }

    Start-Sleep -Seconds 3
    $after = Get-OnlineState -LocalIp $ip
    if ($after.Online) {
        if ($rc -eq 'ok') {
            Write-CnLog ("AUTH  OK 本脚本认证成功  ip={0} mac={1} online={2}" -f $ip, $mac, $after.Detail)
        } else {
            $why = '当时没有 IP'
            if (-not $linkDown) { $why = '认证请求未被接受' }
            Write-CnLog ("AUTH  OK 网络自行恢复（本脚本本次未能认证：rc=$rc，原因=$why）  ip={0} online={1}" -f $ip, $after.Detail)
        }
        Write-StateFiles -Key ('ip={0} mac={1} online={2}' -f $ip, $mac, $after.Detail)
    } else {
        Write-CnLog ("AUTH  FAIL 自动认证未成功（rc=$rc）  ip={0} mac={1} online={2}" -f $ip, $mac, $after.Detail)
    }
    return 0
}

exit (Invoke-Main)

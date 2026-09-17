# campus-net-autologin (Windows) 配置模板
# 复制成 config.ps1 后填写：  Copy-Item config.example.ps1 config.ps1
# config.ps1 含密码，别提交到 git（仓库的 .gitignore 已排除它）。
#
# 编码提示：本文件是 UTF-8 with BOM。用记事本编辑后若中文注释变成乱码，
# 不影响功能（要填的值本来就是 ASCII）；想避免就在"另存为"里选 UTF-8。

# ── 账号 ──────────────────────────────────────────────────────
# 学号。有些学校要带运营商后缀 —— 移动是 @cmcc、电信是 @dx、联通是 @lt
$CampusUser = "你的学号"
$CampusPass = "你的密码"

# ── portal 地址 ───────────────────────────────────────────────
# 掉线时浏览器会自动跳到登录页，看地址栏那个 IP，形如 http://10.x.x.x/a70.htm?...
$PortalHost  = "10.x.x.x"
$EportalBase = ""        # 留空则自动用 http://<PortalHost>:801/eportal

# 认证时上报的 MAC。eportal 标准做法是全 0；若一直失败可改成真实 MAC（大写、无分隔符）
$EportalMac  = "000000000000"

# ── 网卡（一般不用改）────────────────────────────────────────
# 0 = 自动挑：优先"有 IPv4 且非虚拟"的网卡，排除 VPN/WSL/Hyper-V/VMware 等
$IfIndex = 0
# 也可以按适配器名匹配（中文系统里常见的是 "以太网" 或 "WLAN"）
$IfAlias = ""

# ── 其它（可选）──────────────────────────────────────────────
$RetainDays   = 90       # 日志保留天数
$HeartbeatSec = 1800     # 状态没变时最多多久写一条心跳（秒）

# 探针：用 IP 直连，绕开 DNS 被 VPN/代理劫持导致的误判
$Probes = @('http://223.5.5.5/', 'http://1.1.1.1/')

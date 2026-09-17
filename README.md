# campus-net-autologin

macOS 校园网**掉线自动重连**工具。适用于使用 **Dr.COM / 锐捷 eportal** Web 认证的校园网。

被学校踢下线时（并发设备数超限、会话超时），典型表现是「Wi-Fi 连着、网关也 ping 得通，
但网页打不开、要重新登录」。这个工具每 30 秒探活一次，一旦发现被踢就自动重新认证，
通常几秒内恢复。

---

## 特性

- **主动探活**：绕开系统代理与 DNS 劫持，用 IP 直连探针判断真实连通性
- **准确识别被踢**：区分「被认证页拦截」和「链路层断开」，不误判
- **自动重认证**：Dr.COM / 锐捷 eportal JSONP 接口
- **网络变化立即触发**：切 Wi-Fi、插拔网线、重新拿 IP 时马上检查
- **开机自启**，状态变化写日志，附带统计脚本
- **只做探活与认证，不改动系统网络配置**

## 环境要求

- macOS（LaunchAgent + `curl`，无第三方依赖）
- 校园网是 **Dr.COM / 锐捷 eportal** Web 认证（浏览器会弹登录页输学号密码）

> **Windows 用户**：见 [`windows/`](windows/) —— 同一套判定逻辑的 PowerShell 移植，
> 用计划任务每分钟探活（Windows 计划程序的最小重复间隔就是 1 分钟）。
> 两边命令、配置项、日志格式、判定规则都对齐。

> 其它认证系统（深澜 srun 等）可以用 `LOGIN_MODE=curl`：把浏览器里真实的登录请求
> 「Copy as cURL」粘进配置即可。

---

## 安装

```bash
git clone https://github.com/Tr1meputiNe/campus-net-autologin.git ~/Desktop/campus-net
cd ~/Desktop/campus-net
./install.sh                                     # 装到 ~/.local/share/campus-net 并加载 LaunchAgent
$EDITOR ~/.local/share/campus-net/config.env     # 填学号/密码/portal 地址
```

`install.sh` 会：

1. 把脚本复制到 `~/.local/share/campus-net/`
2. 生成并加载 `~/Library/LaunchAgents/com.local.campusnet.auth.plist`
3. 日志写到 `~/Library/Logs/campus-net/monitor.log`

其它命令：

```bash
./install.sh --status      # 看 LaunchAgent 状态和最近日志
./install.sh --uninstall   # 卸载（保留配置和日志）
```

---

## 配置（`config.env`）

```bash
IFACE=en1                    # 走校园网的网卡：Wi-Fi 一般是 en1，有线 en0
CAMPUS_USER="你的学号"        # 有的学校要带运营商后缀，如 2025001@cmcc / @dx / @lt
CAMPUS_PASS="你的密码"

LOGIN_MODE=eportal           # eportal | curl | form | open
PORTAL_HOST="10.x.x.x"       # 登录页那个 IP
EPORTAL_BASE="http://10.x.x.x:801/eportal"
EPORTAL_MAC="000000000000"   # eportal 标准做法是全 0
```

**portal IP 怎么找**：掉线时浏览器会自动跳到登录页，看地址栏，形如
`http://10.x.x.x/a70.htm?...` 或 `http://10.x.x.x/`，那个 IP 就是。

**网卡名怎么找**：

```bash
networksetup -listallhardwareports | grep -A2 'Wi-Fi'   # 看 Device: enX
```

改完配置自测一次：

```bash
~/.local/share/campus-net/scripts/portal-login.sh --force
```

> ⚠️ `--force` 在**已在线**时只能证明「请求格式被服务端接受」，**不能验证密码** ——
> eportal 在 IP 已在线时会直接回「已经在线」并返回，压根不校验密码。
> 想验证密码必须真的掉线一次。

---

## Dr.COM / 锐捷 eportal 接口说明

从认证页前端 JS 反解 + 实测确认：

| 项 | 值 |
|---|---|
| 认证 | `GET http://<portal>:801/eportal/portal/login` |
| 状态查询 | `GET http://<portal>/drcom/chkstatus?callback=dr1003&wlan_user_ip=<ip>` |
| 账号参数 | `user_account` |
| 密码参数 | `user_password` |
| 其它必填 | `login_method=1`、`wlan_user_ip`、`wlan_user_mac=000000000000`、`terminal_type=1`、`jsVersion=4.1.3`、`lang=zh-cn`、`callback=dr1003` |
| 成功响应 | `dr1003({"result":1,"msg":"Portal协议认证成功！"})` |
| 已在线 | `dr1003({"result":0,"msg":"IP: x.x.x.x 已经在线！","ret_code":2})` |

被踢时 HTTP 会被重定向到认证页，形如：

```
http://<portal>/a79.htm?wlanuserip=<你的IP>&wlanacname=&wlanacip=<AC的IP>
    &usermac=<你的MAC>&wlanuserfirsturl=<你请求的URL>&ME60=...
```

> 认证页里 `<script>` 那段 `authloginpath='/eportal/?c=ACSetting&a=Login'`、
> `authuserfield='DDDDD'` 是**旧版残留配置**。实测该路径返回的是后台管理 SPA，
> 不是认证接口，别照着写。

---

## 判定逻辑（核心，改动前先读）

`scripts/lib.sh` 的 `cn_online` 负责判断「在线 / 被踢 / 不通」：

| 探针返回 | 判定 |
|---|---|
| `2xx` / `404` | 在线 |
| `3xx` 且 `Location` 是**同 host 的 http→https 升级** | 在线（如 `http://1.1.1.1/` → `https://1.1.1.1/`） |
| 其它 `3xx`（含认证页重定向） | **被踢** |
| 裸 `3xx`（无 `Location`） | **被踢** |
| `000` | 不通（换下一个探针，全失败才判掉线） |

探针用 **IP 直连**（默认 `223.5.5.5` / `1.1.1.1`），避免 DNS 被代理/VPN 的 fake-ip
劫持后误判成「校园网掉线」。

### ⚠️ 两个必须避开的坑

**1. 不能用子串匹配判断「重定向回自己」**

认证页重定向会把原始 URL 塞进参数里：`...&wlanuserfirsturl=http://223.5.5.5/`。
如果写成：

```bash
case "$redir" in ""|*"$url"*) 算在线 ;; esac     # 错
```

就会**误匹配**，把被踢时的 302 判成「在线」，脚本直接不作为（日志里会留下
`online=302` 这种怪记录）。必须比对 **host**。

**2. `curl -w` 的分隔符不能用空格**

```bash
-w '%{http_code} %{redirect_url}'      # 错：redirect_url 为空时会被 shell 吞掉尾随空格
-w '%{http_code}|%{redirect_url}'      # 对
```

---

## 探活间隔与开销

默认 **30 秒**（`StartInterval`）。想改的话重装一次即可：

```bash
START_INTERVAL=60 ./install.sh     # 改成 60 秒
START_INTERVAL=30 ./install.sh     # 改回 30 秒（默认）
```

实测单次开销与不同间隔的代价：

| 间隔 | 最坏恢复时间 | 每天执行 | CPU 合计 | 每天探测请求 |
|---|---|---|---|---|
| 15s | 15s | 5760 次 | 单核 0.74% | ~11500 |
| **30s（默认）** | **30s** | **2880 次** | **单核 0.37%** | **~5760** |
| 60s | 60s | 1440 次 | 单核 0.19% | ~2880 |
| 120s | 2 分钟 | 720 次 | 单核 0.09% | ~1440 |

单次约 2.4 秒墙钟 / 110 毫秒 CPU（大部分时间在等网络 I/O），探针流量约几百字节，
一天合计 2 MB 量级 —— 相当于打开一个网页。

**关键：认证请求只在探活判定「被踢」时才发，正常在线时对学校的认证服务器 0 请求。**

日志心跳默认 30 分钟（`HEARTBEAT_SEC`，可在 `config.env` 里调大）。

日志**默认只保留最近 90 天**（`RETAIN_DAYS`）。轮转由 `portal-login.sh` 每天自动
触发一次，不需要额外定时任务，可以手动立即执行：

```bash
./scripts/portal-login.sh --rotate
```

轮转方式对 SSD 友好：**只做 rename 和 unlink，从不重写文件内容**。

- 跨天时把 `monitor.log` 改名为 `monitor-YYYY-MM-DD.log`（rename 是元数据操作）
- 删掉超过 `RETAIN_DAYS` 天的归档文件（unlink 是元数据操作）
- 全天只有一次 rename、若干次 unlink，**零数据重写**

> 为什么不是"删掉旧行"？因为 POSIX 只有 `ftruncate`（从**尾部**截断），
> macOS/APFS 也不支持收缩文件头部区间。要从头部删就必须把剩余数据前移，
> 那本身就是重写。改成按天分文件后，删除就变成了纯 unlink。

> 日志量说明：早期版本因为状态串里含 `ping=` 这种每次都变的字段，导致每次都判定
> 「状态变了」，每 30 秒刷一行（2447 行/天）。现已改为按**状态指纹**
> （`cn_state_key`，只含 ip/mac/online）判断变化，只在真正变化或 30 分钟心跳时记录，
> 约 50 行/天。

## 日志与统计

```bash
tail -f ~/Library/Logs/campus-net/monitor.log     # 实时看（当前日志）
ls -1 ~/Library/Logs/campus-net/                  # 归档：monitor-YYYY-MM-DD.log
./scripts/log-summary.sh                          # 统计全部
./scripts/log-summary.sh 24                       # 只看最近 24 小时
./scripts/net-monitor.sh                          # 看一次当前状态
./scripts/net-monitor.sh --watch 15 120           # 每 15s 采样，120 次后自动停
```

日志关键字：

| 关键字 | 含义 |
|---|---|
| `OK` | 在线心跳 |
| `DOWN ... 原因=有 IP 但外网不通` | 被踢，正在自动重认证 |
| `DOWN ... 原因=接口没有 IP` | 链路层掉线，认证无从下手，只能等链路恢复 |
| `AUTH OK 本脚本认证成功` | 脚本真的认证成功了 |
| `AUTH OK 网络自行恢复` | 网络自己好的，脚本没参与（别记错功劳） |
| `AUTH FAIL` | 认证失败（密码错、账号后缀不对等） |
| `AUTH SKIP` | 配置缺失或没有 IP，未发送请求（避免触发失败计数） |

---

## 文件说明

```
campus-net/
├── install.sh                                 # 安装 / 卸载 / 看状态
├── config.env.example                         # 配置模板
├── launchd/com.local.campusnet.auth.plist.in  # LaunchAgent 模板（30s 探活）
├── scripts/                                   # macOS
│   ├── lib.sh            # 探活与判定核心
│   ├── portal-login.sh   # 认证主程序（LaunchAgent 调它）
│   ├── net-monitor.sh    # 手动查看状态 / 掉线取证
│   └── log-summary.sh    # 日志统计
└── windows/                                   # Windows 移植
    ├── README.md
    ├── install.ps1                  # 注册/卸载计划任务
    ├── campus-net-autologin.ps1     # 认证主程序
    └── config.example.ps1           # 配置模板
```

## 说明

- 仅用于自己账号在自己设备上的自动重新认证，不涉及绕过任何认证。
- 路由器多设备共享、MAC 伪造等规避设备数量限制的做法，本工具不做也不建议。

## License

MIT

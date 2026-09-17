# Windows 版

macOS 版的 Windows 移植。功能一致：探活 → 判定被踢 → 自动重新认证 → 写日志 → 按天轮转。

## 快速开始

**用 `.cmd` 启动器** —— Windows 默认禁止运行 `.ps1`，启动器会自动带上
`-ExecutionPolicy Bypass`（**只对本次进程生效，不改任何系统设置**）。

在 `windows` 目录里双击 `install.cmd`，或在该目录打开 CMD/PowerShell 执行：

```
install.cmd                 :: 安装（会弹 UAC 提权，因为要注册计划任务）
campus-net.cmd config       :: 填学号 / 密码 / portal 地址
campus-net.cmd diagnose     :: 诊断：确认网卡、探针、portal 都对
campus-net.cmd force        :: 确认服务端接受认证请求
campus-net.cmd log          :: 看最近 20 行日志
```

安装后 `%LOCALAPPDATA%\campus-net\` 下也有一份 `campus-net.cmd`，
以后直接用它，不用再回到解压目录。

### 为什么不能直接跑 `.\install.ps1`？

Windows 客户端默认的 PowerShell 执行策略是 `Restricted`，会报：

> 无法加载文件 ...，因为在此系统上禁止运行脚本。

**这是系统默认设置，不是脚本的问题**，所以默认路径必然失败 —— 请用 `.cmd` 启动器。
`Bypass` 的作用范围仅限该进程。

想永久改策略（可选，非必需）：

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
Get-ChildItem -Recurse | Unblock-File    # ZIP 解压出来的文件还需解锁
```

### 从 ZIP 安装必须多做一步

GitHub 下载的 ZIP 解压后，每个文件都带"来自 Internet"标记，PowerShell 会拒绝运行
（这一点 `.cmd` 启动器也救不了）：

```powershell
Get-ChildItem -Recurse | Unblock-File
```

## 命令

推荐用 `.cmd` 启动器（会自动绕过执行策略限制）：

| 命令 | 作用 |
|---|---|
| `install.cmd` | 安装并注册计划任务 |
| `install.cmd -Status` | 任务状态 + 最近 15 行日志 |
| `install.cmd -Uninstall` | 删除任务（保留配置和日志） |
| `campus-net.cmd diagnose` | 环境诊断，用来填配置 |
| `campus-net.cmd force` | 立即发一次认证请求 |
| `campus-net.cmd rotate` | 立即轮转日志 |
| `campus-net.cmd log` | 看最近 20 行日志 |
| `campus-net.cmd config` | 用记事本打开配置 |
| `campus-net.cmd status` | 计划任务状态 |

等价的原始 PowerShell 命令（需要自己加 `-ExecutionPolicy Bypass`）：

| 命令 | 作用 |
|---|---|
| `install.ps1` | 安装 |
| `campus-net-autologin.ps1 -Diagnose` | 环境诊断 |
| `campus-net-autologin.ps1 -Force` | 立即认证 |
| `campus-net-autologin.ps1 -Rotate` | 立即轮转日志 |

## 开机自启动

`install.ps1` 注册的计划任务带**两个触发器**：

| 触发器 | 作用 |
|---|---|
| **登录时**（AtLogOn） | 你登录 Windows 后**立刻跑一次** —— 这就是"开机自启动" |
| **每分钟**（重复） | 之后持续轮询，每 60 秒探活一次 |

用 `-Status` 可以确认两个触发器都在：

```powershell
.\install.ps1 -Status
#   触发器    Logon
#   触发器    Time
```

任务以**当前用户身份、仅在用户登录时运行**注册，所以重启后你一登录就自动起来，
**不需要存储密码**，也不会引入常驻的高权限任务。

> 想在**登录界面之前**就完成认证（例如机器常年锁屏、只用远程桌面连）？
> 那需要把任务改成 SYSTEM 身份运行，配置也得从 `%LOCALAPPDATA%` 挪到 `%ProgramData%`。
> 默认不做，因为那会引入一个以最高权限常驻的任务。有需要可以提 issue。

## 和 macOS 版的差异

| 项 | macOS | Windows |
|---|---|---|
| 开机自启 | LaunchAgent `RunAtLoad`，登录即跑 | 计划任务登录触发器 + 每分钟重复 |
| 定时 | LaunchAgent，30 秒 | 计划任务，**最小 1 分钟** |
| 网络变化触发 | WatchPaths | 无（靠 1 分钟轮询，够用） |
| 绑网卡发请求 | `curl --interface en1` | `curl --interface <本机IP>` |
| 日志 | `~/Library/Logs/campus-net/` | `%LOCALAPPDATA%\campus-net\logs\` |
| 配置 | `config.env` | `config.ps1` |

> Windows 计划程序的重复间隔最小是 1 分钟，所以被踢后最坏要等 60 秒才恢复（macOS 版是 30 秒）。
> 想要 30 秒得改成一个常驻 PowerShell 循环，代价是进程可能意外退出、可靠性下降，这里没有采用。

## 实现要点

- **探针用 IP 直连**（`223.5.5.5` / `1.1.1.1`），不依赖 DNS —— 避免 DNS 被 VPN/代理
  的 fake-ip 劫持后把"校园网被踢"误判成"正常"
- **优先用系统自带的 `curl.exe`**（Windows 10 1803+ / Windows 11 都有），
  这样判定语义和 macOS 版**逐字节一致**（`-w '%{http_code}|%{redirect_url}'`，默认不跟随重定向）；
  没有 curl.exe 时自动回退到 .NET `HttpWebRequest`
- **认证响应写临时文件再按 UTF-8 读**，避免中文（"已经在线"）被控制台编码搞坏
- **日志轮转只做 rename + unlink**，从不重写文件内容（和 macOS 版同一套设计）

## 判定规则（和 macOS 版一致）

| 探针返回 | 判定 |
|---|---|
| `2xx` / `404` | 在线 |
| `3xx` 且 `Location` 是同 host 的 http→https 升级 | 在线 |
| 其它 `3xx`（含认证页重定向） | **被踢**，触发认证 |
| 裸 `3xx`（无 `Location`） | **被踢** |
| `0`（不通） | 换下一个探针，全失败判掉线 |

## 排查

**任务没跑？**
```powershell
.\install.ps1 -Status
Get-ScheduledTask -TaskName campus-net-autologin | Get-ScheduledTaskInfo
```
注意"上次结果"：`0x0` 正常，`0x2` 是找不到文件，`0x1` 是脚本报错。

**选错网卡？**
先跑 `-Diagnose`，看"自动选中的网卡"是不是你要的那块。不是的话在 `config.ps1` 里
按输出里的 `ifIndex` 填 `$IfIndex`，或者按名字填 `$IfAlias`（例如 `"以太网"`）。

**多块网卡 / 有 VPN？**
自动选择会排除名字里含 `VPN`/`WSL`/`Hyper-V`/`VMware`/`VirtualBox`/`Tailscale`/`ZeroTier`
等关键词的适配器，并优先选"有 IPv4 且有默认网关"的那块。

**认证一直失败？**
看日志里的 `AUTH  eportal 响应:` 那一行，服务端原话会写在那里。
- 出现"密码错误" → 检查组 `$CampusUser` 后缀（`@cmcc` 之类要不要去掉）
- 出现"已经在线" → 说明本来就在线，请求格式没问题
- 什么都没有 → 网络到不了 portal，先 `-Diagnose` 看 portal 可达性

## 日志格式

```
2026-09-17 10:42:29 DOWN  iface=以太网 ip=10.x.x.x mac=... online=PORTAL:http://...  原因=有 IP 但外网不通...
2026-09-17 10:42:29 AUTH  eportal 响应: dr1003({"result":1,"msg":"Portal协议认证成功！"});
2026-09-17 10:42:34 AUTH  OK 本脚本认证成功  ip=10.x.x.x mac=... online=404
```

关键词与 macOS 版一致：`OK`（心跳）、`DOWN`（掉线）、`AUTH OK 本脚本认证成功`、
`AUTH OK 网络自行恢复`（脚本没参与）、`AUTH FAIL`、`AUTH SKIP`（配置缺失/没有 IP）。

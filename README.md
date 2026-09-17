# campus-net-autologin

校园网掉线自动重连。macOS 用 LaunchAgent，Windows 用计划任务。

针对 **Dr.COM / 锐捷 eportal** 认证的校园网。

被踢下线时（设备数超限、会话超时），表现是 Wi-Fi 连着但网页打不开、要重新登录。
这个工具定期探活，被踢了就自动重新登录。macOS 每 30 秒，Windows 每 60 秒。

## 安装

### macOS

```bash
git clone https://github.com/Tr1meputiNe/campus-net-autologin.git
cd campus-net-autologin
./install.sh
$EDITOR ~/.local/share/campus-net/config.env   # 填账号、密码、portal 地址
```

装完登录时自启，日志在 `~/Library/Logs/campus-net/`。

### Windows

下载 [最新 release](https://github.com/Tr1meputiNe/campus-net-autologin/releases) 里的 windows 包，解压后在这个目录执行：

```
install.cmd              安装（会弹 UAC）
campus-net.cmd config    填账号、密码、portal 地址
campus-net.cmd diagnose  确认网卡和 portal 都对
```

用 `.cmd`，别直接跑 `install.ps1`（Windows 默认禁止运行脚本）。

日志在 `%LOCALAPPDATA%\campus-net\logs\`。细节见 [windows/](windows/)。

## 配置

三个值：

- `CAMPUS_USER` 学号。有些学校要带运营商后缀 —— 移动是 `@cmcc`、电信是 `@dx`、联通是 `@lt`
- `CAMPUS_PASS` 密码
- `PORTAL_HOST` 登录页那个 IP —— 掉线时浏览器会自动跳过去，看地址栏就知道

## 命令

macOS：

```bash
./install.sh --status          # 服务状态 + 最近日志
./scripts/net-monitor.sh       # 看一眼当前状态
./scripts/log-summary.sh 24    # 统计最近 24 小时
./install.sh --uninstall
```

Windows：

```
campus-net.cmd diagnose | force | log | config | rotate | status
install.cmd -Status | -Uninstall
```

## 出问题

- **网卡选错了**：`diagnose` 会列出每块网卡的 `ifIndex`，填进 `config.ps1` 的 `$IfIndex`
- **认证老失败**：看日志里的 `AUTH  eportal 响应:` 那行，服务端会写原因
- **忘记命令**：`campus-net.cmd` 不带参数会打印用法

## 说明

只用自己账号在自己设备上自动重新登录。不做 MAC 伪造、路由器共享那类绕开设备限制的事。

## License

MIT

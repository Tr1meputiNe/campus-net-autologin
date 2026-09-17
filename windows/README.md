# Windows 版

校园网掉线自动重连，已在 Windows 上实测跑通。

## 安装

下载 [最新 release](https://github.com/Tr1meputiNe/campus-net-autologin/releases) 的 windows 包，解压，在这个目录里执行：

```
install.cmd
```

会弹 UAC（注册计划任务需要）。装到 `%LOCALAPPDATA%\campus-net\`。

用 `.cmd`，别直接跑 `install.ps1` —— Windows 默认禁止运行脚本。

## 配置

```
campus-net.cmd config
```

记事本会打开配置，填三行：

```powershell
$CampusUser  = "你的学号"      # 有些学校要带运营商后缀：移动 @cmcc、电信 @dx、联通 @lt
$CampusPass  = "你的密码"
$PortalHost  = "10.x.x.x"     # 掉线时浏览器跳到的登录页 IP
```

## 确认能用

```
campus-net.cmd diagnose
```

看两处：**自动选中的网卡**是不是你上网用的那块，**portal 可达性**是不是 200。
结果也会存到 `%LOCALAPPDATA%\campus-net\diagnose.txt`。

## 命令

| 命令 | 作用 |
|---|---|
| `install.cmd` | 安装 |
| `install.cmd -Status` | 任务状态 + 最近日志 |
| `install.cmd -Uninstall` | 卸载 |
| `campus-net.cmd diagnose` | 诊断 |
| `campus-net.cmd force` | 立刻认证一次 |
| `campus-net.cmd log` | 看最近 20 行日志 |
| `campus-net.cmd config` | 改配置 |
| `campus-net.cmd rotate` | 轮转日志 |

## 开机自启

计划任务在**登录时**跑一次，之后每分钟跑一次。不保存密码。

## 卸载

```
install.cmd -Uninstall
rmdir /s /q "%LOCALAPPDATA%\campus-net"
```

## 日志

`%LOCALAPPDATA%\campus-net\logs\`，按天归档，默认保留 90 天。

## 出问题

- **网卡选错了**：`diagnose` 会打印每块网卡的 `ifIndex`，填进 `config.ps1` 的 `$IfIndex`
- **认证老失败**：看日志里的 `AUTH  eportal 响应:` 那行，服务端会写原因
- **任务没跑**：`install.cmd -Status` 看「上次结果」，`0x0` 正常

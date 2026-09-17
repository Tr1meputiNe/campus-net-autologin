<#
.SYNOPSIS
    campus-net-autologin (Windows) 安装器

.DESCRIPTION
    把脚本装到 %LOCALAPPDATA%\campus-net，并注册一个每分钟运行一次的计划任务。

    用法（在 windows 目录下执行）：
        .\install.ps1                安装（会自动请求管理员权限）
        .\install.ps1 -Status        查看任务状态和最近日志
        .\install.ps1 -Uninstall     卸载（保留配置和日志）
        .\install.ps1 -IntervalSeconds 60   探活间隔，最小 60 秒

.NOTES
    Windows 计划程序的最小重复间隔是 1 分钟，所以这里默认 60 秒。
    macOS 版用的是 30 秒（LaunchAgent 没有这个限制）。
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$Status,
    [int]$IntervalSeconds = 60
)

$ErrorActionPreference = 'Stop'

$TaskName = 'campus-net-autologin'
$AppDir   = Join-Path $env:LOCALAPPDATA 'campus-net'
$SrcDir   = $PSScriptRoot

# ── 需要管理员权限才能注册计划任务 ──────────────────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host '注册计划任务需要管理员权限，正在提权（会弹 UAC）...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Uninstall) { $argList += '-Uninstall' }
    if ($Status)    { $argList += '-Status' }
    if ($IntervalSeconds -ne 60) { $argList += @('-IntervalSeconds', "$IntervalSeconds") }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
    exit
}

function Get-Task {
    Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
}

# ── 状态 ────────────────────────────────────────────────────────
if ($Status) {
    $t = Get-Task
    if (-not $t) {
        Write-Host "计划任务 $TaskName 未安装。" -ForegroundColor Yellow
    } else {
        $i = Get-ScheduledTaskInfo -TaskName $TaskName
        $rep = $t.Triggers[0].Repetition.Interval
        Write-Host "任务名    $TaskName" -ForegroundColor Green
        Write-Host "状态      $($t.State)"
        Write-Host "重复间隔  $rep"
        foreach ($tr in $t.Triggers) {
            Write-Host "触发器    $($tr.CimClass.CimClassName -replace 'MSFT_Task','' -replace 'Trigger','')"
        }
        Write-Host "上次运行  $($i.LastRunTime)"
        Write-Host "上次结果  0x$('{0:X}' -f $i.LastTaskResult)"
        Write-Host "下次运行  $($i.NextRunTime)"
    }
    Write-Host ''
    Write-Host '--- 最近日志 ---'
    $log = Join-Path $AppDir 'logs\monitor.log'
    if (Test-Path $log) { Get-Content -LiteralPath $log -Tail 15 } else { Write-Host "(还没有日志：$log)" }
    exit 0
}

# ── 卸载 ────────────────────────────────────────────────────────
if ($Uninstall) {
    if (Get-Task) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "已删除计划任务 $TaskName" -ForegroundColor Green
    } else {
        Write-Host "计划任务本来就不存在。"
    }
    Write-Host "配置和日志保留在：$AppDir"
    exit 0
}

# ── 安装 ────────────────────────────────────────────────────────
if ($IntervalSeconds -lt 60) {
    Write-Host "Windows 计划程序最小重复间隔是 60 秒，已自动改为 60。" -ForegroundColor Yellow
    $IntervalSeconds = 60
}

Write-Host "安装到 $AppDir" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $AppDir 'logs')  | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $AppDir 'state') | Out-Null

foreach ($f in @('campus-net-autologin.ps1', 'install.ps1', 'install.cmd', 'campus-net.cmd', 'config.example.ps1', 'README.md')) {
    $src = Join-Path $SrcDir $f
    if (Test-Path $src) { Copy-Item -LiteralPath $src -Destination $AppDir -Force }
}

$cfg = Join-Path $AppDir 'config.ps1'
if (Test-Path $cfg) {
    Write-Host 'config.ps1 已存在，保留不动。' -ForegroundColor Green
} else {
    Copy-Item -LiteralPath (Join-Path $SrcDir 'config.example.ps1') -Destination $cfg -Force
    Write-Host "已生成 $cfg —— 需要填学号/密码/portal 地址" -ForegroundColor Yellow
}

$script = Join-Path $AppDir 'campus-net-autologin.ps1'
if (-not (Test-Path $script)) { throw "找不到主脚本 $script" }

# 注册计划任务：每分钟一次，以当前用户身份、仅在登录时运行、以普通权限运行
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""

# 触发器 1：登录时立刻跑一次 —— 这就是"开机自启动"
#   （任务以"仅在用户登录时运行"的方式注册，所以登录触发是正确粒度；
#    真正想在登录界面之前就认证，需要用 SYSTEM 身份 + ProgramData 配置，见 README）
$triggerLogon = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"

# 触发器 2：之后每 N 秒轮询（不写 RepetitionDuration 即为无限期重复）
$triggerRepeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Seconds $IntervalSeconds)

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive -RunLevel Limited

if (Get-Task) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false | Out-Null }

Register-ScheduledTask -TaskName $TaskName `
    -Action $action -Trigger @($triggerLogon, $triggerRepeat) -Settings $settings -Principal $principal `
    -Description '校园网掉线自动重连（Dr.COM / 锐捷 eportal）' | Out-Null

Write-Host ''
Write-Host "✅ 已注册计划任务 $TaskName（每 $IntervalSeconds 秒一次）" -ForegroundColor Green
Write-Host "   主脚本  $script"
Write-Host "   配置    $cfg"
Write-Host "   日志    $(Join-Path $AppDir 'logs\monitor.log')"
Write-Host ''

# 立刻跑一次，暴露配置问题
Write-Host '立刻试跑一次...' -ForegroundColor Cyan
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script
Write-Host ''
Write-Host '接下来（用 .cmd 启动器，不需要改任何系统设置）：' -ForegroundColor Cyan
Write-Host "  1)  $AppDir\campus-net.cmd config      用记事本填学号/密码/portal 地址"
Write-Host "  2)  $AppDir\campus-net.cmd diagnose    看诊断是否符合预期"
Write-Host "  3)  $AppDir\campus-net.cmd force       确认服务端接受认证请求"
Write-Host "  4)  $AppDir\campus-net.cmd log         看日志"
Write-Host ''
Write-Host '  （也可以在解压目录里跑 .\install.cmd -Status 看任务状态）'

#!/usr/bin/env bash
# 安装/卸载校园网自动认证 LaunchAgent
#   ./install.sh             安装
#   ./install.sh --uninstall 卸载
#   ./install.sh --status    查看运行状态
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/share/campus-net}"
LOG_DIR="$HOME/Library/Logs/campus-net"
LABEL="com.local.campusnet.auth"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_N="$(id -u)"

status() {
    launchctl print "gui/$UID_N/$LABEL" 2>/dev/null | grep -E 'state|pid|last exit code|runs' || echo "未加载"
    echo "--- 最近日志 ---"
    tail -n 15 "$LOG_DIR/monitor.log" 2>/dev/null || echo "(暂无日志)"
}

uninstall() {
    launchctl bootout "gui/$UID_N/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "已卸载。日志和配置保留在 $LOG_DIR 与 $INSTALL_DIR"
}

install() {
    mkdir -p "$INSTALL_DIR/scripts" "$LOG_DIR" "$HOME/Library/LaunchAgents"
    cp "$SRC/scripts/"*.sh "$INSTALL_DIR/scripts/"
    cp "$SRC/config.env.example" "$INSTALL_DIR/"
    [ -f "$SRC/README.md" ] && cp "$SRC/README.md" "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR"/scripts/*.sh

    if [ -f "$INSTALL_DIR/config.env" ]; then
        echo "已存在 config.env，保留不动"
    elif [ -f "$SRC/config.env" ]; then
        # 优先带上工作区里已经填好账号的配置（密码留空，需自己补）
        cp "$SRC/config.env" "$INSTALL_DIR/config.env"
        echo "已从工作区复制 config.env（含账号，密码仍需填写）"
    else
        cp "$SRC/config.env.example" "$INSTALL_DIR/config.env"
        echo "已生成 $INSTALL_DIR/config.env —— 记得填学号/密码"
    fi
    chmod 600 "$INSTALL_DIR/config.env"
    grep -q '^CAMPUS_PASS=""' "$INSTALL_DIR/config.env" 2>/dev/null && \
        echo "⚠️  $INSTALL_DIR/config.env 里 CAMPUS_PASS 还是空的，填上才会自动认证"

    # 探活间隔（秒），可用 START_INTERVAL=60 ./install.sh 覆盖
    INTERVAL="${START_INTERVAL:-30}"
    case "$INTERVAL" in (''|*[!0-9]*) echo "START_INTERVAL 必须是整数"; exit 1 ;; esac
    [ "$INTERVAL" -ge 5 ] || { echo "START_INTERVAL 至少 5 秒"; exit 1; }
    THROTTLE=$(( INTERVAL < 30 ? INTERVAL : 30 ))

    sed -e "s|__INSTALL_DIR__|$INSTALL_DIR|g" \
        -e "s|__LOG_DIR__|$LOG_DIR|g" \
        -e "s|__START_INTERVAL__|$INTERVAL|g" \
        -e "s|__THROTTLE__|$THROTTLE|g" \
        "$SRC/launchd/$LABEL.plist.in" >"$PLIST"

    launchctl bootout "gui/$UID_N/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$UID_N" "$PLIST"
    launchctl kickstart -k "gui/$UID_N/$LABEL" 2>/dev/null || true

    echo
    echo "✅ 已安装并加载：$PLIST（探活间隔 ${INTERVAL}s）"
    echo "   日志：$LOG_DIR/monitor.log"
    echo "   手动跑一次：$INSTALL_DIR/scripts/portal-login.sh"
    echo "   看状态：    $SRC/install.sh --status"
}

case "${1:-}" in
    --uninstall) uninstall ;;
    --status)    status ;;
    *)           install ;;
esac

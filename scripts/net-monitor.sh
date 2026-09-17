#!/usr/bin/env bash
# 掉线取证：打印当前链路/认证状态，并在你掉线时把证据写进日志
#   ./net-monitor.sh            # 看一次当前状态
#   ./net-monitor.sh --watch 10 # 每 10 秒一次，持续观察（Ctrl-C 退出）
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"
cn_load_config

hw_mac() {
    networksetup -listallhardwareports 2>/dev/null \
        | awk -v d="$IFACE" '$0 ~ "Device: "d"$"{f=1} f&&/Ethernet Address/{print $3; exit}'
}

online_desc() {
    case "$1" in
        000)      printf '不通（链路断，或被 portal 拦）' ;;
        PORTAL:*) printf '被重定向到认证页 → %s' "${1#PORTAL:}" ;;
        *)        printf '通 HTTP %s' "$1" ;;
    esac
}

print_one() {
    local ip mac gw ping online hw
    ip="$(cn_ip)"; mac="$(cn_mac)"; gw="$(cn_gw)"; hw="$(hw_mac)"
    ping="$(cn_ping_gw)"; online="$(cn_online)"
    printf '%s\n' "───────────────────────────────────────────────"
    printf '时间      %s\n' "$(CN_TS)"
    printf '网卡      %s\n' "$IFACE"
    printf 'IP        %s\n' "${ip:-<无>}"
    printf '当前 MAC  %s\n' "${mac:-<无>}"
    printf '硬件 MAC  %s\n' "${hw:-<无>}"
    printf '网关      %s (%s)\n' "${gw:-<无>}" "$ping"
    printf '外网探活  %s\n' "$(online_desc "$online")"
    if [ -n "${mac:-}" ] && [ -n "${hw:-}" ] && [ "$mac" != "$hw" ]; then
        printf '设备身份  正在用私有 Wi-Fi 地址 %s（≠ 硬件 MAC %s）\n' "$mac" "$hw"
        printf '          固定模式下它是稳定的 → 去自助服务系统就登记这个 MAC，别关掉它\n'
    fi
    # MAC 一旦变化，学校就会当成一台新设备 —— 这才是"设备数被撑爆"的证据
    local mac_f prevmac
    mac_f="$(cn_state_file "$IFACE").mac"
    prevmac="$(cat "$mac_f" 2>/dev/null || true)"
    if [ -n "$prevmac" ] && [ -n "${mac:-}" ] && [ "$prevmac" != "$mac" ]; then
        printf '⚠️  MAC 变了：%s → %s（校园网会当成新设备，设备名额就是这么被吃掉的）\n' "$prevmac" "$mac"
    fi
    [ -n "${mac:-}" ] && printf '%s' "$mac" >"$mac_f"
    cn_log "PROBE $IFACE ip=${ip:-none} mac=${mac:-none} gw=${gw:-none} ping=$ping online=$online"
}

if [ "${1:-}" = "--watch" ]; then
    n="${2:-10}"
    count="${3:-0}"   # 0 = 一直跑；给数字则采样这么多次后自动退出（抓完证据就走）
    echo "每 ${n}s 采样一次，日志: $LOG_DIR/monitor.log  （Ctrl-C 退出）"
    prev=""; i=0
    while true; do
        cur="$(cn_state)"
        if [ "$cur" != "$prev" ]; then print_one; prev="$cur"; else printf '.'; fi
        i=$((i + 1))
        [ "$count" -gt 0 ] && [ "$i" -ge "$count" ] && { echo; echo "采样 ${i} 次结束"; break; }
        sleep "$n"
    done
else
    print_one
    echo "日志: $LOG_DIR/monitor.log"
fi

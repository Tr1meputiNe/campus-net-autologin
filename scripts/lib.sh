#!/usr/bin/env bash
# 校园网工具公共库：探活、链路取证、日志
# 被 portal-login.sh / net-monitor.sh / portal-probe.sh 共同 source

: "${IFACE:=en1}"

CAMPUS_HOME="${CAMPUS_HOME:-$HOME/.local/share/campus-net}"
CONFIG_FILE="${CONFIG:-$CAMPUS_HOME/config.env}"
LOG_DIR="${LOG_DIR:-$HOME/Library/Logs/campus-net}"
STATE_DIR="${STATE_DIR:-$CAMPUS_HOME/state}"

# 用 IP 直连做探活，避开 DNS 被代理 App 劫持（fake-ip）导致的误判
: "${ONLINE_PROBES:=http://223.5.5.5/ http://1.1.1.1/ http://114.114.114.114/}"

CN_TS() { date '+%Y-%m-%d %H:%M:%S'; }

cn_log() {
    mkdir -p "$LOG_DIR" 2>/dev/null
    printf '%s %s\n' "$(CN_TS)" "$*" >>"$LOG_DIR/monitor.log"
}

cn_state_file() { mkdir -p "$STATE_DIR" 2>/dev/null; printf '%s/%s' "$STATE_DIR" "${1:-$IFACE}"; }

cn_ip()  { ipconfig getifaddr "$IFACE" 2>/dev/null || true; }

cn_mac() {
    ifconfig "$IFACE" 2>/dev/null | awk '/[ \t]ether[ \t]/{print $2; exit}'
}

cn_gw() { ipconfig getoption "$IFACE" router 2>/dev/null || true; }

# 网关可达性：打印 "3.5ms" 或 "LOSS"
cn_ping_gw() {
    local gw out
    gw="$(cn_gw)"; [ -n "$gw" ] || { printf 'NOGW'; return; }
    out="$(ping -c 3 -t 3 "$gw" 2>/dev/null | awk -F'= ' '/round-trip/{print $2}' | awk -F/ '{print $2}')"
    if [ -n "$out" ]; then printf '%sms' "$out"; else printf 'LOSS'; fi
}

# 取 URL 的 host 部分，用于判断"重定向是不是回到同一个站点"
cn_host_of() { printf '%s' "$1" | sed -e 's|^[a-zA-Z][a-zA-Z0-9+.-]*://||' -e 's|/.*$||'; }

# 不走系统代理、强制从校园网卡出去做外网探活。
# 返回：2xx/404 = 在线；PORTAL:<url或状态码> = 被认证页拦截（已掉线）；000 = 完全不通
#
# 判定要点（踩过的坑）：
#   1. 裸 3xx（没有 Location）**绝不能**算在线 —— 校园网被踢时就返回这种 302
#   2. http://1.1.1.1/ 正常会 301 跳到 https://1.1.1.1/，host 相同 ⇒ 算在线
#   3. 真正被 portal 拦截时，Location 指向认证页 host（校内 IP，与探针不同）⇒ 判掉线
cn_online() {
    local url out code redir
    for url in $ONLINE_PROBES; do
        # 用 | 分隔而不是空格：redirect_url 为空时结尾空格会被命令替换吞掉，产生误判
        out="$(curl --noproxy '*' --interface "$IFACE" -s -m 5 -o /dev/null \
                     -w '%{http_code}|%{redirect_url}' "$url" 2>/dev/null)"
        code="${out%%|*}"; redir="${out#*|}"
        [ -n "$code" ] && [ "$code" != "000" ] || continue
        case "$code" in
            2*|404) printf '%s' "$code"; return 0 ;;
            3*)
                # 只认「http → https 同 host」这种升级跳转算正常；
                # 其余 3xx（含把原始 URL 塞进参数里的认证页重定向）一律判掉线
                if [ -n "$redir" ] &&
                   [ "$(cn_host_of "$redir")" = "$(cn_host_of "$url")" ] &&
                   [ "${redir%%:*}" = "https" ] && [ "${url%%:*}" = "http" ]; then
                    printf '%s' "$code"; return 0
                fi
                if [ -z "$redir" ]; then
                    printf 'PORTAL:裸%s(无Location)' "$code"; return 1
                fi
                printf 'PORTAL:%s' "$redir"; return 1
                ;;
            *) continue ;;                              # 其它状态码换下一个探针
        esac
    done
    printf '000'; return 1
}

# 状态指纹：只保留"有意义"的字段（排除 ping 这类每次都变的），
# 用来判断状态是否真的变化，避免日志每 30 秒刷一行
cn_state_key() {
    printf 'iface=%s ip=%s mac=%s online=%s' \
        "$IFACE" "$(cn_ip)" "$(cn_mac)" "$(cn_online)"
}

# 一行完整状态：写日志、人工查看用
cn_state() {
    printf 'iface=%s ip=%s mac=%s gw=%s ping=%s online=%s' \
        "$IFACE" "$(cn_ip)" "$(cn_mac)" "$(cn_gw)" "$(cn_ping_gw)" "$(cn_online)"
}

cn_load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        . "$CONFIG_FILE"
    fi
}

# 日志轮转：跨天把 monitor.log 改名归档，并删除超过 RETAIN_DAYS 天的归档文件。
# 全程只做 rename 和 unlink —— 都是元数据操作，从不重写文件内容。
#   cn_rotate_log          正常调用（每个自然日最多执行一次）
#   cn_rotate_log force    立即执行（手动）
cn_rotate_log() {
    local force="${1:-}" days="${RETAIN_DAYS:-90}" live="$LOG_DIR/monitor.log"
    local today lastday mday archive cutoff f d

    case "$days" in (''|*[!0-9]*) days=90 ;; esac
    [ "$days" -ge 1 ] 2>/dev/null || days=90
    today="$(date '+%Y-%m-%d')"

    # 每个自然日只做一次（rename/unlink 很便宜，但没必要每 30 秒扫一遍目录）
    if [ "$force" != "force" ]; then
        lastday="$(cat "$STATE_DIR/.last-rotate" 2>/dev/null || true)"
        [ "$lastday" = "$today" ] && return 0
    fi

    # 1) 跨天归档：monitor.log -> monitor-<日期>.log（纯 rename，内容一个字节都不动）
    if [ -f "$live" ]; then
        mday="$(date -r "$live" '+%Y-%m-%d' 2>/dev/null || printf '%s' "$today")"
        if [ "$mday" != "$today" ]; then
            archive="$LOG_DIR/monitor-$mday.log"
            [ -e "$archive" ] && archive="$LOG_DIR/monitor-$mday.$$.log"
            mv "$live" "$archive" 2>/dev/null || true
        fi
    fi

    # 2) 删除过期归档：纯 unlink，零数据写入
    cutoff="$(date -v-"${days}"d '+%Y-%m-%d')"
    for f in "$LOG_DIR"/monitor-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*.log; do
        [ -e "$f" ] || continue
        d="$(basename "$f" | cut -c9-18)"
        [[ "$d" < "$cutoff" ]] && rm -f "$f"
    done

    mkdir -p "$STATE_DIR" 2>/dev/null
    printf '%s' "$today" >"$STATE_DIR/.last-rotate"
    return 0
}

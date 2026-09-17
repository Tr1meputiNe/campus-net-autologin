#!/usr/bin/env bash
# 校园网自动认证 + 状态记录。由 LaunchAgent 定时/网络变化时调用，也可手动跑。
#
# 认证方式（LOGIN_MODE）：
#   eportal  Dr.COM / 锐捷 eportal JSONP 接口（本校园实测可用，默认）
#   curl     逐字重放浏览器 DevTools 里 Copy as cURL 的请求
#   form     普通表单 POST
#   open     不自动提交，只把登录页弹出来
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"
cn_load_config

HEARTBEAT_SEC="${HEARTBEAT_SEC:-1800}"
STATE_F="$(cn_state_file "$IFACE")"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

verify_online() { cn_online >/dev/null 2>&1; }

# ── Dr.COM / 锐捷 eportal 认证 ─────────────────────────────────────────
# 实测：GET http://<portal>:801/eportal/portal/login
#   成功     dr1003({"result":1,...})
#   已在线   dr1003({"result":0,"msg":"IP: x.x.x.x 已经在线！","ret_code":2})
#   失败     dr1003({"result":0,"msg":"...密码错误...","ret_code":...})
eportal_login() {
    local ip base url v resp
    ip="$(cn_ip)"
    if [ -z "$ip" ]; then
        cn_log "AUTH  SKIP 接口没有 IP，portal 认证无从下手（与密码无关）"
        return 1
    fi

    # 绝不发送空密码：连续失败可能触发账号锁定
    if [ -z "${CAMPUS_PASS:-}" ]; then
        cn_log "AUTH  SKIP config.env 里 CAMPUS_PASS 是空的，不发送（避免失败计数）"
        return 2
    fi
    if [ -z "${CAMPUS_USER:-}" ]; then
        cn_log "AUTH  SKIP config.env 里 CAMPUS_USER 是空的"
        return 2
    fi

    if [ -z "${EPORTAL_BASE:-}" ] && [ -z "${PORTAL_HOST:-}" ]; then
        cn_log "AUTH  SKIP 未配置 EPORTAL_BASE / PORTAL_HOST（见 config.env.example）"
        return 2
    fi
    base="${EPORTAL_BASE:-http://${PORTAL_HOST}:801/eportal}"
    url="$base/portal/login"
    v="$((RANDOM % 9000 + 1000)).$((RANDOM % 900 + 100))"

    resp="$(curl --noproxy '*' --interface "$IFACE" -s -m 10 -G "$url" \
        --data-urlencode "callback=dr1003" \
        --data-urlencode "login_method=1" \
        --data-urlencode "user_account=${CAMPUS_USER}" \
        --data-urlencode "user_password=${CAMPUS_PASS}" \
        --data-urlencode "wlan_user_ip=${ip}" \
        --data-urlencode "wlan_user_ipv6=" \
        --data-urlencode "wlan_user_mac=${EPORTAL_MAC:-000000000000}" \
        --data-urlencode "wlan_ac_ip=" \
        --data-urlencode "wlan_ac_name=" \
        --data-urlencode "jsVersion=4.1.3" \
        --data-urlencode "terminal_type=1" \
        --data-urlencode "lang=zh-cn" \
        --data-urlencode "v=${v}" 2>/dev/null)"

    cn_log "AUTH  eportal 响应: ${resp:0:220}"

    case "$resp" in
        *'"result":1'*) return 0 ;;            # 认证成功
        *'已经在线'*)   return 0 ;;            # 本来就在线，等同于成功
        *)              return 1 ;;
    esac
}

do_login() {
    local mode="${LOGIN_MODE:-eportal}"
    case "$mode" in
    eportal)
        eportal_login ;;
    curl)
        if [ -z "${LOGIN_CURL:-}" ]; then
            cn_log "AUTH  FAIL LOGIN_MODE=curl 但 LOGIN_CURL 为空"
            return 1
        fi
        eval "$LOGIN_CURL" >/dev/null 2>&1 ;;
    form)
        if [ -z "${PORTAL_LOGIN_URL:-}" ]; then
            cn_log "AUTH  FAIL LOGIN_MODE=form 但 PORTAL_LOGIN_URL 为空"
            return 1
        fi
        curl --noproxy '*' --interface "$IFACE" -s -m 10 -o /dev/null \
             --data-urlencode "${PORTAL_USER_FIELD}=${CAMPUS_USER}" \
             --data-urlencode "${PORTAL_PASS_FIELD}=${CAMPUS_PASS}" \
             ${PORTAL_EXTRA_FIELDS:+-d "$PORTAL_EXTRA_FIELDS"} \
             "$PORTAL_LOGIN_URL" 2>/dev/null ;;
    open)
        [ -n "${PORTAL_URL:-}" ] && open "$PORTAL_URL" ;;
    *)
        cn_log "AUTH  FAIL 未知 LOGIN_MODE=$mode"; return 1 ;;
    esac
}

main() {
    local cur key prev last now rc ip_now LINK_DOWN

    # --force：即使当前在线也发一次认证请求，用来验证参数是否被服务端接受
    if [ "$FORCE" = "1" ]; then
        cn_log "TEST  --force 手动认证测试  $(cn_state)"
        do_login; rc=$?
        cn_log "TEST  --force 结果 rc=$rc（0=服务端接受了这个请求）"
        return $rc
    fi

    cur="$(cn_state)"          # 完整状态，写日志用
    key="$(cn_state_key)"      # 指纹，判断是否真的变了
    ip_now="$(cn_ip)"

    if verify_online; then
        now=$(date +%s)
        prev="$(cat "$STATE_F" 2>/dev/null || true)"
        last="$(cat "$STATE_F.epoch" 2>/dev/null || echo 0)"
        if [ "$key" != "$prev" ] || [ $((now - last)) -ge "$HEARTBEAT_SEC" ]; then
            cn_log "OK    $cur"
            printf '%s' "$key" >"$STATE_F"
            printf '%s' "$now" >"$STATE_F.epoch"
        fi
        return 0
    fi

    if [ -z "$ip_now" ]; then
        cn_log "DOWN  $cur  原因=接口没有 IP（Wi-Fi 掉链/未关联），portal 认证无从下手，只能等链路恢复"
        LINK_DOWN=1
    else
        cn_log "DOWN  $cur  原因=有 IP 但外网不通（portal 拦截/被踢下线），自动重新认证"
        LINK_DOWN=0
    fi

    do_login; rc=$?
    [ "$rc" = "2" ] && return 2      # 配置缺失，别反复重试

    sleep 3
    if verify_online; then
        if [ "$rc" = "0" ]; then
            cn_log "AUTH  OK 本脚本认证成功  $(cn_state)"
        else
            cn_log "AUTH  OK 网络自行恢复（本脚本本次未能认证：rc=$rc，原因=$([ "$LINK_DOWN" = "1" ] && echo '当时没有 IP' || echo '认证请求未被接受')）  $(cn_state)"
        fi
        cn_state_key >"$STATE_F"; date +%s >"$STATE_F.epoch"
    else
        cn_log "AUTH  FAIL 自动认证未成功（rc=$rc）  $(cn_state)"
    fi
}

main "$@"

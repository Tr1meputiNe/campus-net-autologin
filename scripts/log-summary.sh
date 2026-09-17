#!/usr/bin/env bash
# 汇总掉线日志：掉了几次、自动重连成功几次、按小时分布、MAC 有没有变过
#   ./log-summary.sh                      # 看全部
#   ./log-summary.sh 24                   # 只看最近 24 小时
set -uo pipefail

LOG_DIR="${LOG_DIR:-$HOME/Library/Logs/campus-net}"
HOURS="${1:-0}"

# 归档文件名是 monitor-YYYY-MM-DD.log，字母序即时间序，且都排在 monitor.log 之前
FILES="$(ls -1 "$LOG_DIR"/monitor*.log 2>/dev/null | sort)"
[ -n "$FILES" ] || { echo "找不到日志：$LOG_DIR/monitor*.log"; exit 1; }

DATA="$(cat $FILES)"
if [ "$HOURS" -gt 0 ] 2>/dev/null; then
    SINCE=$(date -v-"${HOURS}"H '+%Y-%m-%d %H:%M:%S')
    DATA="$(printf '%s\n' "$DATA" | awk -v s="$SINCE" '$1" "$2 >= s')"
    echo "=== 最近 ${HOURS} 小时（自 ${SINCE}） ==="
else
    echo "=== 全部记录（$(printf '%s\n' "$FILES" | wc -l | tr -d ' ') 个日志文件） ==="
fi

printf '%s\n' "$DATA" | awk '
    $3=="OK"   { ok++ }
    $3=="DOWN" { down++; split($2,t,":"); byhour[t[1]]++ }
    /本脚本认证成功/ { authok++ }
    /自动认证未成功/ { authfail++ }
    /网络自行恢复/   { selfheal++ }
    /没有 IP/        { noip++ }
    { n++ }
    END {
        printf "总记录        %d 条\n", n
        printf "在线心跳      %d 次\n", ok+0
        printf "掉线事件      %d 次\n", down+0
        printf "  ├ 本脚本认证成功  %d 次   ← 自动重连真实生效\n", authok+0
        printf "  ├ 认证失败        %d 次\n", authfail+0
        printf "  ├ 网络自行恢复    %d 次   ← 脚本没参与，别算它的功劳\n", selfheal+0
        printf "  └ 当时没有 IP     %d 次   ← 链路层掉线，portal 认证无从下手\n", noip+0
        if (down > 0) {
            printf "\n掉线按小时分布：\n"
            for (h in byhour) printf "  %s 时   %d 次\n", h, byhour[h]
        } else {
            printf "\n观察期内一次都没掉。\n"
        }
    }'

printf '\nMAC 出现过的值（多于 1 个说明设备身份变过）：\n'
printf '%s\n' "$DATA" | grep -oE '(^|[[:space:]])mac=[0-9a-fA-F:]+' \
    | sed 's/^[[:space:]]*//' | sort | uniq -c | sed 's/^/  /'

printf '\n最近 5 次掉线/认证事件：\n'
printf '%s\n' "$DATA" | grep -E 'DOWN|本脚本认证成功|自动认证未成功|网络自行恢复' | tail -5 | cut -c1-140 | sed 's/^/  /'

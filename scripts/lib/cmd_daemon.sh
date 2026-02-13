# shellcheck shell=bash
# lib/cmd_daemon.sh - daemonコマンド（cmd_service.shへのエイリアス）
#
# ignite daemon は ignite service の後方互換エイリアスです。
# 新規利用には ignite service を推奨します。

[[ -n "${__LIB_CMD_DAEMON_LOADED:-}" ]] && return; __LIB_CMD_DAEMON_LOADED=1

LIB_DIR="${LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

cmd_daemon() {
    print_warning "ignite daemon は非推奨です。ignite service を使用してください。"
    echo ""

    # cmd_service.sh を遅延ロード
    source "${LIB_DIR}/cmd_service.sh"
    cmd_service "$@"
}

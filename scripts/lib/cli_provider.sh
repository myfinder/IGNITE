# shellcheck shell=bash
# lib/cli_provider.sh - CLI Provider 抽象化レイヤー（ディスパッチャー）
# プロバイダー固有の実装は cli_provider_opencode.sh / cli_provider_claude.sh / cli_provider_codex.sh に委譲
[[ -n "${__LIB_CLI_PROVIDER_LOADED:-}" ]] && return; __LIB_CLI_PROVIDER_LOADED=1

# グローバル変数（cli_load_config で設定される）
CLI_PROVIDER=""
CLI_MODEL=""
CLI_COMMAND=""
CLI_LOG_LEVEL=""

# =============================================================================
# cli_load_config - system.yaml の cli: セクション読み込み + プロバイダー source
# =============================================================================
cli_load_config() {
    CLI_PROVIDER=$(get_config cli provider "opencode")

    # プロバイダーバリデーション
    case "$CLI_PROVIDER" in
        opencode|claude|codex) ;;
        *)
            log_warn "不正な cli.provider: $CLI_PROVIDER（有効値: opencode/claude/codex）。opencode にフォールバック"
            CLI_PROVIDER="opencode"
            ;;
    esac

    CLI_MODEL=$(get_config cli model "$DEFAULT_MODEL")

    # モデル名バリデーション（英数字, ハイフン, ドット, スラッシュ, アンダースコア, コロンのみ許可）
    if [[ ! "$CLI_MODEL" =~ ^[a-zA-Z0-9/:._-]+$ ]]; then
        print_error "不正な model 名: $CLI_MODEL（使用可能: 英数字, /, :, ., _, -）"
        return 1
    fi

    # プロバイダーに応じてコマンド名を設定
    case "$CLI_PROVIDER" in
        opencode)
            CLI_COMMAND="opencode"
            ;;
        claude)
            CLI_COMMAND="claude"
            ;;
        codex)
            CLI_COMMAND="codex"
            ;;
    esac

    # ログレベル（opencode 用、他プロバイダーでは無視）
    CLI_LOG_LEVEL=$(get_config cli log_level "")
    if [[ -n "$CLI_LOG_LEVEL" ]]; then
        case "$CLI_LOG_LEVEL" in
            DEBUG|INFO|WARN|ERROR) ;;
            *)
                log_warn "不正な cli.log_level: $CLI_LOG_LEVEL（有効値: DEBUG/INFO/WARN/ERROR）。無視します"
                CLI_LOG_LEVEL=""
                ;;
        esac
    fi

    # プロバイダー固有モジュールを source
    local _cli_provider_dir
    _cli_provider_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local _provider_script="${_cli_provider_dir}/cli_provider_${CLI_PROVIDER}.sh"
    if [[ -f "$_provider_script" ]]; then
        # shellcheck source=/dev/null
        source "$_provider_script"
    else
        log_error "プロバイダースクリプトが見つかりません: $_provider_script"
        return 1
    fi
}

# =============================================================================
# 共通ユーティリティ関数（プロバイダー非依存）
# =============================================================================

# _validate_pid <pid> <expected_pattern> [expected_starttime]
# PID が生存しており、cmdline が期待パターンにマッチするか検証
# expected_starttime が指定された場合、PIDリサイクルを検出する（Linux のみ）
_validate_pid() {
    local pid="$1"
    local expected_pattern="$2"
    local expected_starttime="${3:-}"
    if [[ -z "$pid" ]]; then
        log_warn "_validate_pid: PID が空です"
        return 1
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
        log_warn "_validate_pid: PID=$pid は生存していません"
        return 1
    fi
    # PIDリサイクル検出（Linux環境のみ）
    if [[ -n "$expected_starttime" ]] && [[ -f "/proc/$pid/stat" ]]; then
        local current_starttime
        current_starttime=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)
        if [[ -n "$current_starttime" ]] && [[ "$current_starttime" != "$expected_starttime" ]]; then
            log_warn "_validate_pid: PID=$pid はリサイクルされています (starttime: expected=$expected_starttime, actual=$current_starttime)"
            return 1
        fi
    fi
    if [[ -f "/proc/$pid/cmdline" ]]; then
        if ! tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q "$expected_pattern"; then
            log_warn "_validate_pid: PID=$pid の cmdline が期待パターン '$expected_pattern' にマッチしません"
            return 1
        fi
    else
        # macOS フォールバック
        if ! ps -p "$pid" -o args= 2>/dev/null | grep -q "$expected_pattern"; then
            log_warn "_validate_pid: PID=$pid の args が期待パターン '$expected_pattern' にマッチしません (macOS)"
            return 1
        fi
    fi
    return 0
}

# _get_pgid <pid>
# PID からプロセスグループ ID (PGID) を取得する
# setsid 前提: PID == PGID が不変条件として成立
# 優先順位: (1) /proc/$pid/stat field 5 (Linux) → (2) ps -o pgid= (macOS) → (3) $pid (最終FB)
_get_pgid() {
    local pid="$1"
    local pgid=""

    # (1) Linux: /proc/$pid/stat の field 5 から PGID 取得
    if [[ -f "/proc/$pid/stat" ]]; then
        pgid=$(awk '{print $5}' "/proc/$pid/stat" 2>/dev/null || true)
        if [[ -n "$pgid" ]]; then
            echo "$pgid"
            return 0
        fi
    fi

    # (2) macOS フォールバック: ps -o pgid=
    pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
    if [[ -n "$pgid" ]]; then
        echo "$pgid"
        return 0
    fi

    # (3) 最終フォールバック: setsid 前提で PID == PGID
    echo "$pid"
    return 0
}

# _kill_process_tree <pid> <pane_idx> [runtime_dir]
# プロセスツリーを安全に停止する共通ユーティリティ
# kill順序: (1) _validate_pid → _get_pgid → PGID kill → (2) pkill -P → (3) kill PID → (4) 生存確認ループ → (5) SIGKILL
_kill_process_tree() {
    local pid="$1"
    local pane_idx="$2"
    local runtime_dir="${3:-${IGNITE_RUNTIME_DIR:-}}"
    local max_wait=10  # 生存確認タイムアウト（0.5秒 × 10回 = 5秒）: systemd TimeoutStopSec=30 と整合
    local pgid=""
    local _process_pattern
    _process_pattern=$(cli_get_process_pattern 2>/dev/null || echo "opencode")

    # (1) プロセス検証 + PGID kill（安全チェック付き）
    if [[ -n "$pid" ]] && _validate_pid "$pid" "$_process_pattern"; then
        pgid=$(_get_pgid "$pid")
        if [[ -n "$pgid" ]] && [[ "$pgid" == "$pid" ]]; then
            # PID == PGID: setsid 前提の正常パス → グループ全体に SIGTERM
            kill -- -"$pgid" 2>/dev/null || true
        elif [[ -n "$pgid" ]]; then
            # PID != PGID: 想定外 → 警告ログ + pkill -P フォールバック
            log_warn "_kill_process_tree: PID=$pid と PGID=$pgid が不一致（setsid 前提違反）、pkill -P にフォールバック"
            pkill -P "$pid" 2>/dev/null || true
            kill "$pid" 2>/dev/null || true
        fi
    else
        # _validate_pid 失敗: stale PID → PGID kill せず pkill -P フォールバック
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            pkill -P "$pid" 2>/dev/null || true
            kill "$pid" 2>/dev/null || true
        fi
    fi

    # (2) pkill -P（フォールバック: 子プロセスが残っていれば停止）
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        pkill -P "$pid" 2>/dev/null || true
    fi

    # (3) kill PID（まだ生存していれば個別に SIGTERM）
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
    fi

    # (4) 生存確認ループ（0.5秒 × max_wait 回）
    local attempt=0
    while [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && [[ $attempt -lt $max_wait ]]; do
        sleep 0.5
        attempt=$((attempt + 1))
    done

    # (5) SIGKILL エスカレーション
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        log_warn "プロセス PID=$pid が ${max_wait} 回のチェック後も生存、SIGKILL を送信します"
        pgid=$(_get_pgid "$pid")
        if [[ -n "$pgid" ]] && [[ "$pgid" == "$pid" ]]; then
            kill -9 -- -"$pgid" 2>/dev/null || true
        fi
        pkill -9 -P "$pid" 2>/dev/null || true
        kill -9 "$pid" 2>/dev/null || true
    fi
}

# cli_save_agent_state <pane_idx> <session_id> <agent_name> [runtime_dir]
# ステートファイル群を保存
cli_save_agent_state() {
    local pane_idx="$1"
    local session_id="$2"
    local agent_name="$3"
    local runtime_dir="${4:-$IGNITE_RUNTIME_DIR}"

    local state_dir="${runtime_dir}/state"
    mkdir -p "$state_dir"

    echo "$session_id" > "${state_dir}/.agent_session_${pane_idx}"
    echo "$agent_name" > "${state_dir}/.agent_name_${pane_idx}"
}

# cli_load_agent_state <pane_idx> [runtime_dir]
# ファイルからステートを読み込み → グローバル変数にセット
# _AGENT_SESSION_ID, _AGENT_NAME を設定（_AGENT_PID は後方互換で読み込むが通常は空）
cli_load_agent_state() {
    local pane_idx="$1"
    local runtime_dir="${2:-$IGNITE_RUNTIME_DIR}"
    local state_dir="${runtime_dir}/state"

    _AGENT_SESSION_ID=$(cat "${state_dir}/.agent_session_${pane_idx}" 2>/dev/null || true)
    _AGENT_PID=$(cat "${state_dir}/.agent_pid_${pane_idx}" 2>/dev/null || true)
    _AGENT_NAME=$(cat "${state_dir}/.agent_name_${pane_idx}" 2>/dev/null || true)
}

# cli_cleanup_agent_state <pane_idx> [runtime_dir]
# ステートファイルを削除
cli_cleanup_agent_state() {
    local pane_idx="$1"
    local runtime_dir="${2:-$IGNITE_RUNTIME_DIR}"
    local state_dir="${runtime_dir}/state"

    rm -f "${state_dir}/.agent_pid_${pane_idx}"
    # 後方互換: v0.6.x 以前の port ファイルを削除（将来除去予定）
    rm -f "${state_dir}/.agent_port_${pane_idx}"
    rm -f "${state_dir}/.agent_session_${pane_idx}"
    rm -f "${state_dir}/.agent_name_${pane_idx}"
    rm -f "${state_dir}/.send_lock_${pane_idx}"
}

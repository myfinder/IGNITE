#!/bin/bash
# =============================================================================
# watcher_common.sh — Watcher 共通ライブラリ
#
# カスタム Watcher が共有する責務（デーモン管理、状態管理、MIME構築、
# 入力サニタイズ、シグナルハンドリング）を提供します。
#
# 使い方:
#   source "${SCRIPT_DIR}/../lib/watcher_common.sh"
#   watcher_init "my_watcher" "$config_file"
#   # watcher_poll() を独自定義で上書き
#   watcher_poll() { ... }
#   watcher_run_daemon
#
# カスタム Watcher が実装すべき関数:
#   watcher_poll()     — [poll型] 1サイクル分のイベント取得・処理
#   watcher_on_event() — [push型] イベント受信時のコールバック（Phase 3）
#
# 提供する共通関数:
#   watcher_init()                 — 初期化 + シグナルtrap登録
#   watcher_load_config()          — YAML設定ファイル読み込み
#   watcher_run_daemon()           — メインpollingループ + graceful shutdown
#   watcher_send_mime()            — MIME構築・キュー投入
#   watcher_shutdown()             — グレースフル停止 + PIDファイル削除
#   watcher_init_state()           — 状態管理初期化
#   watcher_is_event_processed()   — イベント重複チェック
#   watcher_mark_event_processed() — イベント処理済みマーク
#   watcher_cleanup_old_events()   — 24h超過イベント削除
#   _watcher_sanitize_input()      — 外部入力サニタイズ
#
# 命名規則:
#   公開関数:   watcher_*
#   内部関数:   _watcher_*
#   グローバル: _WATCHER_*
# =============================================================================

# 多重sourceガード
if [[ -n "${_WATCHER_COMMON_LOADED:-}" ]]; then
    return 0
fi
_WATCHER_COMMON_LOADED=1

# =============================================================================
# 依存ライブラリの読み込み
# =============================================================================

# core.sh が未ロードの場合は読み込む（log_info 等の提供元）
if ! declare -f log_info &>/dev/null; then
    _WATCHER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=core.sh
    source "${_WATCHER_LIB_DIR}/core.sh"
fi

# yaml_utils.sh が未ロードの場合は読み込む
if ! declare -f yaml_get &>/dev/null; then
    _WATCHER_LIB_DIR="${_WATCHER_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
    # shellcheck source=yaml_utils.sh
    source "${_WATCHER_LIB_DIR}/yaml_utils.sh"
fi

# MIMEメッセージ構築ツールのパス
_WATCHER_LIB_DIR="${_WATCHER_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
_WATCHER_MIME_TOOL="${_WATCHER_LIB_DIR}/ignite_mime.py"

# =============================================================================
# グローバル状態（Watcher共通）
# =============================================================================

# Watcher名（watcher_init で設定）
_WATCHER_NAME=""

# 状態ファイルパス（watcher_init_state で設定）
_WATCHER_STATE_FILE=""

# シグナル制御フラグ
_WATCHER_SHUTDOWN_REQUESTED=false
_WATCHER_SHUTDOWN_SIGNAL=""
_WATCHER_EXIT_CODE=0
_WATCHER_RELOAD_REQUESTED=false

# 設定値（watcher_load_config で設定）
_WATCHER_POLL_INTERVAL=60
_WATCHER_CONFIG_FILE=""

# PIDファイルパス
_WATCHER_PID_FILE=""

# =============================================================================
# インターフェース定義（カスタム Watcher が上書きする）
# =============================================================================

# watcher_poll — [poll型] 1サイクル分のイベント取得・処理
# 各 Watcher が shell 関数後定義で上書きすること。
# デフォルトは空実装（何もしない）。
watcher_poll() { :; }

# watcher_on_event — [push型] イベント受信時のコールバック
# Phase 3 で Push型 Watcher（Slack等）用に実装予定。
# 引数:
#   $1 — イベントタイプ
#   $2 — イベントデータ（JSON文字列）
watcher_on_event() { :; }

# =============================================================================
# 初期化
# =============================================================================

# watcher_init — Watcher の初期化 + シグナルtrap登録
# 引数:
#   $1 — Watcher名（例: "github_watcher", "slack_watcher"）
#   $2 — 設定ファイルパス（省略時は IGNITE_CONFIG_DIR/${watcher_name}.yaml）
watcher_init() {
    local watcher_name="$1"
    local config_file="${2:-}"

    _WATCHER_NAME="$watcher_name"

    # 設定ファイルの解決
    if [[ -z "$config_file" ]]; then
        local config_filename
        # watcher名からYAMLファイル名を導出（アンダースコア→ハイフン）
        config_filename="${watcher_name//_/-}.yaml"
        config_file="${IGNITE_CONFIG_DIR}/${config_filename}"
    fi
    _WATCHER_CONFIG_FILE="$config_file"

    # 設定読み込み
    watcher_load_config "$config_file"

    # 状態管理初期化
    watcher_init_state "$watcher_name"

    # PIDファイル作成
    _WATCHER_PID_FILE="${IGNITE_RUNTIME_DIR}/state/${watcher_name}.pid"
    mkdir -p "$(dirname "$_WATCHER_PID_FILE")"
    echo $$ > "$_WATCHER_PID_FILE"

    # シグナルtrap登録
    _watcher_setup_traps

    log_info "[${_WATCHER_NAME}] 初期化完了"
}

# =============================================================================
# 設定読み込み
# =============================================================================

# watcher_load_config — YAML設定ファイルから共通設定を読み込む
# 引数:
#   $1 — 設定ファイルパス
# 設定する変数:
#   _WATCHER_POLL_INTERVAL — ポーリング間隔（秒）
# 注意:
#   Watcher固有の設定は各Watcherが独自に読み込むこと
watcher_load_config() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        log_warn "[${_WATCHER_NAME}] 設定ファイルが見つかりません: $config_file（デフォルト値を使用）"
        return 0
    fi

    # 共通設定: ポーリング間隔
    local interval
    interval=$(yaml_get "$config_file" 'interval')
    _WATCHER_POLL_INTERVAL="${interval:-60}"

    log_info "[${_WATCHER_NAME}] 設定読み込み完了: interval=${_WATCHER_POLL_INTERVAL}s"
}

# =============================================================================
# デーモン管理
# =============================================================================

# watcher_run_daemon — メインpollingループ + graceful shutdown
# github_watcher.sh L1202-1259 ベース
# 各Watcherは事前に watcher_poll() を上書き定義しておくこと
watcher_run_daemon() {
    log_info "[${_WATCHER_NAME}] デーモンを起動します"
    log_info "[${_WATCHER_NAME}] 監視間隔: ${_WATCHER_POLL_INTERVAL}秒"

    while [[ "$_WATCHER_SHUTDOWN_REQUESTED" != true ]]; do
        # セッション/プロセス生存チェック（環境変数が設定されている場合のみ）
        if [[ -n "${IGNITE_SESSION:-}" ]]; then
            local leader_pid
            leader_pid=$(cat "${IGNITE_RUNTIME_DIR}/state/.agent_pid_0" 2>/dev/null || true)
            if [[ -z "$leader_pid" ]] || ! kill -0 "$leader_pid" 2>/dev/null; then
                log_warn "[${_WATCHER_NAME}] Leader プロセスが終了しました。Watcherを終了します"
                exit 0
            fi
        fi

        # poll型: カスタム Watcher の watcher_poll() を呼び出す
        watcher_poll || log_warn "[${_WATCHER_NAME}] watcher_poll failed, continuing..."

        # 定期的に古いイベントをクリーンアップ
        watcher_cleanup_old_events || log_warn "[${_WATCHER_NAME}] cleanup_old_events failed, continuing..."

        # SIGHUP による設定リロード（フラグベース遅延実行）
        if [[ "$_WATCHER_RELOAD_REQUESTED" == true ]]; then
            _WATCHER_RELOAD_REQUESTED=false
            watcher_load_config "$_WATCHER_CONFIG_FILE" || log_warn "[${_WATCHER_NAME}] 設定リロード失敗"
            log_info "[${_WATCHER_NAME}] 設定リロード完了"
        fi

        # sleep分割: SIGTERM応答性改善（最大1秒以内に停止可能）
        local i=0
        while [[ $i -lt $_WATCHER_POLL_INTERVAL ]] && [[ "$_WATCHER_SHUTDOWN_REQUESTED" != true ]]; do
            sleep 1
            i=$((i + 1))
        done
    done

    exit "${_WATCHER_EXIT_CODE:-0}"
}

# watcher_shutdown — グレースフル停止 + PIDファイル削除
# github_watcher.sh L1354-1386 ベース
watcher_shutdown() {
    # PIDファイル削除
    if [[ -n "$_WATCHER_PID_FILE" ]] && [[ -f "$_WATCHER_PID_FILE" ]]; then
        rm -f "$_WATCHER_PID_FILE"
    fi
}

# =============================================================================
# シグナルハンドリング（内部）
# =============================================================================

# _watcher_setup_traps — シグナルtrap登録
_watcher_setup_traps() {
    # SIGHUP: 設定リロード予約
    # trap内で直接 watcher_load_config() を呼ぶと競合のリスクがあるため
    # フラグを立てるだけにしてメインループ内で安全にリロードする
    trap '_watcher_handle_sighup' SIGHUP

    # SIGTERM/SIGINT: グレースフル停止
    # process中のwatcher_poll()完了を待ってから安全に停止する
    trap '_watcher_handle_shutdown 15' SIGTERM
    trap '_watcher_handle_shutdown 2' SIGINT

    # EXIT: 終了処理
    trap '_watcher_handle_exit' EXIT
}

# _watcher_handle_sighup — SIGHUPハンドラ
_watcher_handle_sighup() {
    log_info "[${_WATCHER_NAME}] SIGHUP受信: リロード予約"
    _WATCHER_RELOAD_REQUESTED=true
}

# _watcher_handle_shutdown — SIGTERM/SIGINTハンドラ
# 引数:
#   $1 — シグナル番号
_watcher_handle_shutdown() {
    _WATCHER_SHUTDOWN_SIGNAL="$1"
    _WATCHER_SHUTDOWN_REQUESTED=true
    _WATCHER_EXIT_CODE=$((128 + $1))
    log_info "[${_WATCHER_NAME}] シグナル受信 (${1}): 安全に停止します"
}

# _watcher_handle_exit — EXITハンドラ
_watcher_handle_exit() {
    local exit_code=$?
    [[ $exit_code -eq 0 ]] && exit_code=${_WATCHER_EXIT_CODE:-0}

    # PIDファイル削除
    watcher_shutdown

    if [[ -n "$_WATCHER_SHUTDOWN_SIGNAL" ]]; then
        log_info "[${_WATCHER_NAME}] 終了: シグナル${_WATCHER_SHUTDOWN_SIGNAL}による停止"
    elif [[ $exit_code -eq 0 ]]; then
        log_info "[${_WATCHER_NAME}] 終了: 正常終了"
    elif [[ $exit_code -gt 128 ]]; then
        local sig=$((exit_code - 128))
        log_warn "[${_WATCHER_NAME}] 終了: シグナル${sig}"
    else
        log_error "[${_WATCHER_NAME}] 終了: 異常終了 (exit_code=$exit_code)"
    fi
}

# =============================================================================
# 状態管理
# =============================================================================

# watcher_init_state — 状態ファイルの初期化
# 引数:
#   $1 — Watcher名（状態ファイルのパス決定に使用）
# 状態ファイル: state/{watcher_name}_state.json
watcher_init_state() {
    local watcher_name="$1"

    _WATCHER_STATE_FILE="${IGNITE_RUNTIME_DIR}/state/${watcher_name}_state.json"

    mkdir -p "$(dirname "$_WATCHER_STATE_FILE")"
    if [[ ! -f "$_WATCHER_STATE_FILE" ]]; then
        local now
        now=$(date -Iseconds)
        echo "{\"processed_events\":{},\"last_check\":{},\"initialized_at\":\"$now\"}" > "$_WATCHER_STATE_FILE"
        log_info "[${_WATCHER_NAME}] 新規ステートファイル作成: $now 以降のイベントを監視"
    fi
}

# watcher_is_event_processed — イベントIDが処理済みかチェック
# 引数:
#   $1 — イベントタイプ
#   $2 — イベントID
# 戻り値: 0=処理済み, 1=未処理
watcher_is_event_processed() {
    local event_type="$1"
    local event_id="$2"
    local key="${event_type}_${event_id}"

    jq -e ".processed_events[\"$key\"]" "$_WATCHER_STATE_FILE" > /dev/null 2>&1
}

# watcher_mark_event_processed — イベントIDを処理済みとして記録
# 引数:
#   $1 — イベントタイプ
#   $2 — イベントID
watcher_mark_event_processed() {
    local event_type="$1"
    local event_id="$2"
    local key="${event_type}_${event_id}"
    local timestamp
    timestamp=$(date -Iseconds)

    local tmp_file
    tmp_file=$(mktemp)
    if jq ".processed_events[\"$key\"] = \"$timestamp\"" "$_WATCHER_STATE_FILE" > "$tmp_file"; then
        mv "$tmp_file" "$_WATCHER_STATE_FILE"
    else
        rm -f "$tmp_file"
        log_warn "[${_WATCHER_NAME}] ステートファイル更新失敗: mark_event_processed $key"
    fi
}

# watcher_update_last_check — 最終チェック時刻を更新
# 引数:
#   $1 — チェック対象キー（例: "owner/repo_issues"）
watcher_update_last_check() {
    local check_key="$1"
    local timestamp
    timestamp=$(date -Iseconds)

    local tmp_file
    tmp_file=$(mktemp)
    if jq ".last_check[\"$check_key\"] = \"$timestamp\"" "$_WATCHER_STATE_FILE" > "$tmp_file"; then
        mv "$tmp_file" "$_WATCHER_STATE_FILE"
    else
        rm -f "$tmp_file"
        log_warn "[${_WATCHER_NAME}] ステートファイル更新失敗: update_last_check $check_key"
    fi
}

# watcher_get_last_check — 最終チェック時刻を取得
# 引数:
#   $1 — チェック対象キー
# 戻り値: ISO 8601タイムスタンプ（未チェックの場合は initialized_at）
watcher_get_last_check() {
    local check_key="$1"
    jq -r ".last_check[\"$check_key\"] // .initialized_at // empty" "$_WATCHER_STATE_FILE" 2>/dev/null
}

# watcher_cleanup_old_events — 24時間超過の処理済みイベントを削除
watcher_cleanup_old_events() {
    local cutoff
    cutoff=$(date -d "24 hours ago" -Iseconds 2>/dev/null || date -v-24H -Iseconds 2>/dev/null || echo "")
    if [[ -z "$cutoff" ]]; then
        return 0
    fi

    local tmp_file
    tmp_file=$(mktemp)
    if jq --arg cutoff "$cutoff" '
        .processed_events |= with_entries(select(.value >= $cutoff))
    ' "$_WATCHER_STATE_FILE" > "$tmp_file" 2>/dev/null; then
        mv "$tmp_file" "$_WATCHER_STATE_FILE"
    else
        rm -f "$tmp_file"
    fi
}

# =============================================================================
# MIME メッセージ構築
# =============================================================================

# watcher_send_mime — MIME メッセージを構築してキューに投入
# 引数:
#   $1 — from（送信元 Watcher名）
#   $2 — to（送信先エージェント名、例: "leader"）
#   $3 — type（メッセージタイプ、例: "github_event"）
#   $4 — body_yaml（ボディYAML文字列。生成は呼び出し側の責務）
#   $5 — repo（リポジトリ、例: "owner/repo"）省略可
#   $6 — issue（Issue番号）省略可
# 戻り値: 生成されたMIMEファイルのパス（stdout）
# 注意:
#   ボディYAMLの生成は各Watcher固有の責務。
#   この関数はMIME構築とキュー投入のみを担当する。
watcher_send_mime() {
    local from="$1"
    local to="$2"
    local msg_type="$3"
    local body_yaml="$4"
    local repo="${5:-}"
    local issue="${6:-}"

    local message_id
    message_id=$(date +%s%6N)
    local queue_dir="${IGNITE_RUNTIME_DIR}/queue/${to}"

    mkdir -p "$queue_dir"

    local message_file="${queue_dir}/${from}_${msg_type}_${message_id}.mime"

    # MIME構築引数
    local mime_args=(--from "$from" --to "$to" --type "$msg_type" --priority normal)
    [[ -n "$repo" ]] && mime_args+=(--repo "$repo")
    [[ -n "$issue" ]] && mime_args+=(--issue "$issue")

    if ! python3 "$_WATCHER_MIME_TOOL" build "${mime_args[@]}" --body "$body_yaml" -o "$message_file"; then
        log_error "[${_WATCHER_NAME}] MIMEメッセージ構築失敗: ${msg_type}"
        return 1
    fi

    echo "$message_file"
}

# =============================================================================
# 入力サニタイズ
# =============================================================================

# _watcher_sanitize_input — 外部データのサニタイズ
# github_watcher.sh L52-73 からの移植。
# - 制御文字（\x00-\x1f、\x7f）を除去
# - シェルメタキャラクタを全角に変換（YAML/シェルインジェクション防止）
# - 長さ制限を適用
# 引数:
#   $1 — サニタイズ対象の入力文字列
#   $2 — 最大長（デフォルト: 256）
# 戻り値: サニタイズ済み文字列（stdout）
_watcher_sanitize_input() {
    local input="$1"
    local max_length="${2:-256}"

    # 制御文字を全除去（タブ・改行含む: YAML埋め込み時のインジェクション防止）
    local sanitized
    sanitized=$(printf '%s' "$input" | tr -d '\000-\037\177')

    # シェルメタキャラクタを無害化（全角に置換）
    sanitized="${sanitized//;/；}"
    sanitized="${sanitized//|/｜}"
    sanitized="${sanitized//&/＆}"
    sanitized="${sanitized//\$/＄}"
    sanitized="${sanitized//\`/｀}"
    sanitized="${sanitized//</＜}"
    sanitized="${sanitized//>/＞}"
    sanitized="${sanitized//(/（}"
    sanitized="${sanitized//)/）}"

    # 長さ制限
    echo "${sanitized:0:$max_length}"
}

#!/bin/bash
# =============================================================================
# slack_watcher.sh — Slack チャンネル/メンション監視デーモン
#
# Slack Socket Mode (WebSocket) でリアルタイムにイベントを受信し、
# MIME メッセージとして Leader キューに送信する。
#
# アーキテクチャ:
#   Shell ラッパー + Python subprocess のハイブリッド構成
#   - slack_watcher.py: Socket Mode でブロッキング待機、spool に JSON 書込
#   - slack_watcher.sh: spool ポーリング → サニタイズ → MIME 構築 → キュー投入
#
# 使い方:
#   ./scripts/utils/slack_watcher.sh [オプション]
#
# オプション:
#   -d, --daemon    デーモンモードで起動（デフォルト）
#   -c, --config    設定ファイルを指定
#   -h, --help      このヘルプを表示
# =============================================================================

set -e
set -u

# スクリプトのディレクトリを取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/core.sh"
source "${SCRIPT_DIR}/../lib/cli_provider.sh"
# core.sh が SCRIPT_DIR を上書きするため再設定
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# WORKSPACE_DIR が未設定の場合、IGNITE_WORKSPACE_DIR からフォールバック
WORKSPACE_DIR="${WORKSPACE_DIR:-${IGNITE_WORKSPACE_DIR:-}}"
[[ -n "${WORKSPACE_DIR:-}" ]] && setup_workspace_config "$WORKSPACE_DIR"
cli_load_config 2>/dev/null || true

# YAMLユーティリティ
source "${SCRIPT_DIR}/../lib/yaml_utils.sh"

# Watcher共通ライブラリ
source "${SCRIPT_DIR}/../lib/watcher_common.sh"

# =============================================================================
# 定数・デフォルト設定
# =============================================================================

SLACK_SPOOL_DIR="${IGNITE_RUNTIME_DIR}/tmp/slack_events"
SLACK_VENV_DIR="${IGNITE_RUNTIME_DIR}/venv"
SLACK_REQUIREMENTS="${SCRIPT_DIR}/slack_requirements.txt"
SLACK_PYTHON_SCRIPT="${SCRIPT_DIR}/slack_watcher.py"

# Python 子プロセスの PID
_SLACK_PYTHON_PID=""

# Python 再起動制御
_SLACK_PYTHON_RESTART_COUNT=0
_SLACK_PYTHON_RESTART_MAX=5
_SLACK_PYTHON_LAST_START=0

# ハートビート設定
WATCHER_HEARTBEAT_FILE="${IGNITE_RUNTIME_DIR:-}/state/slack_watcher_heartbeat.json"

# Slack 固有設定（load_slack_config で設定）
SLACK_TASK_KEYWORDS=()
SLACK_ACCESS_CONTROL_ENABLED="false"
SLACK_ALLOWED_USERS=()
SLACK_ALLOWED_CHANNELS=()

# =============================================================================
# ログヘルパー
# =============================================================================

log_event() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${CYAN:-}[EVENT]${NC:-} $1" >&2; }

# =============================================================================
# 設定読み込み（Slack 固有）
# =============================================================================

load_slack_config() {
    local config_file="${1:-${_WATCHER_CONFIG_FILE:-}}"
    if [[ -z "$config_file" || ! -f "$config_file" ]]; then
        log_warn "[slack_watcher] 設定ファイルが見つかりません: ${config_file:-未指定}"
        return 0
    fi

    # task_keywords の読み込み
    SLACK_TASK_KEYWORDS=()
    local keywords_raw
    keywords_raw=$(yaml_get "$config_file" 'triggers.task_keywords[]' 2>/dev/null || true)
    if [[ -n "$keywords_raw" ]]; then
        while IFS= read -r kw; do
            [[ -n "$kw" ]] && SLACK_TASK_KEYWORDS+=("$kw")
        done <<< "$keywords_raw"
    fi

    # デフォルトキーワード（設定がない場合）
    if [[ ${#SLACK_TASK_KEYWORDS[@]} -eq 0 ]]; then
        SLACK_TASK_KEYWORDS=(
            "実装して" "修正して" "implement" "fix"
            "レビューして" "review"
            "教えて" "調べて" "説明して" "どうすれば" "なぜ"
            "explain" "how to" "why" "what is"
        )
    fi

    # access_control の読み込み
    SLACK_ACCESS_CONTROL_ENABLED=$(yaml_get "$config_file" 'access_control.enabled' 2>/dev/null || echo "false")

    SLACK_ALLOWED_USERS=()
    local users_raw
    users_raw=$(yaml_get "$config_file" 'access_control.allowed_users[]' 2>/dev/null || true)
    if [[ -n "$users_raw" ]]; then
        while IFS= read -r u; do
            [[ -n "$u" ]] && SLACK_ALLOWED_USERS+=("$u")
        done <<< "$users_raw"
    fi

    SLACK_ALLOWED_CHANNELS=()
    local channels_raw
    channels_raw=$(yaml_get "$config_file" 'access_control.allowed_channels[]' 2>/dev/null || true)
    if [[ -n "$channels_raw" ]]; then
        while IFS= read -r c; do
            [[ -n "$c" ]] && SLACK_ALLOWED_CHANNELS+=("$c")
        done <<< "$channels_raw"
    fi

    log_info "[slack_watcher] 設定読み込み完了: task_keywords=${#SLACK_TASK_KEYWORDS[@]}件, access_control=${SLACK_ACCESS_CONTROL_ENABLED}"
}

# =============================================================================
# Python venv 管理
# =============================================================================

# setup_venv — Python 仮想環境のセットアップ
# 初回起動時に venv を作成し、slack-bolt をインストール
setup_venv() {
    # Python3 チェック
    if ! command -v python3 &>/dev/null; then
        log_error "[slack_watcher] python3 が見つかりません。Slack Watcher には python3 が必要です"
        return 1
    fi

    # venv が既に存在する場合はキャッシュ判定
    if [[ -f "${SLACK_VENV_DIR}/bin/python3" ]]; then
        # requirements.txt のハッシュで変更を検出
        local req_hash=""
        local cached_hash=""
        if [[ -f "$SLACK_REQUIREMENTS" ]]; then
            # md5sum (Linux) / md5 (macOS) フォールバック
            req_hash=$(md5sum "$SLACK_REQUIREMENTS" 2>/dev/null | cut -d' ' -f1 \
                    || md5 -q "$SLACK_REQUIREMENTS" 2>/dev/null || true)
        fi
        if [[ -f "${SLACK_VENV_DIR}/.requirements_hash" ]]; then
            cached_hash=$(cat "${SLACK_VENV_DIR}/.requirements_hash" 2>/dev/null || true)
        fi
        if [[ -n "$req_hash" && "$req_hash" == "$cached_hash" ]]; then
            # ハッシュ一致でも実際にパッケージがインポートできるか検証
            if "${SLACK_VENV_DIR}/bin/python3" -c "import slack_bolt" 2>/dev/null; then
                log_info "[slack_watcher] venv キャッシュ済み、セットアップスキップ"
                return 0
            fi
            log_warn "[slack_watcher] venv が壊れています（slack_bolt インポート失敗）。再作成します"
        fi
    fi

    # 壊れた venv が残っている場合は削除してクリーンに再作成
    if [[ -d "$SLACK_VENV_DIR" ]]; then
        log_info "[slack_watcher] 既存の venv を削除して再作成します"
        rm -rf "$SLACK_VENV_DIR"
    fi

    log_info "[slack_watcher] Python venv をセットアップ中..."
    mkdir -p "$(dirname "$SLACK_VENV_DIR")"

    # venv 作成（python3-venv が必要）
    if ! python3 -m venv "$SLACK_VENV_DIR"; then
        log_error "[slack_watcher] venv 作成に失敗しました。python3-venv をインストールしてください: sudo apt install python3-venv"
        return 1
    fi

    # パッケージインストール
    if [[ -f "$SLACK_REQUIREMENTS" ]]; then
        if ! "${SLACK_VENV_DIR}/bin/pip" install -q -r "$SLACK_REQUIREMENTS"; then
            log_error "[slack_watcher] パッケージインストールに失敗しました"
            return 1
        fi
        # ハッシュをキャッシュ（md5sum / md5 フォールバック）
        { md5sum "$SLACK_REQUIREMENTS" 2>/dev/null | cut -d' ' -f1 \
          || md5 -q "$SLACK_REQUIREMENTS" 2>/dev/null; } > "${SLACK_VENV_DIR}/.requirements_hash" 2>/dev/null || true
    fi

    log_info "[slack_watcher] venv セットアップ完了: ${SLACK_VENV_DIR}"
}

# =============================================================================
# トークン検証
# =============================================================================

# validate_tokens — .ignite/.env からトークンを読み込み、検証
validate_tokens() {
    local env_file="${IGNITE_RUNTIME_DIR}/.env"

    # .env ファイルが存在する場合は読み込む
    if [[ -f "$env_file" ]]; then
        # セキュリティ: 変数名を制限してサニタイズ
        while IFS='=' read -r key value; do
            # コメント・空行をスキップ
            [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
            # SLACK_ プレフィックスのみ許可
            key=$(echo "$key" | tr -d '[:space:]')
            value=$(echo "$value" | sed 's/^["'"'"']//;s/["'"'"']$//')
            case "$key" in
                SLACK_TOKEN|SLACK_APP_TOKEN)
                    export "$key=$value"
                    ;;
            esac
        done < "$env_file"
    fi

    # トークン検証
    if [[ -z "${SLACK_TOKEN:-}" ]]; then
        log_error "[slack_watcher] SLACK_TOKEN が設定されていません"
        log_error "[slack_watcher] ${env_file} に SLACK_TOKEN=xoxb-... または xoxp-... を設定してください"
        return 1
    fi
    if [[ -z "${SLACK_APP_TOKEN:-}" ]]; then
        log_error "[slack_watcher] SLACK_APP_TOKEN が設定されていません"
        log_error "[slack_watcher] ${env_file} に SLACK_APP_TOKEN=xapp-... を設定してください"
        return 1
    fi
    if [[ ! "${SLACK_APP_TOKEN}" =~ ^xapp- ]]; then
        log_error "[slack_watcher] SLACK_APP_TOKEN は xapp- で始まる必要があります（Socket Mode トークン）"
        return 1
    fi

    log_info "[slack_watcher] トークン検証完了"
}

# =============================================================================
# Python 子プロセス管理
# =============================================================================

# start_python_receiver — Python Socket Mode レシーバーを起動
start_python_receiver() {
    mkdir -p "$SLACK_SPOOL_DIR"

    local python_bin="${SLACK_VENV_DIR}/bin/python3"
    local py_args=(
        "$SLACK_PYTHON_SCRIPT"
        --spool-dir "$SLACK_SPOOL_DIR"
    )
    if [[ -n "${_WATCHER_CONFIG_FILE:-}" && -f "${_WATCHER_CONFIG_FILE:-}" ]]; then
        py_args+=(--config "$_WATCHER_CONFIG_FILE")
    fi

    "$python_bin" "${py_args[@]}" &
    _SLACK_PYTHON_PID=$!

    log_info "[slack_watcher] Python レシーバー起動: PID=${_SLACK_PYTHON_PID}"
}

# stop_python_receiver — Python 子プロセスを停止
stop_python_receiver() {
    if [[ -n "$_SLACK_PYTHON_PID" ]] && kill -0 "$_SLACK_PYTHON_PID" 2>/dev/null; then
        log_info "[slack_watcher] Python レシーバー停止中: PID=${_SLACK_PYTHON_PID}"
        kill -TERM "$_SLACK_PYTHON_PID" 2>/dev/null || true
        # 最大5秒待機
        local wait_count=0
        while kill -0 "$_SLACK_PYTHON_PID" 2>/dev/null && [[ $wait_count -lt 5 ]]; do
            sleep 1
            wait_count=$((wait_count + 1))
        done
        # まだ生きていれば SIGKILL
        if kill -0 "$_SLACK_PYTHON_PID" 2>/dev/null; then
            kill -KILL "$_SLACK_PYTHON_PID" 2>/dev/null || true
            log_warn "[slack_watcher] Python レシーバーを強制停止しました"
        fi
        _SLACK_PYTHON_PID=""
    fi
}

# check_python_health — Python プロセスの生存確認、死亡時は再起動（バックオフ付き）
check_python_health() {
    if [[ -n "$_SLACK_PYTHON_PID" ]] && kill -0 "$_SLACK_PYTHON_PID" 2>/dev/null; then
        # プロセス生存中 — 60秒以上安定稼働したらカウンタリセット
        local now
        now=$(date +%s)
        if (( now - _SLACK_PYTHON_LAST_START > 60 )); then
            _SLACK_PYTHON_RESTART_COUNT=0
        fi
        return 0
    fi

    # 再起動上限チェック
    if (( _SLACK_PYTHON_RESTART_COUNT >= _SLACK_PYTHON_RESTART_MAX )); then
        log_error "[slack_watcher] Python レシーバーの再起動上限 (${_SLACK_PYTHON_RESTART_MAX}回) に達しました。停止します"
        _WATCHER_SHUTDOWN_REQUESTED=true
        return 1
    fi

    _SLACK_PYTHON_RESTART_COUNT=$((_SLACK_PYTHON_RESTART_COUNT + 1))
    log_warn "[slack_watcher] Python レシーバーが停止しています。再起動します (${_SLACK_PYTHON_RESTART_COUNT}/${_SLACK_PYTHON_RESTART_MAX})..."
    _SLACK_PYTHON_LAST_START=$(date +%s)
    start_python_receiver
}

# =============================================================================
# アクセス制御
# =============================================================================

# is_slack_user_authorized — ユーザーがタスクをトリガーする権限があるかチェック
is_slack_user_authorized() {
    local user_id="$1"

    # アクセス制御が無効の場合は全員許可
    if [[ "$SLACK_ACCESS_CONTROL_ENABLED" != "true" ]]; then
        return 0
    fi

    # 許可リストが空の場合は全員許可（設定ミス防止）
    if [[ ${#SLACK_ALLOWED_USERS[@]} -eq 0 ]]; then
        return 0
    fi

    local allowed
    for allowed in "${SLACK_ALLOWED_USERS[@]}"; do
        if [[ "$user_id" == "$allowed" ]]; then
            return 0
        fi
    done

    log_warn "[slack_watcher] 未承認ユーザー: ${user_id}"
    return 1
}

# is_slack_channel_authorized — チャンネルが許可されているかチェック
is_slack_channel_authorized() {
    local channel_id="$1"

    # アクセス制御が無効の場合は全チャンネル許可
    if [[ "$SLACK_ACCESS_CONTROL_ENABLED" != "true" ]]; then
        return 0
    fi

    # 許可リストが空の場合は全チャンネル許可
    if [[ ${#SLACK_ALLOWED_CHANNELS[@]} -eq 0 ]]; then
        return 0
    fi

    local allowed
    for allowed in "${SLACK_ALLOWED_CHANNELS[@]}"; do
        if [[ "$channel_id" == "$allowed" ]]; then
            return 0
        fi
    done

    log_warn "[slack_watcher] 未承認チャンネル: ${channel_id}"
    return 1
}

# =============================================================================
# タスクキーワード検出
# =============================================================================

# has_task_keyword — テキストにタスクキーワードが含まれるかチェック
# 戻り値: 0=含まれる, 1=含まれない
has_task_keyword() {
    local text="$1"
    local text_lower
    text_lower=$(echo "$text" | tr '[:upper:]' '[:lower:]')

    local keyword
    for keyword in "${SLACK_TASK_KEYWORDS[@]}"; do
        local kw_lower
        kw_lower=$(echo "$keyword" | tr '[:upper:]' '[:lower:]')
        if [[ "$text_lower" == *"$kw_lower"* ]]; then
            return 0
        fi
    done

    return 1
}

# =============================================================================
# spool 処理 → MIME 構築
# =============================================================================

# process_spool_events — spool ディレクトリからイベントを読み取り MIME 構築
process_spool_events() {
    # spool ディレクトリが存在しない場合はスキップ
    [[ -d "$SLACK_SPOOL_DIR" ]] || return 0

    local event_files
    event_files=$(find "$SLACK_SPOOL_DIR" -name "slack_event_*.json" -type f 2>/dev/null | sort)
    [[ -z "$event_files" ]] && return 0

    local count=0
    while IFS= read -r event_file; do
        [[ -f "$event_file" ]] || continue

        # JSON 読み取り
        local event_json
        event_json=$(cat "$event_file" 2>/dev/null) || continue
        if [[ -z "$event_json" ]]; then
            rm -f "$event_file"
            continue
        fi

        # JSON バリデーション + フィールド抽出
        local event_type event_ts channel_id user_id text thread_ts
        if ! event_type=$(echo "$event_json" | jq -r '.event_type // ""' 2>/dev/null); then
            log_warn "[slack_watcher] 不正な JSON をスキップ: ${event_file}"
            rm -f "$event_file"
            continue
        fi
        event_ts=$(echo "$event_json" | jq -r '.event_ts // ""')
        channel_id=$(echo "$event_json" | jq -r '.channel_id // ""')
        user_id=$(echo "$event_json" | jq -r '.user_id // ""')
        text=$(echo "$event_json" | jq -r '.text // ""')
        thread_ts=$(echo "$event_json" | jq -r '.thread_ts // ""')

        # 重複チェック（watcher_common.sh の状態管理）
        if watcher_is_event_processed "$event_type" "$event_ts"; then
            log_info "[slack_watcher] 重複イベントをスキップ: ${event_type}_${event_ts}"
            rm -f "$event_file"
            continue
        fi

        # アクセス制御チェック
        if ! is_slack_user_authorized "$user_id"; then
            rm -f "$event_file"
            continue
        fi
        if ! is_slack_channel_authorized "$channel_id"; then
            rm -f "$event_file"
            continue
        fi

        # サニタイズ（全フィールド。spool JSON は Python 経由だが防御的にサニタイズ）
        local safe_text safe_user safe_channel safe_event_type safe_thread_ts safe_event_ts
        safe_text=$(_watcher_sanitize_input "$text" 1024)
        safe_user=$(_watcher_sanitize_input "$user_id" 64)
        safe_channel=$(_watcher_sanitize_input "$channel_id" 64)
        safe_event_type=$(_watcher_sanitize_input "$event_type" 64)
        safe_thread_ts=$(_watcher_sanitize_input "$thread_ts" 64)
        safe_event_ts=$(_watcher_sanitize_input "$event_ts" 64)

        # メッセージタイプ判定: タスクキーワードがあれば slack_task、なければ slack_event
        # 注意: サニタイズ前の $text を使用（サニタイズ後は全角変換でキーワードマッチしなくなるため）
        local msg_type="slack_event"
        if has_task_keyword "$text"; then
            msg_type="slack_task"
        fi

        # thread_messages → thread_context YAML 変換
        local thread_context=""
        local thread_messages_json
        thread_messages_json=$(echo "$event_json" | jq -c '.thread_messages // []' 2>/dev/null)
        if [[ -n "$thread_messages_json" && "$thread_messages_json" != "[]" && "$thread_messages_json" != "null" ]]; then
            thread_context=$(echo "$thread_messages_json" | jq -r '
                .[] | "  - user: \"" + (.user // "") + "\"\n    text: \"" + ((.text // "") | gsub("\n"; "\\n") | gsub("\""; "\\\"")) + "\"\n    ts: \"" + (.ts // "") + "\""
            ' 2>/dev/null || true)
        fi

        # MIME ボディ YAML 構築
        local body_yaml
        if [[ -n "$thread_context" ]]; then
            body_yaml=$(cat <<YAML
event_type: "${safe_event_type}"
channel_id: "${safe_channel}"
user_id: "${safe_user}"
text: "${safe_text}"
thread_ts: "${safe_thread_ts}"
event_ts: "${safe_event_ts}"
source: "slack_watcher"
thread_context:
${thread_context}
YAML
)
        else
            body_yaml=$(cat <<YAML
event_type: "${safe_event_type}"
channel_id: "${safe_channel}"
user_id: "${safe_user}"
text: "${safe_text}"
thread_ts: "${safe_thread_ts}"
event_ts: "${safe_event_ts}"
source: "slack_watcher"
thread_context: ""
YAML
)
        fi

        # MIME 送信（slack_task は priority: high）
        local priority="normal"
        [[ "$msg_type" == "slack_task" ]] && priority="high"
        local mime_file
        if mime_file=$(watcher_send_mime "slack_watcher" "leader" "$msg_type" "$body_yaml" "" "" "$priority"); then
            log_event "Sent ${msg_type}: channel=${safe_channel} user=${safe_user} → ${mime_file}"
            watcher_mark_event_processed "$event_type" "$event_ts"
            count=$((count + 1))
            # 成功時のみ spool ファイル削除
            rm -f "$event_file"
        else
            # 失敗時は spool に残す（次サイクルでリトライ）
            log_warn "[slack_watcher] MIME 送信失敗: ${event_type}_${event_ts}（次サイクルでリトライ）"
        fi

    done <<< "$event_files"

    if [[ $count -gt 0 ]]; then
        log_info "[slack_watcher] ${count} 件のイベントを処理しました"
    fi
}

# =============================================================================
# ハートビート
# =============================================================================

_write_slack_heartbeat() {
    [[ -z "${IGNITE_RUNTIME_DIR:-}" ]] && return 0

    local state_dir="${IGNITE_RUNTIME_DIR}/state"
    mkdir -p "$state_dir" 2>/dev/null || true

    WATCHER_HEARTBEAT_FILE="${state_dir}/slack_watcher_heartbeat.json"

    local timestamp
    timestamp=$(date -Iseconds)

    local python_status="running"
    if [[ -z "$_SLACK_PYTHON_PID" ]] || ! kill -0 "$_SLACK_PYTHON_PID" 2>/dev/null; then
        python_status="stopped"
    fi

    local tmp_file
    tmp_file=$(mktemp "${state_dir}/.watcher_heartbeat.XXXXXX") || return 0
    printf '{"timestamp":"%s","resume_token":"","session":"%s","python_pid":"%s","python_status":"%s"}\n' \
        "$timestamp" "${IGNITE_SESSION:-}" "${_SLACK_PYTHON_PID:-}" "$python_status" \
        > "$tmp_file"
    mv "$tmp_file" "$WATCHER_HEARTBEAT_FILE" 2>/dev/null || rm -f "$tmp_file"
}

# =============================================================================
# watcher_common.sh オーバーライド
# =============================================================================

# watcher_poll — spool ディレクトリからイベントを読み取り処理
watcher_poll() {
    # Python プロセスのヘルスチェック
    check_python_health

    # spool からイベント処理
    process_spool_events
}

# watcher_heartbeat — ハートビート書込
watcher_heartbeat() {
    _write_slack_heartbeat
}

# =============================================================================
# シャットダウン
# =============================================================================

# EXIT ハンドラの拡張（Python 子プロセスの停止）
_slack_watcher_cleanup() {
    stop_python_receiver
    # spool ディレクトリの .tmp ファイルを掃除
    find "$SLACK_SPOOL_DIR" -name "*.tmp" -delete 2>/dev/null || true
}

# =============================================================================
# ヘルプ
# =============================================================================

show_help() {
    cat << 'EOF'
Slack チャンネル/メンション監視デーモン

使用方法:
  ./scripts/utils/slack_watcher.sh [オプション]

オプション:
  -d, --daemon    デーモンモードで起動（デフォルト）
  -c, --config    設定ファイルを指定
  -h, --help      このヘルプを表示

環境変数:
  SLACK_TOKEN              Slack Token (Bot: xoxb-... / User: xoxp-...)
  SLACK_APP_TOKEN          Slack App-Level Token (xapp-...)
  IGNITE_WATCHER_CONFIG    設定ファイルのパス

トークン設定:
  .ignite/.env に以下を設定:
    SLACK_TOKEN=xoxb-...    # Bot Token または xoxp-... (User Token)
    SLACK_APP_TOKEN=xapp-...

使用例:
  # デーモンモードで起動
  ./scripts/utils/slack_watcher.sh

  # バックグラウンドで起動
  ./scripts/utils/slack_watcher.sh &

  # 設定ファイルを指定
  ./scripts/utils/slack_watcher.sh -c /path/to/slack-watcher.yaml

設定ファイル:
  config/slack-watcher.yaml を編集して監視対象イベントを設定してください。
  詳細は docs/slack-watcher.md を参照してください。
EOF
}

# =============================================================================
# メイン
# =============================================================================

main() {
    local config_file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--daemon)
                shift
                ;;
            -c|--config)
                config_file="$2"
                export IGNITE_WATCHER_CONFIG="$config_file"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    # watcher_common.sh の初期化
    watcher_init "slack_watcher" "${config_file:-}"

    # Slack 固有設定の読み込み
    load_slack_config "$_WATCHER_CONFIG_FILE"

    # トークン検証
    if ! validate_tokens; then
        log_error "[slack_watcher] トークン検証失敗。終了します"
        exit 1
    fi

    # Python venv セットアップ
    if ! setup_venv; then
        log_error "[slack_watcher] Python 環境のセットアップに失敗しました。終了します"
        exit 1
    fi

    # 二重起動防止ロック
    if [[ -n "${IGNITE_RUNTIME_DIR:-}" ]]; then
        mkdir -p "${IGNITE_RUNTIME_DIR}/state" 2>/dev/null || true
        local lock_file="${IGNITE_RUNTIME_DIR}/state/slack_watcher.lock"
        exec 9>"$lock_file"
        if ! flock -n 9; then
            log_warn "[slack_watcher] slack_watcher は既に稼働中です（flock取得失敗）"
            exit 1
        fi
    fi

    # Python レシーバー起動
    start_python_receiver

    # EXIT トラップ拡張（Python 子プロセスの停止）
    trap '_slack_watcher_cleanup; _watcher_handle_exit' EXIT

    log_info "[slack_watcher] Slack Watcher を起動します"
    log_info "[slack_watcher] spool ディレクトリ: ${SLACK_SPOOL_DIR}"
    log_info "[slack_watcher] 監視間隔: ${_WATCHER_POLL_INTERVAL}秒"

    # watcher_common.sh のデーモンループに委譲
    watcher_run_daemon
}

main "$@"

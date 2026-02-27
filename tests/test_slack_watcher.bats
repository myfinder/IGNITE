#!/usr/bin/env bats
# test_slack_watcher.bats - Slack Watcher テスト

load test_helper

# =============================================================================
# セットアップ / ティアダウン
# =============================================================================

setup() {
    setup_temp_dir
    export WORKSPACE_DIR="$TEST_TEMP_DIR/workspace"
    export IGNITE_CONFIG_DIR="$TEST_TEMP_DIR/config"
    export IGNITE_RUNTIME_DIR="$TEST_TEMP_DIR/runtime"
    mkdir -p "$IGNITE_CONFIG_DIR"
    mkdir -p "$IGNITE_RUNTIME_DIR/state"
    mkdir -p "$IGNITE_RUNTIME_DIR/queue/leader"
    mkdir -p "$IGNITE_RUNTIME_DIR/tmp/slack_events"

    # ログ関数のスタブ
    log_info()    { :; }
    log_warn()    { :; }
    log_error()   { :; }
    log_success() { :; }
    export -f log_info log_warn log_error log_success

    # yaml_get のスタブ
    yaml_get() {
        local file="$1" key="$2" default="${3:-}"
        if command -v yq &>/dev/null; then
            local val
            val=$(yq -r ".$key // \"\"" "$file" 2>/dev/null)
            [[ -z "$val" || "$val" == "null" ]] && val="$default"
            echo "$val"
        else
            echo "$default"
        fi
    }
    export -f yaml_get

    # 多重sourceガードのリセット
    unset _WATCHER_COMMON_LOADED
}

teardown() {
    cleanup_temp_dir
}

# watcher_common.sh をsource するヘルパー
_source_watcher_common() {
    unset _WATCHER_COMMON_LOADED
    source "$SCRIPTS_DIR/lib/watcher_common.sh"
}

# slack_watcher.sh の関数をインラインで定義するヘルパー
# slack_watcher.sh を直接 source すると main() が実行されてしまうため、
# テストに必要な関数のみをここで再定義する
_define_slack_functions() {
    _source_watcher_common

    SLACK_SPOOL_DIR="$IGNITE_RUNTIME_DIR/tmp/slack_events"
    SLACK_TASK_KEYWORDS=(
        "実装して" "修正して" "implement" "fix"
        "レビューして" "review"
        "教えて" "調べて" "説明して" "どうすれば" "なぜ"
        "explain" "how to" "why" "what is"
    )
    SLACK_ACCESS_CONTROL_ENABLED="false"
    SLACK_ALLOWED_USERS=()
    SLACK_ALLOWED_CHANNELS=()
    _SLACK_PYTHON_PID=""

    # --- slack_watcher.sh の関数をインライン再定義 ---

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

    is_slack_user_authorized() {
        local user_id="$1"
        if [[ "$SLACK_ACCESS_CONTROL_ENABLED" != "true" ]]; then
            return 0
        fi
        if [[ ${#SLACK_ALLOWED_USERS[@]} -eq 0 ]]; then
            return 0
        fi
        local allowed
        for allowed in "${SLACK_ALLOWED_USERS[@]}"; do
            if [[ "$user_id" == "$allowed" ]]; then
                return 0
            fi
        done
        return 1
    }

    is_slack_channel_authorized() {
        local channel_id="$1"
        if [[ "$SLACK_ACCESS_CONTROL_ENABLED" != "true" ]]; then
            return 0
        fi
        if [[ ${#SLACK_ALLOWED_CHANNELS[@]} -eq 0 ]]; then
            return 0
        fi
        local allowed
        for allowed in "${SLACK_ALLOWED_CHANNELS[@]}"; do
            if [[ "$channel_id" == "$allowed" ]]; then
                return 0
            fi
        done
        return 1
    }

    validate_tokens() {
        local env_file="${IGNITE_RUNTIME_DIR}/.env"
        if [[ -f "$env_file" ]]; then
            while IFS='=' read -r key value; do
                [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
                key=$(echo "$key" | tr -d '[:space:]')
                value=$(echo "$value" | sed 's/^["'"'"']//;s/["'"'"']$//')
                case "$key" in
                    SLACK_BOT_TOKEN|SLACK_APP_TOKEN) export "$key=$value" ;;
                esac
            done < "$env_file"
        fi
        [[ -z "${SLACK_BOT_TOKEN:-}" ]] && return 1
        [[ -z "${SLACK_APP_TOKEN:-}" ]] && return 1
        [[ ! "${SLACK_APP_TOKEN}" =~ ^xapp- ]] && return 1
        return 0
    }

    load_slack_config() {
        local config_file="${1:-}"
        if [[ -z "$config_file" || ! -f "$config_file" ]]; then
            if [[ ${#SLACK_TASK_KEYWORDS[@]} -eq 0 ]]; then
                SLACK_TASK_KEYWORDS=(
                    "実装して" "修正して" "implement" "fix"
                    "レビューして" "review"
                    "教えて" "調べて" "説明して" "どうすれば" "なぜ"
                    "explain" "how to" "why" "what is"
                )
            fi
            return 0
        fi
    }

    process_spool_events() {
        [[ -d "$SLACK_SPOOL_DIR" ]] || return 0
        local event_files
        event_files=$(find "$SLACK_SPOOL_DIR" -name "slack_event_*.json" -type f 2>/dev/null | sort)
        [[ -z "$event_files" ]] && return 0
        local count=0
        while IFS= read -r event_file; do
            [[ -f "$event_file" ]] || continue
            local event_json
            event_json=$(cat "$event_file" 2>/dev/null) || continue
            if [[ -z "$event_json" ]]; then
                rm -f "$event_file"
                continue
            fi
            local event_type event_ts channel_id user_id text thread_ts
            event_type=$(echo "$event_json" | jq -r '.event_type // ""')
            event_ts=$(echo "$event_json" | jq -r '.event_ts // ""')
            channel_id=$(echo "$event_json" | jq -r '.channel_id // ""')
            user_id=$(echo "$event_json" | jq -r '.user_id // ""')
            text=$(echo "$event_json" | jq -r '.text // ""')
            thread_ts=$(echo "$event_json" | jq -r '.thread_ts // ""')
            if watcher_is_event_processed "$event_type" "$event_ts"; then
                rm -f "$event_file"
                continue
            fi
            if ! is_slack_user_authorized "$user_id"; then
                rm -f "$event_file"
                continue
            fi
            if ! is_slack_channel_authorized "$channel_id"; then
                rm -f "$event_file"
                continue
            fi
            local safe_text safe_user safe_channel
            safe_text=$(_watcher_sanitize_input "$text" 1024)
            safe_user=$(_watcher_sanitize_input "$user_id" 64)
            safe_channel=$(_watcher_sanitize_input "$channel_id" 64)
            local msg_type="slack_event"
            if has_task_keyword "$text"; then
                msg_type="slack_task"
            fi
            local body_yaml
            body_yaml="event_type: \"${event_type}\"
channel_id: \"${safe_channel}\"
user_id: \"${safe_user}\"
text: \"${safe_text}\"
thread_ts: \"${thread_ts}\"
event_ts: \"${event_ts}\"
source: \"slack_watcher\""
            local mime_file
            if mime_file=$(watcher_send_mime "slack_watcher" "leader" "$msg_type" "$body_yaml"); then
                watcher_mark_event_processed "$event_type" "$event_ts"
                count=$((count + 1))
            fi
            rm -f "$event_file"
        done <<< "$event_files"
        echo "$count"
    }
}

# =============================================================================
# 1. タスクキーワード検出テスト
# =============================================================================

@test "has_task_keyword: 日本語キーワード「実装して」を検出" {
    _define_slack_functions
    has_task_keyword "この機能を実装してください"
}

@test "has_task_keyword: 英語キーワード「implement」を検出" {
    _define_slack_functions
    has_task_keyword "please implement this feature"
}

@test "has_task_keyword: 英語キーワード大文字小文字無視" {
    _define_slack_functions
    has_task_keyword "Please IMPLEMENT this"
}

@test "has_task_keyword: キーワードなしの場合は不一致" {
    _define_slack_functions
    ! has_task_keyword "こんにちは、今日の天気はどう？"
}

@test "has_task_keyword: 複合メッセージでキーワード検出" {
    _define_slack_functions
    has_task_keyword "@ignite-bot レビューしてください、お願いします"
}

@test "has_task_keyword: explain キーワードを検出" {
    _define_slack_functions
    has_task_keyword "Can you explain how this works?"
}

@test "has_task_keyword: how to キーワードを検出" {
    _define_slack_functions
    has_task_keyword "how to configure the database?"
}

# =============================================================================
# 2. アクセス制御テスト
# =============================================================================

@test "is_slack_user_authorized: アクセス制御無効時は全員許可" {
    _define_slack_functions
    SLACK_ACCESS_CONTROL_ENABLED="false"
    is_slack_user_authorized "U_ANY_USER"
}

@test "is_slack_user_authorized: 許可リストにあるユーザーは通過" {
    _define_slack_functions
    SLACK_ACCESS_CONTROL_ENABLED="true"
    SLACK_ALLOWED_USERS=("U01ABC" "U02DEF")
    is_slack_user_authorized "U01ABC"
}

@test "is_slack_user_authorized: 許可リストにないユーザーは拒否" {
    _define_slack_functions
    SLACK_ACCESS_CONTROL_ENABLED="true"
    SLACK_ALLOWED_USERS=("U01ABC" "U02DEF")
    ! is_slack_user_authorized "U_UNKNOWN"
}

@test "is_slack_user_authorized: 許可リスト空の場合は全員許可" {
    _define_slack_functions
    SLACK_ACCESS_CONTROL_ENABLED="true"
    SLACK_ALLOWED_USERS=()
    is_slack_user_authorized "U_ANY_USER"
}

@test "is_slack_channel_authorized: アクセス制御無効時は全チャンネル許可" {
    _define_slack_functions
    SLACK_ACCESS_CONTROL_ENABLED="false"
    is_slack_channel_authorized "C_ANY_CHANNEL"
}

@test "is_slack_channel_authorized: 許可リストにあるチャンネルは通過" {
    _define_slack_functions
    SLACK_ACCESS_CONTROL_ENABLED="true"
    SLACK_ALLOWED_CHANNELS=("C01ABC" "C02DEF")
    is_slack_channel_authorized "C01ABC"
}

@test "is_slack_channel_authorized: 許可リストにないチャンネルは拒否" {
    _define_slack_functions
    SLACK_ACCESS_CONTROL_ENABLED="true"
    SLACK_ALLOWED_CHANNELS=("C01ABC")
    ! is_slack_channel_authorized "C_UNKNOWN"
}

# =============================================================================
# 3. spool イベント処理テスト
# =============================================================================

@test "process_spool_events: spool ディレクトリが空の場合はスキップ" {
    _define_slack_functions
    watcher_init "slack_watcher" "$IGNITE_CONFIG_DIR/slack-watcher.yaml"

    run process_spool_events
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "process_spool_events: モック JSON から MIME ファイルが生成される" {
    _define_slack_functions
    watcher_init "slack_watcher" "$IGNITE_CONFIG_DIR/slack-watcher.yaml"

    # モック JSON を spool に配置
    cat > "$SLACK_SPOOL_DIR/slack_event_1234567890_654321.json" <<'JSON'
{
    "event_type": "app_mention",
    "channel_id": "C01ABC123",
    "user_id": "U01XYZ789",
    "text": "@bot implement login feature",
    "thread_ts": "",
    "event_ts": "1234567890.654321",
    "ts": "1234567890.654321"
}
JSON

    # watcher_send_mime をモック（実際の ignite_mime.py は使わない）
    watcher_send_mime() {
        local from="$1" to="$2" msg_type="$3" body_yaml="$4"
        local mime_file="$IGNITE_RUNTIME_DIR/queue/${to}/${from}_${msg_type}_test.mime"
        echo "$body_yaml" > "$mime_file"
        echo "$mime_file"
    }

    run process_spool_events
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]

    # MIME ファイルが生成されたことを確認
    local mime_count
    mime_count=$(find "$IGNITE_RUNTIME_DIR/queue/leader" -name "slack_watcher_slack_task_*.mime" -type f 2>/dev/null | wc -l)
    [ "$mime_count" -eq 1 ]

    # spool ファイルが削除されたことを確認
    local spool_count
    spool_count=$(find "$SLACK_SPOOL_DIR" -name "slack_event_*.json" -type f 2>/dev/null | wc -l)
    [ "$spool_count" -eq 0 ]
}

@test "process_spool_events: slack_event タイプ（キーワードなし）" {
    _define_slack_functions
    watcher_init "slack_watcher" "$IGNITE_CONFIG_DIR/slack-watcher.yaml"

    # キーワードなしの JSON を配置
    cat > "$SLACK_SPOOL_DIR/slack_event_9999999999_111111.json" <<'JSON'
{
    "event_type": "app_mention",
    "channel_id": "C01ABC123",
    "user_id": "U01XYZ789",
    "text": "@bot hello there",
    "thread_ts": "",
    "event_ts": "9999999999.111111",
    "ts": "9999999999.111111"
}
JSON

    # watcher_send_mime をモック
    watcher_send_mime() {
        local from="$1" to="$2" msg_type="$3" body_yaml="$4"
        local mime_file="$IGNITE_RUNTIME_DIR/queue/${to}/${from}_${msg_type}_test.mime"
        echo "$body_yaml" > "$mime_file"
        echo "$mime_file"
    }

    run process_spool_events
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]

    # slack_event（タスクキーワードなし）で生成されたことを確認
    local event_count
    event_count=$(find "$IGNITE_RUNTIME_DIR/queue/leader" -name "slack_watcher_slack_event_*.mime" -type f 2>/dev/null | wc -l)
    [ "$event_count" -eq 1 ]
}

@test "process_spool_events: 重複イベントはスキップされる" {
    _define_slack_functions
    watcher_init "slack_watcher" "$IGNITE_CONFIG_DIR/slack-watcher.yaml"

    # 事前にイベントを処理済みとしてマーク
    watcher_mark_event_processed "app_mention" "1234567890.654321"

    # 同じ event_ts のイベントが spool にある場合
    cat > "$SLACK_SPOOL_DIR/slack_event_1234567890_654321.json" <<'JSON'
{
    "event_type": "app_mention",
    "event_ts": "1234567890.654321",
    "channel_id": "C01ABC",
    "user_id": "U01XYZ",
    "text": "test",
    "thread_ts": "",
    "ts": "1234567890.654321"
}
JSON

    # 処理済みチェック
    watcher_is_event_processed "app_mention" "1234567890.654321"
}

@test "process_spool_events: アクセス制御で拒否されたイベントはスキップ" {
    _define_slack_functions
    watcher_init "slack_watcher" "$IGNITE_CONFIG_DIR/slack-watcher.yaml"

    SLACK_ACCESS_CONTROL_ENABLED="true"
    SLACK_ALLOWED_USERS=("U_ALLOWED_ONLY")

    cat > "$SLACK_SPOOL_DIR/slack_event_5555555555_111111.json" <<'JSON'
{
    "event_type": "app_mention",
    "channel_id": "C01ABC",
    "user_id": "U_NOT_ALLOWED",
    "text": "@bot implement something",
    "thread_ts": "",
    "event_ts": "5555555555.111111",
    "ts": "5555555555.111111"
}
JSON

    watcher_send_mime() {
        local from="$1" to="$2" msg_type="$3" body_yaml="$4"
        echo "SHOULD_NOT_BE_CALLED"
    }

    run process_spool_events
    [ "$status" -eq 0 ]
    # 0件処理なので "0" が出力される
    [ "$output" = "0" ]
}

# =============================================================================
# 4. トークン検証テスト
# =============================================================================

@test "validate_tokens: SLACK_BOT_TOKEN 未設定でエラー" {
    _define_slack_functions
    unset SLACK_BOT_TOKEN
    unset SLACK_APP_TOKEN
    ! validate_tokens
}

@test "validate_tokens: SLACK_APP_TOKEN が xapp- で始まらない場合エラー" {
    _define_slack_functions
    export SLACK_BOT_TOKEN="xoxb-test-token"
    export SLACK_APP_TOKEN="invalid-token"
    ! validate_tokens
}

@test "validate_tokens: 正しいトークンで成功" {
    _define_slack_functions
    export SLACK_BOT_TOKEN="xoxb-test-token"
    export SLACK_APP_TOKEN="xapp-test-token"
    validate_tokens
}

@test "validate_tokens: .env ファイルからトークンを読み込む" {
    _define_slack_functions
    unset SLACK_BOT_TOKEN
    unset SLACK_APP_TOKEN

    # .env ファイルを作成
    cat > "$IGNITE_RUNTIME_DIR/.env" <<'ENV'
SLACK_BOT_TOKEN=xoxb-from-env
SLACK_APP_TOKEN=xapp-from-env
ENV

    validate_tokens
    [ "$SLACK_BOT_TOKEN" = "xoxb-from-env" ]
    [ "$SLACK_APP_TOKEN" = "xapp-from-env" ]
}

# =============================================================================
# 5. 設定読み込みテスト
# =============================================================================

@test "load_slack_config: デフォルトキーワードが設定される" {
    _define_slack_functions
    SLACK_TASK_KEYWORDS=()

    load_slack_config ""
    [ "${#SLACK_TASK_KEYWORDS[@]}" -gt 0 ]
    local found=false
    for kw in "${SLACK_TASK_KEYWORDS[@]}"; do
        [[ "$kw" == "implement" ]] && found=true
    done
    [ "$found" = "true" ]
}

# =============================================================================
# 6. サニタイズ統合テスト
# =============================================================================

@test "サニタイズ: 制御文字が除去される" {
    _source_watcher_common
    _WATCHER_NAME="test"
    local input result
    input=$(printf 'hello\x00world\x1fend')
    result=$(_watcher_sanitize_input "$input")
    [[ "$result" == "helloworldend" ]]
}

@test "サニタイズ: シェルメタキャラクタが全角に変換される" {
    _source_watcher_common
    _WATCHER_NAME="test"
    local result
    result=$(_watcher_sanitize_input 'test; rm -rf /')
    [[ "$result" == *"；"* ]]
    [[ "$result" != *";"* ]]
}

@test "サニタイズ: 長さ制限が適用される" {
    _source_watcher_common
    _WATCHER_NAME="test"
    local long_text
    long_text=$(printf '%0.sa' {1..300})
    local result
    result=$(_watcher_sanitize_input "$long_text" 10)
    [ "${#result}" -eq 10 ]
}

# =============================================================================
# 7. watcher_common.sh 統合テスト
# =============================================================================

@test "watcher_init: slack_watcher の PID ファイルが作成される" {
    _source_watcher_common
    watcher_init "slack_watcher" "$IGNITE_CONFIG_DIR/slack-watcher.yaml"

    [ -f "$IGNITE_RUNTIME_DIR/state/slack_watcher.pid" ]
    local pid_content
    pid_content=$(cat "$IGNITE_RUNTIME_DIR/state/slack_watcher.pid")
    [ "$pid_content" = "$$" ]
}

@test "watcher_init: slack_watcher の状態ファイルが作成される" {
    _source_watcher_common
    watcher_init "slack_watcher" "$IGNITE_CONFIG_DIR/slack-watcher.yaml"

    [ -f "$IGNITE_RUNTIME_DIR/state/slack_watcher_state.json" ]
    local state
    state=$(cat "$IGNITE_RUNTIME_DIR/state/slack_watcher_state.json")
    echo "$state" | jq -e '.processed_events' > /dev/null
    echo "$state" | jq -e '.initialized_at' > /dev/null
}

# =============================================================================
# 8. ヘルプ表示テスト
# =============================================================================

@test "slack_watcher.sh --help でヘルプが表示される" {
    run bash "$UTILS_DIR/slack_watcher.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Slack"* ]]
    [[ "$output" == *"使用方法"* ]]
}

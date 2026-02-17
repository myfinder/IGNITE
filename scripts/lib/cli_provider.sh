# shellcheck shell=bash
# lib/cli_provider.sh - CLI Provider 抽象化レイヤー（opencode ヘッドレス専用）
[[ -n "${__LIB_CLI_PROVIDER_LOADED:-}" ]] && return; __LIB_CLI_PROVIDER_LOADED=1

# グローバル変数（cli_load_config で設定される）
CLI_PROVIDER=""
CLI_MODEL=""
CLI_COMMAND=""

# =============================================================================
# cli_load_config - system.yaml の cli: セクション読み込み
# =============================================================================
cli_load_config() {
    CLI_PROVIDER="opencode"
    CLI_MODEL=$(get_config cli model "$DEFAULT_MODEL")

    # モデル名バリデーション（英数字, ハイフン, ドット, スラッシュ, アンダースコア, コロンのみ許可）
    if [[ ! "$CLI_MODEL" =~ ^[a-zA-Z0-9/:._-]+$ ]]; then
        print_error "不正な model 名: $CLI_MODEL（使用可能: 英数字, /, :, ., _, -）"
        return 1
    fi

    CLI_COMMAND="opencode"
}

# =============================================================================
# cli_get_process_names - health_check 用プロセス名リストを返す
# =============================================================================
cli_get_process_names() {
    echo "opencode node"
}

# =============================================================================
# cli_setup_project_config - opencode 設定ファイルを生成
# =============================================================================
# Usage: cli_setup_project_config <workspace_dir> <role> [instruction_files...]
# role: エージェントロール名（opencode_{role}.json のファイル名に使用）
# instruction_files: opencode の instructions に追加するファイルパス（可変長）
cli_setup_project_config() {
    local workspace_dir="$1"
    local role="$2"
    shift 2 || true
    local instruction_files=()

    if [[ -z "$role" || "$role" == /* || "$role" == *.md ]]; then
        instruction_files=("$role" "$@")
        role="leader"
    else
        instruction_files=("$@")
    fi

    local config_file="${workspace_dir}/.ignite/opencode_${role}.json"
    # .ignite/ がない場合はワークスペースルートにフォールバック
    if [[ ! -d "${workspace_dir}/.ignite" ]]; then
        config_file="${workspace_dir}/opencode_${role}.json"
    fi
    # 起動ごとに再生成（model や instructions が変わりうるため）

    # instructions JSON 配列を構築
    local instructions_json="[]"
    if [[ ${#instruction_files[@]} -gt 0 ]]; then
        local _items=""
        local first=true
        for f in "${instruction_files[@]}"; do
            [[ -z "$f" ]] && continue
            # パス内の \ と " をエスケープ
            local escaped_f="${f//\\/\\\\}"
            escaped_f="${escaped_f//\"/\\\"}"
            if [[ "$first" == true ]]; then
                first=false
            else
                _items+=","
            fi
            _items+="\"$escaped_f\""
        done
        if [[ "$first" == false ]]; then
            instructions_json="[${_items}]"
        fi
    fi

    # Ollama プロバイダー設定を構築（model が ollama/ で始まる場合）
    local provider_json=""
    if [[ "$CLI_MODEL" == ollama/* ]]; then
        local ollama_url="${OLLAMA_API_URL:-http://localhost:11434/v1}"
        local ollama_model="${CLI_MODEL#ollama/}"
        # JSON インジェクション防止: " と \ をエスケープ
        ollama_url="${ollama_url//\\/\\\\}"
        ollama_url="${ollama_url//\"/\\\"}"
        ollama_model="${ollama_model//\\/\\\\}"
        ollama_model="${ollama_model//\"/\\\"}"
        provider_json=',
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "'"$ollama_url"'"
      },
      "models": {
        "'"$ollama_model"'": {
          "tools": true
        }
      }
    }
  }'
    fi

    # OpenCode 設定を生成（https://opencode.ai/docs/config/ 準拠）
    # permission: {"*": "allow"} で全ツールを自動承認（Claude の --dangerously-skip-permissions 相当）
    cat > "$config_file" <<OCEOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "$CLI_MODEL",
  "permission": {"*": "allow"},
  "instructions": $instructions_json${provider_json}
}
OCEOF
    log_info "opencode.json を生成しました: $config_file"
}

# =============================================================================
# cli_get_required_commands - インストール時の依存コマンドリストを返す
# =============================================================================
cli_get_required_commands() {
    # opencode serve + HTTP API で管理、curl/jq 必須
    echo "opencode curl jq"
}

# =============================================================================
# ヘッドレスモード: opencode serve 管理関数群
# =============================================================================

# _validate_pid <pid> <expected_pattern>
# PID が生存しており、cmdline が期待パターンにマッチするか検証
_validate_pid() {
    local pid="$1"
    local expected_pattern="$2"
    [[ -n "$pid" ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    if [[ -f "/proc/$pid/cmdline" ]]; then
        tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q "$expected_pattern"
    else
        # macOS フォールバック
        ps -p "$pid" -o args= 2>/dev/null | grep -q "$expected_pattern"
    fi
}

# cli_build_server_command <workspace_dir> <role> [extra_env]
# opencode serve のコマンド文字列を生成
cli_build_server_command() {
    local workspace_dir="$1"
    local role="${2:-leader}"
    local extra_env="${3:-}"

    local config_name="opencode_${role}.json"
    local cmd=""

    # .env が存在すれば source
    if [[ -f "${workspace_dir}/.ignite/.env" ]]; then
        cmd+="set -a && source '${workspace_dir}/.ignite/.env' && set +a && "
    fi

    cmd+="${extra_env}"
    cmd+="export WORKSPACE_DIR='${workspace_dir}' IGNITE_RUNTIME_DIR='${workspace_dir}/.ignite' && "
    cmd+="cd '${workspace_dir}' && "
    cmd+="OPENCODE_CONFIG='.ignite/${config_name}' opencode serve --port 0 --print-logs"

    echo "$cmd"
}

# cli_start_agent_server <workspace_dir> <role> <pane_idx> [extra_env]
# nohup で opencode serve をバックグラウンド起動、PID 保存、ポート解析
cli_start_agent_server() {
    local workspace_dir="$1"
    local role="$2"
    local pane_idx="$3"
    local extra_env="${4:-}"

    local runtime_dir="${workspace_dir}/.ignite"
    local log_file="${runtime_dir}/logs/agent_${role}.log"
    local pid_file="${runtime_dir}/state/.agent_pid_${pane_idx}"

    mkdir -p "${runtime_dir}/logs" "${runtime_dir}/state"

    # .env を source して環境変数を継承
    if [[ -f "${runtime_dir}/.env" ]]; then
        set -a
        # shellcheck source=/dev/null
        source "${runtime_dir}/.env"
        set +a
    fi

    local config_name="opencode_${role}.json"

    # 前回のログを退避（古い "listening on" 行でポート誤検出を防止）
    if [[ -s "$log_file" ]]; then
        mv "$log_file" "${log_file%.log}_prev.log"
    fi

    # opencode serve をバックグラウンド起動
    (
        cd "$workspace_dir" || exit 1
        ${extra_env:+eval "$extra_env"}
        WORKSPACE_DIR="$workspace_dir" \
        IGNITE_RUNTIME_DIR="$runtime_dir" \
        OPENCODE_CONFIG=".ignite/${config_name}" \
        nohup opencode serve --port 0 --print-logs >> "$log_file" 2>&1 &
        echo $! > "$pid_file"
    )

    # PID ファイルが書き込まれるまで少し待つ
    local wait_count=0
    while [[ ! -s "$pid_file" ]] && [[ $wait_count -lt 5 ]]; do
        sleep 0.2
        wait_count=$((wait_count + 1))
    done

    if [[ ! -s "$pid_file" ]]; then
        log_error "opencode serve の PID ファイルが生成されませんでした: $pid_file"
        return 1
    fi

    local pid
    pid=$(cat "$pid_file")
    log_info "opencode serve 起動: PID=$pid, role=$role, idx=$pane_idx"

    # ログからポートを解析
    cli_parse_server_port "$log_file" "$pane_idx" "$runtime_dir"
}

# cli_parse_server_port <log_file> <pane_idx> <runtime_dir>
# 起動ログからポートを解析して保存（最大30秒待機）
cli_parse_server_port() {
    local log_file="$1"
    local pane_idx="$2"
    local runtime_dir="$3"
    local port_file="${runtime_dir}/state/.agent_port_${pane_idx}"

    local max_wait=30
    local i=0
    while [[ $i -lt $max_wait ]]; do
        if [[ -f "$log_file" ]]; then
            local port
            port=$(grep -oP 'listening on http://127\.0\.0\.1:\K[0-9]+' "$log_file" 2>/dev/null | tail -1)
            if [[ -z "$port" ]]; then
                # 別のログ形式にも対応
                port=$(grep -oP 'listening on .*:(\K[0-9]+)' "$log_file" 2>/dev/null | tail -1)
            fi
            if [[ -n "$port" ]]; then
                echo "$port" > "$port_file"
                log_info "opencode serve ポート検出: $port (idx=$pane_idx)"
                return 0
            fi
        fi
        sleep 1
        ((i++))
    done

    log_error "opencode serve のポートを検出できませんでした (${max_wait}秒タイムアウト)"
    return 1
}

# cli_wait_server_ready <port> [max_wait]
# HTTP ヘルスチェックで起動完了を待機
cli_wait_server_ready() {
    local port="$1"
    local max_wait="${2:-30}"

    local i=0
    while [[ $i -lt $max_wait ]]; do
        if curl -sf --max-time 2 "http://127.0.0.1:${port}/global/health" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        ((i++))
    done

    log_error "opencode serve がヘルスチェックに応答しません (port=$port, ${max_wait}秒タイムアウト)"
    return 1
}

# cli_create_session <port>
# POST /session で新規セッション作成、セッション ID を stdout に返す
cli_create_session() {
    local port="$1"

    local response
    response=$(curl -sf --max-time 10 -X POST "http://127.0.0.1:${port}/session" 2>/dev/null)
    if [[ -z "$response" ]]; then
        log_error "セッション作成に失敗しました (port=$port)"
        return 1
    fi

    local session_id
    session_id=$(echo "$response" | jq -r '.id // .session_id // empty' 2>/dev/null)
    if [[ -z "$session_id" ]]; then
        # レスポンス全体が ID の場合
        session_id=$(echo "$response" | tr -d '"' | tr -d '[:space:]')
    fi

    if [[ -z "$session_id" ]]; then
        log_error "セッション ID を取得できませんでした: $response"
        return 1
    fi

    echo "$session_id"
}

# cli_send_message <port> <session_id> <message>
# POST /session/:id/prompt_async で非同期メッセージ送信
cli_send_message() {
    local port="$1"
    local session_id="$2"
    local message="$3"

    # JSON エスケープ
    local escaped_message
    escaped_message=$(printf '%s' "$message" | jq -Rs '.' 2>/dev/null)

    local response
    response=$(curl -sf --max-time 10 -X POST \
        -H "Content-Type: application/json" \
        -d "{\"parts\":[{\"type\":\"text\",\"text\":${escaped_message}}]}" \
        "http://127.0.0.1:${port}/session/${session_id}/prompt_async" 2>/dev/null)

    local rc=$?
    if [[ $rc -ne 0 ]]; then
        log_error "メッセージ送信に失敗しました (port=$port, session=$session_id)"
        return 1
    fi

    return 0
}

# cli_check_server_health <port>
# GET /global/health でヘルスチェック
cli_check_server_health() {
    local port="$1"
    curl -sf --max-time 3 "http://127.0.0.1:${port}/global/health" >/dev/null 2>&1
}

# cli_save_agent_state <pane_idx> <port> <session_id> <agent_name> <runtime_dir>
# ステートファイル群を保存
cli_save_agent_state() {
    local pane_idx="$1"
    local port="$2"
    local session_id="$3"
    local agent_name="$4"
    local runtime_dir="${5:-$IGNITE_RUNTIME_DIR}"

    local state_dir="${runtime_dir}/state"
    mkdir -p "$state_dir"

    echo "$port" > "${state_dir}/.agent_port_${pane_idx}"
    echo "$session_id" > "${state_dir}/.agent_session_${pane_idx}"
    echo "$agent_name" > "${state_dir}/.agent_name_${pane_idx}"
}

# cli_load_agent_state <pane_idx> [runtime_dir]
# ファイルからステートを読み込み → グローバル変数にセット
# _AGENT_PORT, _AGENT_SESSION_ID, _AGENT_PID, _AGENT_NAME
cli_load_agent_state() {
    local pane_idx="$1"
    local runtime_dir="${2:-$IGNITE_RUNTIME_DIR}"
    local state_dir="${runtime_dir}/state"

    _AGENT_PORT=$(cat "${state_dir}/.agent_port_${pane_idx}" 2>/dev/null || true)
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
    rm -f "${state_dir}/.agent_port_${pane_idx}"
    rm -f "${state_dir}/.agent_session_${pane_idx}"
    rm -f "${state_dir}/.agent_name_${pane_idx}"
    rm -f "${state_dir}/.send_lock_${pane_idx}"
}

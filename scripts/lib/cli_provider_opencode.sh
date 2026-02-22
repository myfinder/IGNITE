# shellcheck shell=bash
# lib/cli_provider_opencode.sh - OpenCode プロバイダー実装（per-message モード）
# opencode run --format json でメッセージ送信、--session でセッション再開
[[ -n "${__LIB_CLI_PROVIDER_OPENCODE_LOADED:-}" ]] && return; __LIB_CLI_PROVIDER_OPENCODE_LOADED=1

# =============================================================================
# cli_get_process_names - health_check 用プロセス名リストを返す
# =============================================================================
cli_get_process_names() {
    echo "opencode node"
}

# =============================================================================
# cli_get_process_pattern - _validate_pid 用のプロセスパターンを返す
# =============================================================================
cli_get_process_pattern() {
    echo "opencode"
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
    # opencode run (per-message)、jq はレスポンス解析用
    echo "opencode jq"
}

# =============================================================================
# cli_get_flock_timeout - flock タイムアウト値を返す
# per-message の応答は数分かかりうるため、長めのタイムアウトを設定
# =============================================================================
cli_get_flock_timeout() {
    echo "600"
}

# =============================================================================
# ヘッドレスモード: opencode run per-message 管理関数群
# =============================================================================

# cli_start_agent_server <workspace_dir> <role> <pane_idx> [extra_env]
# opencode run で初期化プロンプトを実行し、セッション ID を取得・保存
cli_start_agent_server() {
    local workspace_dir="$1"
    local role="$2"
    local pane_idx="$3"
    local extra_env="${4:-}"

    local runtime_dir="${workspace_dir}/.ignite"
    local log_file="${runtime_dir}/logs/agent_${role}.log"
    local pid_file="${runtime_dir}/state/.agent_pid_${pane_idx}"
    local session_file="${runtime_dir}/state/.agent_session_${pane_idx}"

    mkdir -p "${runtime_dir}/logs" "${runtime_dir}/state"

    # .env を source して環境変数を継承
    if [[ -f "${runtime_dir}/.env" ]]; then
        set -a
        # shellcheck source=/dev/null
        source "${runtime_dir}/.env"
        set +a
    fi

    local config_name="opencode_${role}.json"

    # 前回のログを退避
    if [[ -s "$log_file" ]]; then
        mv "$log_file" "${log_file%.log}_prev.log"
    fi

    # 初期化メッセージで最初のセッションを作成
    local init_msg="初期化中です。セッションを開始します。"

    local response_file="${runtime_dir}/state/.opencode_init_response_${pane_idx}"
    rm -f "$response_file"

    # opencode run をバックグラウンドで実行
    (
        cd "$workspace_dir" || exit 1
        ${extra_env:+eval "$extra_env"}
        WORKSPACE_DIR="$workspace_dir" \
        IGNITE_RUNTIME_DIR="$runtime_dir" \
        OPENCODE_CONFIG=".ignite/${config_name}" \
        opencode run --format json "$init_msg" \
            > "$response_file" 2>> "$log_file"
    ) &
    local bg_pid=$!

    # PID を保存
    echo "$bg_pid" > "$pid_file"
    log_info "opencode run 初期化起動: PID=$bg_pid, role=$role, idx=$pane_idx"

    # 完了を待機（最大120秒）
    local wait_count=0
    local max_wait=120
    while kill -0 "$bg_pid" 2>/dev/null && [[ $wait_count -lt $max_wait ]]; do
        sleep 1
        wait_count=$((wait_count + 1))
    done

    # タイムアウト時はプロセスを強制終了
    if kill -0 "$bg_pid" 2>/dev/null; then
        log_error "初期化タイムアウト: プロセスを強制終了します (PID=$bg_pid)"
        kill "$bg_pid" 2>/dev/null || true
        wait "$bg_pid" 2>/dev/null || true
        return 1
    fi

    # レスポンスからセッション ID を取得
    if [[ ! -f "$response_file" ]] || [[ ! -s "$response_file" ]]; then
        log_error "opencode run の初期化レスポンスが取得できませんでした: role=$role"
        return 1
    fi

    local session_id
    # opencode run --format json は NDJSON を出力。step_start の sessionID を取得
    session_id=$(jq -r 'select(.type == "step_start") | .sessionID // empty' "$response_file" 2>/dev/null | head -1)
    if [[ -z "$session_id" ]]; then
        # フォールバック: sessionId / session_id フィールドを試行
        session_id=$(jq -r '.sessionID // .session_id // .id // empty' "$response_file" 2>/dev/null | head -1)
    fi

    if [[ -z "$session_id" ]]; then
        log_error "opencode run から session_id を取得できませんでした: role=$role"
        log_error "レスポンス: $(head -c 500 "$response_file")"
        return 1
    fi

    # ステートを保存
    echo "$session_id" > "$session_file"

    # init 完了後は PID ファイルを削除（per-message パターンではプロセスは既に終了済み）
    rm -f "$pid_file"

    log_info "opencode run セッション作成完了: session_id=$session_id, role=$role"
    _log_session_response "$role" "$session_id" "$(cat "$response_file" 2>/dev/null)" "$runtime_dir"

    # レスポンスファイルをクリーンアップ
    rm -f "$response_file"

    return 0
}

# cli_send_message <session_id> <message>
# opencode run --session で同期的にメッセージ送信
cli_send_message() {
    local session_id="$1"
    local message="$2"

    if [[ -z "$session_id" ]]; then
        log_error "cli_send_message: session_id が空です"
        return 1
    fi

    local workspace_dir="${WORKSPACE_DIR:-$(pwd)}"
    local runtime_dir="${IGNITE_RUNTIME_DIR:-${workspace_dir}/.ignite}"
    local log_file="${runtime_dir}/logs/opencode_send.log"
    local config_name
    # opencode.json の検出: role 別設定があればそれを使う
    config_name=$(ls "${runtime_dir}"/opencode_*.json 2>/dev/null | head -1)
    local config_env=""
    if [[ -n "$config_name" ]]; then
        config_env="OPENCODE_CONFIG=$(realpath --relative-to="$workspace_dir" "$config_name" 2>/dev/null || echo "$config_name")"
    fi

    local response
    response=$(
        cd "$workspace_dir" || exit 1
        ${config_env:+export $config_env}
        opencode run --format json --session "$session_id" "$message" 2>> "$log_file"
    )
    local rc=$?
    [[ $rc -eq 0 ]] && _log_session_response "${_AGENT_NAME:-unknown}" "$session_id" "$response" "$runtime_dir"

    if [[ $rc -ne 0 ]]; then
        log_error "opencode run メッセージ送信に失敗しました (session=$session_id, rc=$rc)"
        return 1
    fi

    # エラーレスポンスチェック
    if [[ -z "$response" ]]; then
        log_error "opencode run の応答が空です (session=$session_id)"
        return 1
    fi

    return 0
}

# cli_check_session_alive <pane_idx>
# セッション ID ファイルの存在チェック
cli_check_session_alive() {
    local pane_idx="$1"
    local runtime_dir="${IGNITE_RUNTIME_DIR:-}"
    local session_id
    session_id=$(cat "${runtime_dir}/state/.agent_session_${pane_idx}" 2>/dev/null || true)
    [[ -n "$session_id" ]]
}

# shellcheck shell=bash
# lib/cli_provider_codex.sh - Codex CLI ヘッドレスプロバイダー実装
# codex exec --json (per-message) + exec resume (セッション再開) でエージェントを管理する
[[ -n "${__LIB_CLI_PROVIDER_CODEX_LOADED:-}" ]] && return; __LIB_CLI_PROVIDER_CODEX_LOADED=1

# =============================================================================
# cli_get_process_names - health_check 用プロセス名リストを返す
# =============================================================================
cli_get_process_names() {
    echo "codex node"
}

# =============================================================================
# cli_get_process_pattern - _validate_pid 用のプロセスパターンを返す
# =============================================================================
cli_get_process_pattern() {
    echo "codex"
}

# =============================================================================
# cli_get_required_commands - インストール時の依存コマンドリストを返す
# =============================================================================
cli_get_required_commands() {
    echo "codex jq"
}

# =============================================================================
# cli_get_flock_timeout - flock タイムアウト値を返す
# Codex の応答は数分かかりうるため、長めのタイムアウトを設定
# =============================================================================
cli_get_flock_timeout() {
    echo "600"
}

# =============================================================================
# cli_setup_project_config - Codex CLI 用の設定を準備
# インストラクションファイルの内容を連結して初期プロンプトファイルに保存
# Codex は AGENTS.md を自動読み込みするので、role 固有のインストラクションのみ準備
# =============================================================================
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

    local ignite_dir="${workspace_dir}/.ignite"
    mkdir -p "$ignite_dir"

    local init_prompt_file="${ignite_dir}/.codex_init_prompt_${role}"

    # インストラクションファイルの内容を連結
    local content=""
    for f in "${instruction_files[@]}"; do
        [[ -z "$f" ]] && continue
        [[ -f "$f" ]] || continue
        content+="$(cat "$f")"$'\n\n'
    done

    echo "$content" > "$init_prompt_file"
    log_info "Codex 初期プロンプトファイルを生成しました: $init_prompt_file"
}

# =============================================================================
# cli_start_agent_server - Codex CLI で初期化プロンプトを実行
# codex exec --json --full-auto でセッションを作成し、session_id と PID を保存
# =============================================================================
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

    # 前回のログを退避
    if [[ -s "$log_file" ]]; then
        mv "$log_file" "${log_file%.log}_prev.log"
    fi

    # 初期プロンプトファイルから内容を読み込み
    local init_prompt_file="${runtime_dir}/.codex_init_prompt_${role}"
    local instructions_prefix=""
    if [[ -f "$init_prompt_file" ]] && [[ -s "$init_prompt_file" ]]; then
        instructions_prefix=$(cat "$init_prompt_file")
    fi

    # 初期化メッセージを構築（インストラクション + 起動メッセージ）
    local init_msg="${instructions_prefix}

初期化中です。セッションを開始します。"

    local response_file="${runtime_dir}/state/.codex_init_response_${pane_idx}"
    rm -f "$response_file"

    # codex exec をバックグラウンドで実行
    (
        cd "$workspace_dir" || exit 1
        ${extra_env:+eval "$extra_env"}
        WORKSPACE_DIR="$workspace_dir" \
        IGNITE_RUNTIME_DIR="$runtime_dir" \
        echo "$init_msg" | codex exec --json --full-auto - \
            > "$response_file" 2>> "$log_file"
    ) &
    local bg_pid=$!

    # PID を保存
    echo "$bg_pid" > "$pid_file"
    log_info "Codex CLI 初期化起動: PID=$bg_pid, role=$role, idx=$pane_idx"

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
        log_error "Codex CLI の初期化レスポンスが取得できませんでした: role=$role"
        return 1
    fi

    local session_id
    # codex exec --json は NDJSON を出力。thread.started の thread_id を取得
    session_id=$(jq -r 'select(.type == "thread.started") | .thread_id // empty' "$response_file" 2>/dev/null | head -1)
    if [[ -z "$session_id" ]]; then
        # フォールバック: thread_id / session_id フィールドを試行
        session_id=$(jq -r '.thread_id // .session_id // .id // empty' "$response_file" 2>/dev/null | head -1)
    fi

    if [[ -z "$session_id" ]]; then
        log_error "Codex CLI から session_id を取得できませんでした: role=$role"
        log_error "レスポンス: $(head -c 500 "$response_file")"
        return 1
    fi

    # ステートを保存
    echo "$session_id" > "$session_file"

    # init 完了後は PID ファイルを削除（per-message パターンではプロセスは既に終了済み）
    rm -f "$pid_file"

    log_info "Codex CLI セッション作成完了: session_id=$session_id, role=$role"

    # レスポンスファイルをクリーンアップ
    rm -f "$response_file"

    return 0
}

# =============================================================================
# cli_send_message <session_id> <message>
# codex exec resume で同期的にメッセージ送信
# =============================================================================
cli_send_message() {
    local session_id="$1"
    local message="$2"

    if [[ -z "$session_id" ]]; then
        log_error "cli_send_message: session_id が空です"
        return 1
    fi

    local workspace_dir="${WORKSPACE_DIR:-$(pwd)}"
    local runtime_dir="${IGNITE_RUNTIME_DIR:-${workspace_dir}/.ignite}"
    local log_file="${runtime_dir}/logs/codex_send.log"

    local response
    response=$(
        cd "$workspace_dir" || exit 1
        codex exec resume --json --full-auto "$session_id" "$message" 2>> "$log_file"
    )
    local rc=$?

    if [[ $rc -ne 0 ]]; then
        log_error "Codex CLI メッセージ送信に失敗しました (session=$session_id, rc=$rc)"
        return 1
    fi

    return 0
}

# =============================================================================
# cli_check_session_alive <pane_idx>
# セッション ID ファイルの存在チェック
# =============================================================================
cli_check_session_alive() {
    local pane_idx="$1"
    local runtime_dir="${IGNITE_RUNTIME_DIR:-}"
    local session_id
    session_id=$(cat "${runtime_dir}/state/.agent_session_${pane_idx}" 2>/dev/null || true)
    [[ -n "$session_id" ]]
}

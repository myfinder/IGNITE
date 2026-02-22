# shellcheck shell=bash
# lib/cli_provider_claude.sh - Claude Code ヘッドレスプロバイダー実装
# claude -p (per-message プロセス起動) でエージェントを管理する
[[ -n "${__LIB_CLI_PROVIDER_CLAUDE_LOADED:-}" ]] && return; __LIB_CLI_PROVIDER_CLAUDE_LOADED=1

# デフォルトモデル（Claude Code 用）
_CLAUDE_DEFAULT_MODEL="claude-opus-4-6"

# =============================================================================
# cli_get_process_names - health_check 用プロセス名リストを返す
# =============================================================================
cli_get_process_names() {
    echo "claude node"
}

# =============================================================================
# cli_get_process_pattern - _validate_pid 用のプロセスパターンを返す
# =============================================================================
cli_get_process_pattern() {
    echo "claude"
}

# =============================================================================
# cli_get_required_commands - インストール時の依存コマンドリストを返す
# =============================================================================
cli_get_required_commands() {
    # Claude Code CLI + jq（レスポンス解析用）
    echo "claude jq"
}

# =============================================================================
# cli_get_flock_timeout - flock タイムアウト値を返す
# Claude の応答は数分かかりうるため、長めのタイムアウトを設定
# =============================================================================
cli_get_flock_timeout() {
    echo "600"
}

# =============================================================================
# cli_setup_project_config - Claude Code 用の設定ファイルを生成
# --append-system-prompt フラグリストを .claude_flags_{role} に保存
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

    local flags_file="${ignite_dir}/.claude_flags_${role}"

    # フラグファイルを構築
    local flags=""
    for f in "${instruction_files[@]}"; do
        [[ -z "$f" ]] && continue
        [[ -f "$f" ]] || continue
        flags+=" --append-system-prompt $(printf '%q' "$f")"
    done

    echo "$flags" > "$flags_file"
    log_info "Claude Code フラグファイルを生成しました: $flags_file"
}

# =============================================================================
# cli_start_agent_server - Claude Code で初期化プロンプトを実行
# claude -p でセッションを作成し、session_id と PID を保存
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

    # モデル指定（CLI_MODEL が空なら Claude デフォルト）
    local model="${CLI_MODEL:-$_CLAUDE_DEFAULT_MODEL}"

    # フラグファイルから追加フラグを読み込み
    local flags_file="${runtime_dir}/.claude_flags_${role}"
    local extra_flags=""
    if [[ -f "$flags_file" ]]; then
        extra_flags=$(cat "$flags_file")
    fi

    # ダミーの初期化メッセージで最初のセッションを作成
    local init_msg="初期化中です。セッションを開始します。"

    # Claude Code セッション内からの入れ子実行を防止
    local _saved_claudecode="${CLAUDECODE:-}"
    unset CLAUDECODE

    # claude -p をバックグラウンドで実行し、session_id を取得
    local response_file="${runtime_dir}/state/.claude_init_response_${pane_idx}"
    rm -f "$response_file"

    (
        cd "$workspace_dir" || exit 1
        ${extra_env:+eval "$extra_env"}
        WORKSPACE_DIR="$workspace_dir" \
        IGNITE_RUNTIME_DIR="$runtime_dir" \
        claude -p "$init_msg" \
            --output-format json \
            --dangerously-skip-permissions \
            --model "$model" \
            $extra_flags \
            > "$response_file" 2>> "$log_file"
    ) &
    local bg_pid=$!

    # PID を保存（バックグラウンドプロセスの PID）
    echo "$bg_pid" > "$pid_file"
    log_info "Claude Code 初期化起動: PID=$bg_pid, role=$role, idx=$pane_idx"

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
        # CLAUDECODE 環境変数を復元してからエラー返却
        if [[ -n "$_saved_claudecode" ]]; then
            export CLAUDECODE="$_saved_claudecode"
        fi
        return 1
    fi

    # CLAUDECODE 環境変数を復元
    if [[ -n "$_saved_claudecode" ]]; then
        export CLAUDECODE="$_saved_claudecode"
    fi

    # レスポンスから session_id を取得
    if [[ ! -f "$response_file" ]] || [[ ! -s "$response_file" ]]; then
        log_error "Claude Code の初期化レスポンスが取得できませんでした: role=$role"
        return 1
    fi

    local session_id
    session_id=$(jq -r '.session_id // empty' "$response_file" 2>/dev/null)
    if [[ -z "$session_id" ]]; then
        log_error "Claude Code から session_id を取得できませんでした: role=$role"
        log_error "レスポンス: $(head -c 500 "$response_file")"
        return 1
    fi

    # ステートを保存
    echo "$session_id" > "$session_file"

    # init 完了後は PID ファイルを削除（per-message パターンではプロセスは既に終了済み）
    rm -f "$pid_file"

    log_info "Claude Code セッション作成完了: session_id=$session_id, role=$role"
    _log_session_response "$role" "$session_id" "$(cat "$response_file" 2>/dev/null)" "$runtime_dir"

    # レスポンスファイルをクリーンアップ
    rm -f "$response_file"

    return 0
}

# =============================================================================
# cli_send_message <session_id> <message>
# claude -p --resume で同期的にメッセージ送信
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
    local log_file="${runtime_dir}/logs/claude_send.log"

    # モデル指定
    local model="${CLI_MODEL:-$_CLAUDE_DEFAULT_MODEL}"

    # Claude Code セッション内からの入れ子実行を防止
    local _saved_claudecode="${CLAUDECODE:-}"
    unset CLAUDECODE

    # claude -p --resume で同期的にメッセージ送信
    local response
    response=$(
        cd "$workspace_dir" || exit 1
        claude -p "$message" \
            --resume "$session_id" \
            --output-format json \
            --dangerously-skip-permissions \
            --model "$model" \
            2>> "$log_file"
    )
    local rc=$?
    [[ $rc -eq 0 ]] && _log_session_response "${_AGENT_NAME:-unknown}" "$session_id" "$response" "$runtime_dir"

    # CLAUDECODE 環境変数を復元
    if [[ -n "$_saved_claudecode" ]]; then
        export CLAUDECODE="$_saved_claudecode"
    fi

    if [[ $rc -ne 0 ]]; then
        log_error "Claude Code メッセージ送信に失敗しました (session=$session_id, rc=$rc)"
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

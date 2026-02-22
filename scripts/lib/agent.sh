# shellcheck shell=bash
# lib/agent.sh - エージェント起動・セッション管理（ヘッドレス専用）
[[ -n "${__LIB_AGENT_LOADED:-}" ]] && return; __LIB_AGENT_LOADED=1

source "${LIB_DIR}/health_check.sh"

# GitHub Bot Token を取得（ペイン起動時の GH_TOKEN 設定用）
_resolve_bot_token() {
    local config_dir="${IGNITE_CONFIG_DIR:-}"
    local scripts_dir="${IGNITE_SCRIPTS_DIR:-}"
    [[ -z "$config_dir" || -z "$scripts_dir" ]] && return 1

    local watcher_config
    watcher_config=$(resolve_config "github-watcher.yaml" 2>/dev/null) || return 1
    [[ -f "$watcher_config" ]] || return 1

    # github-watcher.yaml から最初のリポジトリ名を取得
    local repo
    repo=$(yaml_get_first_repo "$watcher_config") || return 1

    # サブシェルで github_helpers.sh を source してキャッシュ付きトークン取得
    local token
    token=$(
        WORKSPACE_DIR="${WORKSPACE_DIR:-}" \
        IGNITE_CONFIG_DIR="$config_dir" \
        SCRIPT_DIR="$scripts_dir/utils" \
        bash -c 'source "$SCRIPT_DIR/github_helpers.sh" && get_cached_bot_token "'"$repo"'"' 2>/dev/null
    ) || true

    [[ -n "$token" && "$token" == ghs_* ]] && echo "$token"
}

# GitHub Watcher自動起動設定を取得（resolve_config でワークスペース優先）
get_watcher_auto_start() {
    local config_file
    config_file=$(resolve_config "github-watcher.yaml" 2>/dev/null) || config_file="$IGNITE_CONFIG_DIR/github-watcher.yaml"
    if [[ -f "$config_file" ]]; then
        local enabled
        enabled=$(yaml_get "$config_file" 'enabled')
        [[ "$enabled" == "true" ]]
    else
        return 1
    fi
}

# =============================================================================
# ヘッドレスモード: 初期化プロンプトメッセージ生成
# =============================================================================
_build_init_prompt() {
    local role="$1"
    local name="$2"
    local character_file="${3:-}"
    local instruction_file="${4:-}"

    local msg="あなたは${name}（${role^}）です。ワークスペースは $WORKSPACE_DIR です。起動時の初期化を行ってください。以降のメッセージ通知は queue_monitor が通知します。instructions内の workspace/ は $WORKSPACE_DIR に、./scripts/utils/ は $IGNITE_SCRIPTS_DIR/utils/ に、config/ は $IGNITE_CONFIG_DIR/ に読み替えてください。"
    echo "$msg"
}

# =============================================================================
# ヘッドレスモード: エージェント起動（全プロバイダー統一フロー）
# =============================================================================

# _start_agent_headless <role> <name> <pane_idx> [extra_env] [character_file] [instruction_file]
# プロバイダーに応じてエージェントを起動し、初期化プロンプトを送信
_start_agent_headless() {
    local role="$1"
    local name="$2"
    local pane_idx="$3"
    local extra_env="${4:-}"
    local character_file="${5:-$IGNITE_CHARACTERS_DIR/${role}.md}"
    local instruction_file="${6:-$IGNITE_INSTRUCTIONS_DIR/${role}.md}"

    # 1. プロジェクト設定を生成
    cli_setup_project_config "$WORKSPACE_DIR" "$role" "$character_file" "$instruction_file"

    # 2. エージェント起動（全プロバイダーで session 作成まで完結）
    cli_start_agent_server "$WORKSPACE_DIR" "$role" "$pane_idx" "$extra_env" || return 1

    # 3. ステートから session_id を読み取り
    local session_id
    session_id=$(cat "$IGNITE_RUNTIME_DIR/state/.agent_session_${pane_idx}" 2>/dev/null || true)

    # 4. ステート保存
    cli_save_agent_state "$pane_idx" "$session_id" "${name} (${role^})"

    # 5. 初期化プロンプト送信
    local init_prompt
    init_prompt=$(_build_init_prompt "$role" "$name" "$character_file" "$instruction_file")
    cli_send_message "$session_id" "$init_prompt" || return 1

    return 0
}

# _start_ignitian_headless <id> <pane_idx> [extra_env]
_start_ignitian_headless() {
    local id="$1"
    local pane_idx="$2"
    local extra_env="${3:-}"

    # IGNITIANキューディレクトリを作成
    mkdir -p "$IGNITE_RUNTIME_DIR/queue/ignitian_${id}"

    local role="ignitian_${id}"

    # 1. プロジェクト設定を生成
    cli_setup_project_config "$WORKSPACE_DIR" "$role" \
        "$IGNITE_CHARACTERS_DIR/ignitian.md" "$IGNITE_INSTRUCTIONS_DIR/ignitian.md"

    local env_str="export IGNITE_WORKER_ID=${id}"
    [[ -n "$extra_env" ]] && env_str="${extra_env%%+([ ])&&*} ${env_str}"

    # 2. エージェント起動
    cli_start_agent_server "$WORKSPACE_DIR" "$role" "$pane_idx" "$env_str" || return 1

    # 3. ステートから session_id を読み取り
    local session_id
    session_id=$(cat "$IGNITE_RUNTIME_DIR/state/.agent_session_${pane_idx}" 2>/dev/null || true)

    # 4. ステート保存
    cli_save_agent_state "$pane_idx" "$session_id" "IGNITIAN-${id}"

    # 5. 初期化プロンプト送信
    local init_prompt
    init_prompt=$(_build_init_prompt "ignitian" "IGNITIAN-${id}")
    cli_send_message "$session_id" "$init_prompt" || return 1

    return 0
}

# =============================================================================
# エージェント停止
# =============================================================================

# _kill_agent_process <pane_idx> [session_pane (unused)]
# PID ファイルからプロセスを停止（共通 _kill_process_tree を使用）
_kill_agent_process() {
    local pane_idx="$1"

    local pid_file="$IGNITE_RUNTIME_DIR/state/.agent_pid_${pane_idx}"
    local pid
    pid=$(cat "$pid_file" 2>/dev/null || true)

    if [[ -n "$pid" ]] && _validate_pid "$pid" "$(cli_get_process_pattern 2>/dev/null || echo "opencode")"; then
        _kill_process_tree "$pid" "$pane_idx" "$IGNITE_RUNTIME_DIR"
    fi

    cli_cleanup_agent_state "$pane_idx"
}

# 後方互換: 既存コードから呼ばれる _kill_pane_process
_kill_pane_process() {
    local _session_pane="$1"
    local pane_idx="$2"
    _kill_agent_process "$pane_idx"
}

# エージェント起動関数（最大3回リトライ）
# start_agent_in_pane <role> <name> <pane> [gh_export] [character_file] [instruction_file]
start_agent_in_pane() {
    local role="$1"      # strategist, architect, etc.
    local name="$2"      # キャラクター名（characters.yaml で定義）
    local pane="$3"      # ペイン番号
    local _gh_export="${4:-}"  # 未使用（後方互換）
    local character_file="${5:-}"
    local instruction_file="${6:-}"
    local max_retries=3
    local retry=0

    while [[ $retry -lt $max_retries ]]; do
        print_info "${name} を起動中... (試行 $((retry+1))/$max_retries)"

        if _start_agent_headless "$role" "$name" "$pane" "" "$character_file" "$instruction_file"; then
            print_success "${name} 起動完了"
            return 0
        fi

        print_warning "${name} 起動失敗、リトライ中..."
        ((retry++))
        sleep "$(get_delay agent_retry_wait 2)"
    done

    print_error "${name} 起動に失敗しました（${max_retries}回試行）"
    return 1
}

# IGNITIANS 起動関数
start_ignitian_in_pane() {
    local id="$1"        # IGNITIAN番号 (1, 2, 3, ...)
    local pane="$2"      # ペイン番号
    local _gh_export="${3:-}"  # 未使用（後方互換）
    local max_retries=3
    local retry=0

    # IGNITIANキューディレクトリを作成
    mkdir -p "$IGNITE_RUNTIME_DIR/queue/ignitian_${id}"

    while [[ $retry -lt $max_retries ]]; do
        print_info "IGNITIAN-${id} を起動中... (試行 $((retry+1))/$max_retries)"

        if _start_ignitian_headless "$id" "$pane"; then
            print_success "IGNITIAN-${id} 起動完了"
            return 0
        fi

        print_warning "IGNITIAN-${id} 起動失敗、リトライ中..."
        ((retry++))
        sleep "$(get_delay agent_retry_wait 2)"
    done

    print_error "IGNITIAN-${id} 起動に失敗しました（${max_retries}回試行）"
    return 1
}

# =============================================================================
# リカバリ関数（簡素化: 旧セッション試行 → 失敗なら完全再起動）
# =============================================================================

# restart_leader_in_pane <agent_mode> <gh_export>
# Leader 専用の再起動（pane 0 固定）
restart_leader_in_pane() {
    local agent_mode="$1"
    local _gh_export="${2:-}"

    local pane=0

    # インストラクションファイルを決定
    local instruction_file="$IGNITE_INSTRUCTIONS_DIR/leader.md"
    local character_file="$IGNITE_CHARACTERS_DIR/leader.md"
    if [[ "$agent_mode" == "leader" ]]; then
        instruction_file="$IGNITE_INSTRUCTIONS_DIR/leader-solo.md"
        character_file="$IGNITE_CHARACTERS_DIR/leader-solo.md"
    fi

    # リカバリフロー
    cli_load_agent_state "$pane"
    local old_session="${_AGENT_SESSION_ID:-}"

    # 旧セッションで resume 試行
    if [[ -n "$old_session" ]]; then
        local init_prompt
        init_prompt=$(_build_init_prompt "leader" "${LEADER_NAME}" "$character_file" "$instruction_file")
        if cli_send_message "$old_session" "$init_prompt" 2>/dev/null; then
            log_info "Leader リカバリ: 旧セッションで再開"
            return 0
        fi
    fi

    # 旧セッション失敗 → 完全再起動
    _kill_agent_process "$pane"
    cli_setup_project_config "$WORKSPACE_DIR" "leader" "$character_file" "$instruction_file"
    _start_agent_headless "leader" "${LEADER_NAME}" "$pane" "" "$character_file" "$instruction_file" || return 1
    return 0
}

# restart_agent_in_pane <role> <name> <pane> <gh_export>
# Sub-Leaders 用の再起動（リトライなし、呼び出し元がループ制御）
restart_agent_in_pane() {
    local role="$1"
    local name="$2"
    local pane="$3"
    local _gh_export="${4:-}"

    cli_load_agent_state "$pane"
    local old_session="${_AGENT_SESSION_ID:-}"

    # 旧セッションで resume 試行
    if [[ -n "$old_session" ]]; then
        local init_prompt
        init_prompt=$(_build_init_prompt "$role" "$name")
        if cli_send_message "$old_session" "$init_prompt" 2>/dev/null; then
            log_info "${name} リカバリ: 旧セッションで再開"
            return 0
        fi
    fi

    # 旧セッション失敗 → 完全再起動
    _kill_agent_process "$pane"
    cli_setup_project_config "$WORKSPACE_DIR" "$role" \
        "$IGNITE_CHARACTERS_DIR/${role}.md" "$IGNITE_INSTRUCTIONS_DIR/${role}.md"
    _start_agent_headless "$role" "$name" "$pane" || return 1
    return 0
}

# restart_ignitian_in_pane <id> <pane> <gh_export>
# IGNITIAN 用の再起動（既存キューディレクトリ再利用）
restart_ignitian_in_pane() {
    local id="$1"
    local pane="$2"
    local _gh_export="${3:-}"

    # キューディレクトリは既存を再利用（既に存在するはず）
    mkdir -p "$IGNITE_RUNTIME_DIR/queue/ignitian_${id}"

    cli_load_agent_state "$pane"
    local old_session="${_AGENT_SESSION_ID:-}"

    # 旧セッションで resume 試行
    if [[ -n "$old_session" ]]; then
        local init_prompt
        init_prompt=$(_build_init_prompt "ignitian" "IGNITIAN-${id}")
        if cli_send_message "$old_session" "$init_prompt" 2>/dev/null; then
            log_info "IGNITIAN-${id} リカバリ: 旧セッションで再開"
            return 0
        fi
    fi

    # 旧セッション失敗 → 完全再起動
    _kill_agent_process "$pane"
    _start_ignitian_headless "$id" "$pane" || return 1
    return 0
}

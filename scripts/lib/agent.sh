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
# ヘッドレスモード: エージェント起動
# =============================================================================

# _start_agent_headless <role> <name> <pane_idx> [extra_env]
# opencode serve をバックグラウンド起動し、HTTP で初期化プロンプトを送信
_start_agent_headless() {
    local role="$1"
    local name="$2"
    local pane_idx="$3"
    local extra_env="${4:-}"

    # プロジェクト設定を生成
    local character_file="$IGNITE_CHARACTERS_DIR/${role}.md"
    local instruction_file="$IGNITE_INSTRUCTIONS_DIR/${role}.md"
    cli_setup_project_config "$WORKSPACE_DIR" "$role" "$character_file" "$instruction_file"

    # サーバー起動
    cli_start_agent_server "$WORKSPACE_DIR" "$role" "$pane_idx" "$extra_env" || return 1

    # ポート取得
    local port
    port=$(cat "$IGNITE_RUNTIME_DIR/state/.agent_port_${pane_idx}" 2>/dev/null)
    if [[ -z "$port" ]]; then
        log_error "ポートが取得できません: role=$role, idx=$pane_idx"
        return 1
    fi

    # ヘルスチェック待機
    cli_wait_server_ready "$port" "$(get_delay server_ready 60)" || return 1

    # セッション作成
    local session_id
    session_id=$(cli_create_session "$port") || return 1

    # ステート保存
    cli_save_agent_state "$pane_idx" "$port" "$session_id" "${name} (${role^})"

    # 初期化プロンプト送信
    local init_prompt
    init_prompt=$(_build_init_prompt "$role" "$name" "$character_file" "$instruction_file")
    cli_send_message "$port" "$session_id" "$init_prompt" || return 1

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
    cli_setup_project_config "$WORKSPACE_DIR" "$role" \
        "$IGNITE_CHARACTERS_DIR/ignitian.md" "$IGNITE_INSTRUCTIONS_DIR/ignitian.md"

    local env_str="export IGNITE_WORKER_ID=${id}"
    [[ -n "$extra_env" ]] && env_str="${extra_env%%+([ ])&&*} ${env_str}"

    cli_start_agent_server "$WORKSPACE_DIR" "$role" "$pane_idx" "$env_str" || return 1

    local port
    port=$(cat "$IGNITE_RUNTIME_DIR/state/.agent_port_${pane_idx}" 2>/dev/null)
    [[ -z "$port" ]] && return 1

    cli_wait_server_ready "$port" "$(get_delay server_ready 60)" || return 1

    local session_id
    session_id=$(cli_create_session "$port") || return 1

    cli_save_agent_state "$pane_idx" "$port" "$session_id" "IGNITIAN-${id}"

    local init_prompt
    init_prompt=$(_build_init_prompt "ignitian" "IGNITIAN-${id}")
    cli_send_message "$port" "$session_id" "$init_prompt" || return 1

    return 0
}

# =============================================================================
# エージェント停止
# =============================================================================

# _kill_agent_process <pane_idx> [session_pane (unused)]
# PID ファイルからプロセスを停止
_kill_agent_process() {
    local pane_idx="$1"

    local pid_file="$IGNITE_RUNTIME_DIR/state/.agent_pid_${pane_idx}"
    local pid
    pid=$(cat "$pid_file" 2>/dev/null || true)

    if [[ -n "$pid" ]] && _validate_pid "$pid" "opencode"; then
        # 子プロセス（opencode バイナリ）も含めてプロセスツリーごと停止
        pkill -P "$pid" 2>/dev/null || true
        kill "$pid" 2>/dev/null || true
        local i
        for i in {1..6}; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.5
        done
        if kill -0 "$pid" 2>/dev/null; then
            pkill -9 -P "$pid" 2>/dev/null || true
            kill -9 "$pid" 2>/dev/null || true
        fi
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
start_agent_in_pane() {
    local role="$1"      # strategist, architect, etc.
    local name="$2"      # キャラクター名（characters.yaml で定義）
    local pane="$3"      # ペイン番号
    local _gh_export="${4:-}"  # 未使用（後方互換）
    local max_retries=3
    local retry=0

    while [[ $retry -lt $max_retries ]]; do
        print_info "${name} を起動中... (試行 $((retry+1))/$max_retries)"

        if _start_agent_headless "$role" "$name" "$pane"; then
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
# リカバリ関数
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
    local old_pid="${_AGENT_PID:-}"
    local old_port="${_AGENT_PORT:-}"
    local old_session="${_AGENT_SESSION_ID:-}"

    # サーバープロセスが生存しているか
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null && [[ -n "$old_port" ]]; then
        # 旧セッションで resume 試行
        if [[ -n "$old_session" ]]; then
            local init_prompt
            init_prompt=$(_build_init_prompt "leader" "${LEADER_NAME}" "$character_file" "$instruction_file")
            if cli_send_message "$old_port" "$old_session" "$init_prompt" 2>/dev/null; then
                log_info "Leader リカバリ: 旧セッションで再開"
                return 0
            fi
        fi
        # 旧セッション失敗 → 新規セッション作成
        local new_session
        new_session=$(cli_create_session "$old_port" 2>/dev/null) || true
        if [[ -n "$new_session" ]]; then
            cli_save_agent_state "$pane" "$old_port" "$new_session" "${LEADER_NAME} (Leader)"
            local init_prompt
            init_prompt=$(_build_init_prompt "leader" "${LEADER_NAME}" "$character_file" "$instruction_file")
            cli_send_message "$old_port" "$new_session" "$init_prompt" || true
            log_info "Leader リカバリ: 新規セッションで再開"
            return 0
        fi
    fi

    # サーバー死亡 → 再起動
    _kill_agent_process "$pane"
    cli_setup_project_config "$WORKSPACE_DIR" "leader" "$character_file" "$instruction_file"
    _start_agent_headless "leader" "${LEADER_NAME}" "$pane" || return 1
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
    local old_pid="${_AGENT_PID:-}"
    local old_port="${_AGENT_PORT:-}"
    local old_session="${_AGENT_SESSION_ID:-}"

    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null && [[ -n "$old_port" ]]; then
        if [[ -n "$old_session" ]]; then
            local init_prompt
            init_prompt=$(_build_init_prompt "$role" "$name")
            if cli_send_message "$old_port" "$old_session" "$init_prompt" 2>/dev/null; then
                log_info "${name} リカバリ: 旧セッションで再開"
                return 0
            fi
        fi
        local new_session
        new_session=$(cli_create_session "$old_port" 2>/dev/null) || true
        if [[ -n "$new_session" ]]; then
            cli_save_agent_state "$pane" "$old_port" "$new_session" "${name} (${role^})"
            local init_prompt
            init_prompt=$(_build_init_prompt "$role" "$name")
            cli_send_message "$old_port" "$new_session" "$init_prompt" || true
            return 0
        fi
    fi

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
    local old_pid="${_AGENT_PID:-}"
    local old_port="${_AGENT_PORT:-}"
    local old_session="${_AGENT_SESSION_ID:-}"

    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null && [[ -n "$old_port" ]]; then
        if [[ -n "$old_session" ]]; then
            local init_prompt
            init_prompt=$(_build_init_prompt "ignitian" "IGNITIAN-${id}")
            if cli_send_message "$old_port" "$old_session" "$init_prompt" 2>/dev/null; then
                log_info "IGNITIAN-${id} リカバリ: 旧セッションで再開"
                return 0
            fi
        fi
        local new_session
        new_session=$(cli_create_session "$old_port" 2>/dev/null) || true
        if [[ -n "$new_session" ]]; then
            cli_save_agent_state "$pane" "$old_port" "$new_session" "IGNITIAN-${id}"
            local init_prompt
            init_prompt=$(_build_init_prompt "ignitian" "IGNITIAN-${id}")
            cli_send_message "$old_port" "$new_session" "$init_prompt" || true
            return 0
        fi
    fi

    _kill_agent_process "$pane"
    _start_ignitian_headless "$id" "$pane" || return 1
    return 0
}

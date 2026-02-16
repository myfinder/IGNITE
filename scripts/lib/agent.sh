# shellcheck shell=bash
# lib/agent.sh - エージェント起動・セッション管理
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
    # NOTE: 同一の sed パターンが queue_monitor.sh _refresh_bot_token_cache にも存在する
    local repo
    repo=$(sed -n '/repositories:/,/^[^ ]/{
        /- repo:/{
            s/.*- repo: *//
            s/ *#.*//
            s/["\x27]//g
            s/ *$//
            p; q
        }
    }' "$watcher_config" 2>/dev/null)
    [[ -z "$repo" ]] && return 1

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

# エージェント起動関数（最大3回リトライ）
start_agent_in_pane() {
    local role="$1"      # strategist, architect, etc.
    local name="$2"      # キャラクター名（characters.yaml で定義）
    local pane="$3"      # ペイン番号
    local _gh_export="${4:-}"  # GH_TOKEN export コマンド（cmd_start.sh から渡される）
    local max_retries=3
    local retry=0

    while [[ $retry -lt $max_retries ]]; do
        print_info "${name} を起動中... (試行 $((retry+1))/$max_retries)"

        tmux set-option -t "$SESSION_NAME:$TMUX_WINDOW_NAME.$pane" -p @agent_name "${name} (${role^})"

        # ロール別の opencode.json を生成（OpenCode の場合、各エージェント固有の instructions を設定）
        cli_setup_project_config "$WORKSPACE_DIR" "$role" \
            "$IGNITE_CHARACTERS_DIR/${role}.md" "$IGNITE_INSTRUCTIONS_DIR/${role}.md"

        # CLI 起動（ワークスペースディレクトリで実行）
        local _launch_cmd
        _launch_cmd=$(cli_build_launch_command "$WORKSPACE_DIR" "" "$_gh_export" "$role")
        tmux send-keys -t "$SESSION_NAME:$TMUX_WINDOW_NAME.$pane" "$_launch_cmd" Enter
        sleep "$(get_delay leader_startup 3)"

        # 権限確認通過（プロバイダーが必要とする場合のみ）
        if cli_needs_permission_accept; then
            tmux send-keys -t "$SESSION_NAME:$TMUX_WINDOW_NAME.$pane" Down
            sleep "$(get_delay permission_accept 0.5)"
            tmux send-keys -t "$SESSION_NAME:$TMUX_WINDOW_NAME.$pane" Enter
        fi
        sleep "$(get_delay cli_startup 8)"

        # 起動確認（ヘルスチェック）
        local _health
        _health=$(check_agent_health "$SESSION_NAME:$TMUX_WINDOW_NAME" "$pane" "${name} (${role^})")
        if [[ "$_health" != "missing" ]]; then
            # TUI 入力受付待機（OpenCode は TUI 描画完了まで入力不可）
            local _target="$SESSION_NAME:$TMUX_WINDOW_NAME.$pane"
            cli_wait_tui_ready "$_target"
            # プロンプト先頭を / 以外にする（OpenCode のスラッシュコマンドメニュー回避）
            if cli_needs_prompt_injection; then
                tmux send-keys -l -t "$_target" \
                    "以下のファイルを読んでください: $IGNITE_CHARACTERS_DIR/${role}.md と $IGNITE_INSTRUCTIONS_DIR/${role}.md あなたは${name}として振る舞ってください。ワークスペースは $WORKSPACE_DIR です。起動時の初期化を行ってください。以降のメッセージ通知は queue_monitor が tmux 経由で送信します。instructions内の workspace/ は $WORKSPACE_DIR に、./scripts/utils/ は $IGNITE_SCRIPTS_DIR/utils/ に、config/ は $IGNITE_CONFIG_DIR/ に読み替えてください。"
            else
                # opencode: instructions は opencode_{role}.json 経由で読み込み済み
                tmux send-keys -l -t "$_target" \
                    "あなたは${name}（${role^}）です。ワークスペースは $WORKSPACE_DIR です。起動時の初期化を行ってください。以降のメッセージ通知は queue_monitor が tmux 経由で送信します。instructions内の workspace/ は $WORKSPACE_DIR に、./scripts/utils/ は $IGNITE_SCRIPTS_DIR/utils/ に、config/ は $IGNITE_CONFIG_DIR/ に読み替えてください。"
            fi
            sleep "$(get_delay prompt_send 0.3)"
            eval "tmux send-keys -t \"$_target\" $(cli_get_submit_keys)"
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
    local _gh_export="${3:-}"  # GH_TOKEN export コマンド（cmd_start.sh から渡される）
    local max_retries=3
    local retry=0

    # IGNITIANキューディレクトリを作成
    mkdir -p "$IGNITE_RUNTIME_DIR/queue/ignitian_${id}"

    while [[ $retry -lt $max_retries ]]; do
        print_info "IGNITIAN-${id} を起動中... (試行 $((retry+1))/$max_retries)"

        tmux set-option -t "$SESSION_NAME:$TMUX_WINDOW_NAME.$pane" -p @agent_name "IGNITIAN-${id}"

        # IGNITIAN 用の opencode.json を生成（各 IGNITIAN で共通の instructions を使用）
        cli_setup_project_config "$WORKSPACE_DIR" "ignitian_${id}" \
            "$IGNITE_CHARACTERS_DIR/ignitian.md" "$IGNITE_INSTRUCTIONS_DIR/ignitian.md"

        # IGNITE_WORKER_ID を設定して CLI 起動（per-IGNITIAN リポジトリ分離用）
        local _launch_cmd
        _launch_cmd=$(cli_build_launch_command "$WORKSPACE_DIR" "export IGNITE_WORKER_ID=${id} && " "$_gh_export" "ignitian_${id}")
        tmux send-keys -t "$SESSION_NAME:$TMUX_WINDOW_NAME.$pane" "$_launch_cmd" Enter
        sleep "$(get_delay leader_startup 3)"

        # 権限確認通過（プロバイダーが必要とする場合のみ）
        if cli_needs_permission_accept; then
            tmux send-keys -t "$SESSION_NAME:$TMUX_WINDOW_NAME.$pane" Down
            sleep "$(get_delay permission_accept 0.5)"
            tmux send-keys -t "$SESSION_NAME:$TMUX_WINDOW_NAME.$pane" Enter
        fi
        sleep "$(get_delay cli_startup 8)"

        # 起動確認（ヘルスチェック）
        local _health
        _health=$(check_agent_health "$SESSION_NAME:$TMUX_WINDOW_NAME" "$pane" "IGNITIAN-${id}")
        if [[ "$_health" != "missing" ]]; then
            # TUI 入力受付待機（OpenCode は TUI 描画完了まで入力不可）
            local _target="$SESSION_NAME:$TMUX_WINDOW_NAME.$pane"
            cli_wait_tui_ready "$_target"
            # プロンプト先頭を / 以外にする（OpenCode のスラッシュコマンドメニュー回避）
            if cli_needs_prompt_injection; then
                tmux send-keys -l -t "$_target" \
                    "以下のファイルを読んでください: $IGNITE_CHARACTERS_DIR/ignitian.md と $IGNITE_INSTRUCTIONS_DIR/ignitian.md あなたはIGNITIAN-${id}として振る舞ってください。ワークスペースは $WORKSPACE_DIR です。起動時の初期化を行ってください。以降のメッセージ通知は queue_monitor が tmux 経由で送信します。instructions内の workspace/ は $WORKSPACE_DIR に、./scripts/utils/ は $IGNITE_SCRIPTS_DIR/utils/ に、config/ は $IGNITE_CONFIG_DIR/ に読み替えてください。"
            else
                # opencode: instructions は opencode_ignitian_${id}.json 経由で読み込み済み
                tmux send-keys -l -t "$_target" \
                    "あなたはIGNITIAN-${id}です。ワークスペースは $WORKSPACE_DIR です。起動時の初期化を行ってください。以降のメッセージ通知は queue_monitor が tmux 経由で送信します。instructions内の workspace/ は $WORKSPACE_DIR に、./scripts/utils/ は $IGNITE_SCRIPTS_DIR/utils/ に、config/ は $IGNITE_CONFIG_DIR/ に読み替えてください。"
            fi
            sleep "$(get_delay prompt_send 0.3)"
            eval "tmux send-keys -t \"$_target\" $(cli_get_submit_keys)"
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


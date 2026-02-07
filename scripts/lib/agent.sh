# shellcheck shell=bash
# lib/agent.sh - エージェント起動・セッション管理
[[ -n "${__LIB_AGENT_LOADED:-}" ]] && return; __LIB_AGENT_LOADED=1

# GitHub Watcher自動起動設定を取得
get_watcher_auto_start() {
    local config_file="$IGNITE_CONFIG_DIR/github-watcher.yaml"
    if [[ -f "$config_file" ]]; then
        local enabled
        enabled=$(grep -E '^\s*enabled:' "$config_file" | head -1 | awk '{print $2}')
        [[ "$enabled" == "true" ]]
    else
        return 1
    fi
}

# エージェント起動関数（最大3回リトライ）
start_agent() {
    local role="$1"      # strategist, architect, etc.
    local name="$2"      # 義賀リオ, 祢音ナナ, etc.
    local pane="$3"      # ペイン番号
    local max_retries=3
    local retry=0

    while [[ $retry -lt $max_retries ]]; do
        print_info "${name} を起動中... (試行 $((retry+1))/$max_retries)"

        # ペイン作成
        tmux split-window -t "$SESSION_NAME:ignite" -h
        tmux select-layout -t "$SESSION_NAME:ignite" tiled
        tmux set-option -t "$SESSION_NAME:ignite.$pane" -p @agent_name "${name} (${role^})"

        # Claude CLI 起動（ワークスペースディレクトリで実行）
        tmux send-keys -t "$SESSION_NAME:ignite.$pane" \
            "cd '$WORKSPACE_DIR' && CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 claude --model $DEFAULT_MODEL --dangerously-skip-permissions --teammate-mode in-process" Enter
        sleep "$(get_delay leader_startup 3)"

        # 権限確認通過
        tmux send-keys -t "$SESSION_NAME:ignite.$pane" Down
        sleep "$(get_delay permission_accept 0.5)"
        tmux send-keys -t "$SESSION_NAME:ignite.$pane" Enter
        sleep "$(get_delay claude_startup 8)"

        # 起動確認（ペインが生きているか）
        if tmux list-panes -t "$SESSION_NAME:ignite" 2>/dev/null | grep -q "$pane:"; then
            # システムプロンプト読み込み（絶対パスを使用）
            tmux send-keys -t "$SESSION_NAME:ignite.$pane" \
                "$IGNITE_INSTRUCTIONS_DIR/${role}.md を読んで、あなたは${name}として振る舞ってください。ワークスペースは $WORKSPACE_DIR です。$WORKSPACE_DIR/queue/${role}/ のメッセージを監視してください。instructions内の workspace/ は $WORKSPACE_DIR に、./scripts/utils/ は $IGNITE_SCRIPTS_DIR/utils/ に読み替えてください。"
            sleep "$(get_delay prompt_send 0.3)"
            tmux send-keys -t "$SESSION_NAME:ignite.$pane" C-m
            sleep "$(get_delay agent_stabilize 2)"  # プロンプト送信後の安定待機
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
start_ignitian() {
    local id="$1"        # IGNITIAN番号 (1, 2, 3, ...)
    local pane="$2"      # ペイン番号
    local max_retries=3
    local retry=0

    # IGNITIANキューディレクトリを作成
    mkdir -p "$WORKSPACE_DIR/queue/ignitian_${id}"

    while [[ $retry -lt $max_retries ]]; do
        print_info "IGNITIAN-${id} を起動中... (試行 $((retry+1))/$max_retries)"

        # ペイン作成
        tmux split-window -t "$SESSION_NAME:ignite" -h
        tmux select-layout -t "$SESSION_NAME:ignite" tiled
        tmux set-option -t "$SESSION_NAME:ignite.$pane" -p @agent_name "IGNITIAN-${id}"

        # IGNITE_WORKER_ID を設定して Claude CLI 起動（per-IGNITIAN リポジトリ分離用）
        tmux send-keys -t "$SESSION_NAME:ignite.$pane" \
            "export IGNITE_WORKER_ID=${id} && cd '$WORKSPACE_DIR' && CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 claude --model $DEFAULT_MODEL --dangerously-skip-permissions --teammate-mode in-process" Enter
        sleep "$(get_delay leader_startup 3)"

        # 権限確認通過
        tmux send-keys -t "$SESSION_NAME:ignite.$pane" Down
        sleep "$(get_delay permission_accept 0.5)"
        tmux send-keys -t "$SESSION_NAME:ignite.$pane" Enter
        sleep "$(get_delay claude_startup 8)"

        # 起動確認
        if tmux list-panes -t "$SESSION_NAME:ignite" 2>/dev/null | grep -q "$pane:"; then
            # システムプロンプト読み込み（絶対パスを使用）
            tmux send-keys -t "$SESSION_NAME:ignite.$pane" \
                "$IGNITE_INSTRUCTIONS_DIR/ignitian.md を読んで、あなたはIGNITIAN-${id}として振る舞ってください。ワークスペースは $WORKSPACE_DIR です。$WORKSPACE_DIR/queue/ignitian_${id}/ ディレクトリを監視してください。instructions内の workspace/ は $WORKSPACE_DIR に、./scripts/utils/ は $IGNITE_SCRIPTS_DIR/utils/ に読み替えてください。"
            sleep "$(get_delay prompt_send 0.3)"
            tmux send-keys -t "$SESSION_NAME:ignite.$pane" C-m
            sleep "$(get_delay agent_stabilize 2)"  # プロンプト送信後の安定待機
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

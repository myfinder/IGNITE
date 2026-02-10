# shellcheck shell=bash
# lib/cmd_start.sh - startコマンド
# 注意: print_error (core.sh) に依存する trap ERR あり

[[ -n "${__LIB_CMD_START_LOADED:-}" ]] && return; __LIB_CMD_START_LOADED=1

# =============================================================================
# start コマンド
# =============================================================================
cmd_start() {
    local no_attach=false
    local force=false
    local agent_mode="full"    # full, leader, sub
    local worker_count=""
    local no_workers=false
    local with_watcher=""      # 空=設定に従う, true=起動, false=起動しない
    local skip_validation=false

    # オプション解析
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--no-attach) no_attach=true; shift ;;
            -f|--force) force=true; shift ;;
            -s|--session)
                SESSION_NAME="$2"
                if [[ ! "$SESSION_NAME" =~ ^ignite- ]]; then
                    SESSION_NAME="ignite-$SESSION_NAME"
                fi
                shift 2
                ;;
            -w|--workspace)
                WORKSPACE_DIR="$2"
                if [[ ! "$WORKSPACE_DIR" = /* ]]; then
                    WORKSPACE_DIR="$(pwd)/$WORKSPACE_DIR"
                fi
                shift 2
                ;;
            -a|--agents)
                agent_mode="$2"
                if [[ ! "$agent_mode" =~ ^(full|leader|sub)$ ]]; then
                    print_error "無効なエージェントモード: $agent_mode (full/leader/sub)"
                    exit 1
                fi
                shift 2
                ;;
            --workers)
                worker_count="$2"
                if [[ ! "$worker_count" =~ ^[0-9]+$ ]] || [[ "$worker_count" -lt 1 ]] || [[ "$worker_count" -gt 32 ]]; then
                    print_error "ワーカー数は1-32の範囲で指定してください: $worker_count"
                    exit 1
                fi
                shift 2
                ;;
            --no-workers) no_workers=true; shift ;;
            --with-watcher) with_watcher=true; shift ;;
            --no-watcher) with_watcher=false; shift ;;
            --skip-validation) skip_validation=true; shift ;;
            -h|--help) cmd_help start; exit 0 ;;
            *) print_error "Unknown option: $1"; cmd_help start; exit 1 ;;
        esac
    done

    # セッション名が未指定の場合は自動生成
    if [[ -z "$SESSION_NAME" ]]; then
        SESSION_NAME=$(generate_session_id)
    fi

    # ワークスペースが未指定の場合はデフォルト
    setup_workspace

    # ワーカー数の決定
    if [[ -z "$worker_count" ]]; then
        worker_count=$(get_worker_count)
    fi

    # --no-workers が指定された場合
    if [[ "$no_workers" == true ]]; then
        worker_count=0
    fi

    # agent_mode が leader の場合は Sub-Leaders も起動しない
    if [[ "$agent_mode" == "leader" ]]; then
        worker_count=0
    fi

    # エラートラップ
    trap 'print_error "エラーが発生しました (line $LINENO)"' ERR

    print_header "IGNITE システム起動"
    echo ""
    echo -e "${BLUE}IGNITEバージョン:${NC} v$VERSION"
    echo -e "${BLUE}セッションID:${NC} $SESSION_NAME"
    echo -e "${BLUE}ワークスペース:${NC} $WORKSPACE_DIR"
    echo -e "${BLUE}起動モード:${NC} $agent_mode"
    if [[ "$agent_mode" != "leader" ]]; then
        echo -e "${BLUE}Sub-Leaders:${NC} ${#SUB_LEADERS[@]}名"
    fi
    if [[ "$worker_count" -gt 0 ]]; then
        echo -e "${BLUE}IGNITIANs:${NC} ${worker_count}並列"
    fi
    echo ""

    # 設定ファイル検証（--skip-validation で無効化可能）
    if [[ "$skip_validation" == false ]] && declare -f validate_all_configs &>/dev/null; then
        print_info "設定ファイルを検証中..."
        _VALIDATION_ERRORS=()
        _VALIDATION_WARNINGS=()
        local xdg_dir="${XDG_CONFIG_HOME:-$HOME/.config}/ignite"
        validate_system_yaml "${IGNITE_CONFIG_DIR}/system.yaml" || true
        if [[ -d "$xdg_dir" ]]; then
            validate_watcher_yaml    "${xdg_dir}/github-watcher.yaml" || true
            validate_github_app_yaml "${xdg_dir}/github-app.yaml" || true
        fi

        # 警告の表示
        if [[ ${#_VALIDATION_WARNINGS[@]} -gt 0 ]]; then
            for w in "${_VALIDATION_WARNINGS[@]}"; do
                echo -e "  ${YELLOW}${w}${NC}"
            done
        fi

        # エラーがあれば起動中止
        if [[ ${#_VALIDATION_ERRORS[@]} -gt 0 ]]; then
            for e in "${_VALIDATION_ERRORS[@]}"; do
                echo -e "  ${RED}${e}${NC}"
            done
            echo ""
            print_error "設定ファイルにエラーがあります。起動を中止します。"
            echo -e "  修正後に再実行するか、${YELLOW}--skip-validation${NC} で検証をスキップしてください。"
            _VALIDATION_ERRORS=()
            _VALIDATION_WARNINGS=()
            exit 1
        fi

        _VALIDATION_ERRORS=()
        _VALIDATION_WARNINGS=()
        print_success "設定ファイル検証OK"
        echo ""
    fi

    cd "$WORKSPACE_DIR" || return 1

    # 既存のセッションチェック
    if session_exists; then
        if [[ "$force" == true ]]; then
            print_warning "既存のセッションを強制終了します"
            tmux kill-session -t "$SESSION_NAME"
            print_success "既存セッションを終了しました"
        else
            print_warning "既存のignite-sessionが見つかりました"
            read -p "既存のセッションを終了して再起動しますか? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                tmux kill-session -t "$SESSION_NAME"
                print_success "既存セッションを終了しました"
            else
                print_info "既存セッションにアタッチします"
                tmux attach -t "$SESSION_NAME"
                exit 0
            fi
        fi
    fi

    # workspaceの初期化
    print_info "workspaceを初期化中..."
    mkdir -p "$WORKSPACE_DIR/queue"/{leader,strategist,architect,evaluator,coordinator,innovator}
    # IGNITIANキューは起動時に動的作成（数が設定依存のため）
    mkdir -p "$WORKSPACE_DIR/context"
    mkdir -p "$WORKSPACE_DIR/logs"
    mkdir -p "$WORKSPACE_DIR/state"  # Watcher用ステートファイル保存先
    mkdir -p "$WORKSPACE_DIR/repos"  # 外部リポジトリのclone先

    # SQLite メモリデータベースの初期化
    if command -v sqlite3 &>/dev/null; then
        print_info "メモリデータベースを初期化中..."
        sqlite3 "$WORKSPACE_DIR/state/memory.db" < "$IGNITE_SCRIPTS_DIR/schema.sql"
        sqlite3 "$WORKSPACE_DIR/state/memory.db" "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;"
        # 既存DBのスキーママイグレーション（冪等）
        bash "$IGNITE_SCRIPTS_DIR/schema_migrate.sh" "$WORKSPACE_DIR/state/memory.db"
    else
        print_warning "sqlite3 が見つかりません。メモリ機能は無効です。"
    fi

    # 初期ダッシュボードの作成
    print_info "初期ダッシュボードを作成中..."
    cat > "$WORKSPACE_DIR/dashboard.md" <<EOF
# IGNITE Dashboard

IGNITEバージョン: v$VERSION
更新日時: $(date '+%Y-%m-%d %H:%M:%S')

## システム状態
⏳ Leader ($LEADER_NAME): 起動中...

## 現在のタスク
タスクなし - システム起動中

## 最新ログ
[$(date '+%H:%M:%S')] システム起動を開始しました
EOF

    print_success "workspace初期化完了"
    echo ""

    # 旧デーモンプロセスをクリーンアップ（前セッションの残骸対策）
    if [[ -f "$WORKSPACE_DIR/github_watcher.pid" ]]; then
        local old_pid
        old_pid=$(cat "$WORKSPACE_DIR/github_watcher.pid")
        kill "$old_pid" 2>/dev/null || true
        rm -f "$WORKSPACE_DIR/github_watcher.pid"
    fi
    if [[ -f "$WORKSPACE_DIR/queue_monitor.pid" ]]; then
        local old_pid
        old_pid=$(cat "$WORKSPACE_DIR/queue_monitor.pid")
        kill "$old_pid" 2>/dev/null || true
        rm -f "$WORKSPACE_DIR/queue_monitor.pid"
    fi
    pkill -f "queue_monitor.sh" 2>/dev/null || true
    pkill -f "github_watcher.sh" 2>/dev/null || true
    sleep "$(get_delay process_cleanup 1)"

    # tmuxセッション作成
    print_info "tmuxセッションを作成中..."
    tmux new-session -d -s "$SESSION_NAME" -n "$TMUX_WINDOW_NAME"
    sleep "$(get_delay session_create 0.5)"  # セッション作成を待機

    # ペインボーダーにキャラクター名を常時表示
    tmux set-option -t "$SESSION_NAME" pane-border-status top
    tmux set-option -t "$SESSION_NAME" pane-border-format " #{@agent_name} "

    # Leader ペイン (pane 0)
    print_info "Leader ($LEADER_NAME) を起動中..."
    tmux set-option -t "$SESSION_NAME:$TMUX_WINDOW_NAME.0" -p @agent_name "$LEADER_NAME (Leader)"

    # Bot Token を取得して GH_TOKEN を設定
    local _bot_token _gh_export=""
    _bot_token=$(_resolve_bot_token 2>/dev/null) || true
    if [[ -n "$_bot_token" ]]; then
        _gh_export="export GH_TOKEN='${_bot_token}' && "
    fi

    tmux send-keys -t "$SESSION_NAME:$TMUX_WINDOW_NAME" \
        "${_gh_export}export WORKSPACE_DIR='$WORKSPACE_DIR' && cd '$WORKSPACE_DIR' && CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 claude --model $DEFAULT_MODEL --dangerously-skip-permissions --teammate-mode in-process" Enter

    # 起動待機（確認プロンプト表示を待つ）
    print_warning "Leaderの起動を待機中... (3秒)"
    sleep "$(get_delay leader_startup 3)"

    # 確認プロンプトを通過（下矢印で "Yes, I accept" を選択してEnter）
    print_info "権限確認を承諾中..."
    tmux send-keys -t "$SESSION_NAME:$TMUX_WINDOW_NAME" Down
    sleep "$(get_delay permission_accept 0.5)"
    tmux send-keys -t "$SESSION_NAME:$TMUX_WINDOW_NAME" Enter

    # Claude Codeの起動完了を待機
    print_warning "Claude Codeの起動を待機中... (8秒)"
    sleep "$(get_delay claude_startup 8)"

    # Leaderにシステムプロンプトを読み込ませる（絶対パスを使用）
    print_info "Leaderシステムプロンプトをロード中..."
    local instruction_file="$IGNITE_INSTRUCTIONS_DIR/leader.md"
    local character_file="$IGNITE_CHARACTERS_DIR/leader.md"
    if [[ "$agent_mode" == "leader" ]]; then
        instruction_file="$IGNITE_INSTRUCTIONS_DIR/leader-solo.md"
        character_file="$IGNITE_CHARACTERS_DIR/leader-solo.md"
        print_info "単独モード: $instruction_file を使用"
    fi
    tmux send-keys -t "$SESSION_NAME:$TMUX_WINDOW_NAME" \
        "$character_file と $instruction_file を読んで、あなたはLeader（${LEADER_NAME}）として振る舞ってください。ワークスペースは $WORKSPACE_DIR です。$WORKSPACE_DIR/queue/leader/ 内のメッセージを確認してください。instructions内の workspace/ は $WORKSPACE_DIR に、./scripts/utils/ は $IGNITE_SCRIPTS_DIR/utils/ に、config/ は $IGNITE_CONFIG_DIR/ に読み替えてください。"
    sleep "$(get_delay prompt_send 0.3)"
    tmux send-keys -t "$SESSION_NAME:$TMUX_WINDOW_NAME" C-m

    # プロンプトロード完了を待機
    print_warning "Leaderの初期化を待機中... (10秒)"
    sleep "$(get_delay leader_init 10)"

    # 初期メッセージの送信
    print_info "Leaderに初期化メッセージを送信中..."
    local init_message_file
    init_message_file="$WORKSPACE_DIR/queue/leader/system_init_$(date +%s%6N).yaml"
    cat > "$init_message_file" <<EOF
type: system_init
from: system
to: leader
timestamp: "$(date -Iseconds)"
priority: high
payload:
  message: "システムが起動しました。初期化を完了してください。"
  action: "initialize_dashboard"
EOF

    echo ""
    print_success "IGNITE Leader が起動しました"

    # Sub-Leaders の起動 (agent_mode が leader 以外の場合)
    if [[ "$agent_mode" != "leader" ]]; then
        echo ""
        print_header "Sub-Leaders 起動"
        echo ""

        local pane_num=1
        for i in "${!SUB_LEADERS[@]}"; do
            local role="${SUB_LEADERS[$i]}"
            local name="${SUB_LEADER_NAMES[$i]}"

            if ! start_agent "$role" "$name" "$pane_num" "$_gh_export"; then
                print_warning "Sub-Leader ${name} の起動に失敗しましたが、続行します"
            fi

            ((pane_num++))
        done

        print_success "Sub-Leaders 起動完了 (${#SUB_LEADERS[@]}名)"
    fi

    # IGNITIANs の起動 (worker_count > 0 かつ agent_mode が full の場合)
    local actual_ignitian_count=0
    if [[ "$worker_count" -gt 0 ]] && [[ "$agent_mode" == "full" ]]; then
        echo ""
        print_header "IGNITIANs 起動"
        echo ""

        # Sub-Leaders の後のペイン番号から開始
        local start_pane=$((1 + ${#SUB_LEADERS[@]}))

        for ((i=1; i<=worker_count; i++)); do
            local pane_num=$((start_pane + i - 1))

            if ! start_ignitian "$i" "$pane_num" "$_gh_export"; then
                print_warning "IGNITIAN-${i} の起動に失敗しましたが、続行します"
            else
                actual_ignitian_count=$((actual_ignitian_count + 1))
            fi
        done

        print_success "IGNITIANs 起動完了 (${actual_ignitian_count}並列)"
    fi

    # システム設定ファイルを作成（IGNITIANs数などを記録）
    print_info "システム設定を保存中..."
    cat > "$WORKSPACE_DIR/system_config.yaml" <<EOF
# IGNITE システム設定（自動生成）
# このファイルはシステム起動時に自動的に更新されます

system:
  started_at: "$(date -Iseconds)"
  agent_mode: "${agent_mode}"
  session_name: "${SESSION_NAME}"
  workspace_dir: "${WORKSPACE_DIR}"

ignitians:
  count: ${actual_ignitian_count}
  ids: [$(seq -s ', ' 1 ${actual_ignitian_count} 2>/dev/null || echo "")]
EOF

    # セッション→ワークスペースのマッピングを保存（stop時の自動検出用）
    mkdir -p "$IGNITE_CONFIG_DIR/sessions"
    cat > "$IGNITE_CONFIG_DIR/sessions/${SESSION_NAME}.yaml" <<EOF
# IGNITE セッション情報（自動生成）
session_name: "${SESSION_NAME}"
workspace_dir: "${WORKSPACE_DIR}"
started_at: "$(date -Iseconds)"
mode: "${agent_mode}"
agents_total: $((1 + ${#SUB_LEADERS[@]} + worker_count))
agents_actual: $((1 + ${#SUB_LEADERS[@]} + actual_ignitian_count))
EOF

    # コスト追跡用のセッションID記録
    print_info "コスト追跡用のセッション情報を記録中..."
    mkdir -p "$WORKSPACE_DIR/costs/history"

    local started_timestamp
    started_timestamp=$(date -Iseconds)
    cat > "$WORKSPACE_DIR/costs/sessions.yaml" <<EOF
# IGNITE セッション情報（コスト追跡用）
# このファイルはシステム起動時に自動的に生成されます

session_name: "${SESSION_NAME}"
started_at: "${started_timestamp}"
workspace_dir: "${WORKSPACE_DIR}"

# 各エージェントのClaudeセッションIDは起動後に自動記録されます
# sessions-index.json から起動時刻でマッチングして特定

agents:
EOF

    # エージェントのセッションID記録（起動時刻ベースで推定）
    # Note: 実際のセッションIDは sessions-index.json から起動時刻でマッチング
    local agent_started_at="$started_timestamp"

    # Leader
    cat >> "$WORKSPACE_DIR/costs/sessions.yaml" <<EOF
  leader:
    pane: 0
    name: "${LEADER_NAME//\"/\\\"}"
    started_at: "${agent_started_at}"
    session_id: null
EOF

    # Sub-Leaders
    if [[ "$agent_mode" != "leader" ]]; then
        for i in "${!SUB_LEADERS[@]}"; do
            local role="${SUB_LEADERS[$i]}"
            local name="${SUB_LEADER_NAMES[$i]//\"/\\\"}"
            local pane=$((i + 1))
            cat >> "$WORKSPACE_DIR/costs/sessions.yaml" <<EOF
  ${role}:
    pane: ${pane}
    name: "${name}"
    started_at: "${agent_started_at}"
    session_id: null
EOF
        done
    fi

    # IGNITIANs
    if [[ "$actual_ignitian_count" -gt 0 ]]; then
        echo "" >> "$WORKSPACE_DIR/costs/sessions.yaml"
        echo "ignitians:" >> "$WORKSPACE_DIR/costs/sessions.yaml"
        for ((i=1; i<=actual_ignitian_count; i++)); do
            local pane=$((5 + i))
            cat >> "$WORKSPACE_DIR/costs/sessions.yaml" <<EOF
  ignitian_${i}:
    pane: ${pane}
    started_at: "${agent_started_at}"
    session_id: null
EOF
        done
    fi

    print_success "セッション情報を記録しました"

    echo ""
    print_header "起動完了"
    echo ""
    echo "次のステップ:"
    echo -e "  1. tmuxセッションに接続: ${YELLOW}./scripts/ignite attach${NC}"
    echo -e "  2. ダッシュボード確認: ${YELLOW}./scripts/ignite status${NC}"
    echo -e "  3. タスク投入: ${YELLOW}./scripts/ignite plan \"目標\"${NC}"
    echo ""
    echo "tmuxセッション操作:"
    echo -e "  - デタッチ: ${YELLOW}Ctrl+b d${NC}"
    echo -e "  - セッション終了: ${YELLOW}./scripts/ignite stop${NC}"
    echo ""

    # GitHub Watcher の起動判定
    local start_watcher=false
    if [[ "$with_watcher" == "true" ]]; then
        start_watcher=true
    elif [[ "$with_watcher" == "false" ]]; then
        start_watcher=false
    elif get_watcher_auto_start; then
        start_watcher=true
    fi

    # GitHub Watcher の起動
    if [[ "$start_watcher" == true ]]; then
        if [[ -f "$IGNITE_CONFIG_DIR/github-watcher.yaml" ]]; then
            print_info "GitHub Watcherを起動中..."
            # ログ出力先を設定してバックグラウンド起動
            local watcher_log="$WORKSPACE_DIR/logs/github_watcher.log"
            echo "========== ${SESSION_NAME} started at $(date -Iseconds) ==========" >> "$watcher_log"
            export IGNITE_WATCHER_CONFIG="$IGNITE_CONFIG_DIR/github-watcher.yaml"
            export IGNITE_WORKSPACE_DIR="$WORKSPACE_DIR"
            export IGNITE_CONFIG_DIR="$IGNITE_CONFIG_DIR"
            export IGNITE_TMUX_SESSION="$SESSION_NAME"
            "$IGNITE_SCRIPTS_DIR/utils/github_watcher.sh" >> "$watcher_log" 2>&1 &
            local watcher_pid=$!
            echo "$watcher_pid" > "$WORKSPACE_DIR/github_watcher.pid"
            print_success "GitHub Watcher起動完了 (PID: $watcher_pid)"
            print_info "ログ: $watcher_log"
        else
            print_warning "github-watcher.yaml が見つかりません。Watcher起動をスキップ"
        fi
    fi

    # キューモニター起動（エージェント間通信に必須）
    print_info "キューモニターを起動中..."
    local queue_log="$WORKSPACE_DIR/logs/queue_monitor.log"
    echo "========== ${SESSION_NAME} started at $(date -Iseconds) ==========" >> "$queue_log"
    export WORKSPACE_DIR="$WORKSPACE_DIR"
    export IGNITE_CONFIG_DIR="$IGNITE_CONFIG_DIR"
    "$IGNITE_SCRIPTS_DIR/utils/queue_monitor.sh" -s "$SESSION_NAME" >> "$queue_log" 2>&1 &
    local queue_pid=$!
    echo "$queue_pid" > "$WORKSPACE_DIR/queue_monitor.pid"
    print_success "キューモニター起動完了 (PID: $queue_pid)"
    print_info "ログ: $queue_log"

    # 自動アタッチ（対話環境のみ）
    if [[ "$no_attach" == false ]] && [[ -t 0 ]]; then
        read -p "tmuxセッションにアタッチしますか? (Y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            tmux attach -t "$SESSION_NAME"
        fi
    fi
}

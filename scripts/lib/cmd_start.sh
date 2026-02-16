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
    local daemon_mode=false
    local agent_mode="full"    # full, leader, sub
    local worker_count=""
    local no_workers=false
    local with_watcher=""      # 空=設定に従う, true=起動, false=起動しない
    local skip_validation=false
    local dry_run=false

    # オプション解析
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--no-attach) no_attach=true; shift ;;
            -f|--force) force=true; shift ;;
            --dry-run) dry_run=true; shift ;;
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
            --daemon) daemon_mode=true; no_attach=true; force=true; shift ;;
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

    # ワークスペース固有設定の検出
    setup_workspace_config "$WORKSPACE_DIR"

    # ワークスペース固有の CLI 設定を再読み込み
    cli_load_config

    # 起動並列化
    START_PARALLEL_SLOTS="${IGNITE_START_PARALLEL_SLOTS:-5}"
    START_PARALLEL_TIMEOUT="${IGNITE_START_PARALLEL_TIMEOUT:-90}"

    # .ignite/ 未検出時のエラー表示
    if [[ ! -d "$WORKSPACE_DIR/.ignite" ]]; then
        print_error ".ignite/ ディレクトリが見つかりません: $WORKSPACE_DIR/.ignite"
        echo ""
        echo "ワークスペースを初期化してください:"
        echo -e "  ${YELLOW}ignite init -w $WORKSPACE_DIR${NC}"
        echo ""
        # ~/.config/ignite/ が存在する場合は移行を案内
        if [[ -d "${HOME}/.config/ignite" ]]; then
            echo -e "${CYAN}ヒント:${NC} 既存のグローバル設定が検出されました。"
            echo -e "移行するには: ${YELLOW}ignite init -w $WORKSPACE_DIR --migrate${NC}"
        fi
        exit 1
    fi

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
        validate_system_yaml "${IGNITE_CONFIG_DIR}/system.yaml" || true
        validate_watcher_yaml    "${IGNITE_CONFIG_DIR}/github-watcher.yaml" || true
        validate_github_app_yaml "${IGNITE_CONFIG_DIR}/github-app.yaml" || true

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
    mkdir -p "$IGNITE_RUNTIME_DIR/queue"/{leader,strategist,architect,evaluator,coordinator,innovator}
    # IGNITIANキューは起動時に動的作成（数が設定依存のため）
    mkdir -p "$IGNITE_RUNTIME_DIR/context"
    mkdir -p "$IGNITE_RUNTIME_DIR/logs"
    mkdir -p "$IGNITE_RUNTIME_DIR/state"  # Watcher用ステートファイル保存先
    mkdir -p "$IGNITE_RUNTIME_DIR/repos"  # 外部リポジトリのclone先
    mkdir -p "$IGNITE_RUNTIME_DIR/tmp"   # エージェント用一時ファイル

    # SQLite メモリデータベースの初期化
    if command -v sqlite3 &>/dev/null; then
        print_info "メモリデータベースを初期化中..."
        sqlite3 "$IGNITE_RUNTIME_DIR/state/memory.db" < "$IGNITE_SCRIPTS_DIR/schema.sql"
        sqlite3 "$IGNITE_RUNTIME_DIR/state/memory.db" "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;"
        # 既存DBのスキーママイグレーション（冪等）
        bash "$IGNITE_SCRIPTS_DIR/schema_migrate.sh" "$IGNITE_RUNTIME_DIR/state/memory.db"
    else
        print_warning "sqlite3 が見つかりません。メモリ機能は無効です。"
    fi

    # 初期ダッシュボードの作成
    print_info "初期ダッシュボードを作成中..."
    cat > "$IGNITE_RUNTIME_DIR/dashboard.md" <<EOF
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

    # .env ファイルの読み込み（存在する場合）
    local _env_file="$IGNITE_RUNTIME_DIR/.env"
    if [[ -f "$_env_file" ]]; then
        print_info ".env を読み込み中..."
        set -a
        # shellcheck source=/dev/null
        source "$_env_file"
        set +a
    else
        if [[ -f "$IGNITE_RUNTIME_DIR/.env.example" ]]; then
            print_warning ".env が見つかりません。API キーが必要な場合: cp .ignite/.env.example .ignite/.env"
        fi
    fi

    print_success "workspace初期化完了"
    echo ""

    # 旧デーモンプロセスをクリーンアップ（PIDファイルベース・セッション固有）
    if [[ -f "$IGNITE_RUNTIME_DIR/github_watcher.pid" ]]; then
        local old_pid
        old_pid=$(cat "$IGNITE_RUNTIME_DIR/github_watcher.pid")
        if kill -0 "$old_pid" 2>/dev/null; then
            kill "$old_pid" 2>/dev/null || true
        fi
        rm -f "$IGNITE_RUNTIME_DIR/github_watcher.pid"
    fi
    if [[ -f "$IGNITE_RUNTIME_DIR/queue_monitor.pid" ]]; then
        local old_pid
        old_pid=$(cat "$IGNITE_RUNTIME_DIR/queue_monitor.pid")
        if kill -0 "$old_pid" 2>/dev/null; then
            kill "$old_pid" 2>/dev/null || true
        fi
        rm -f "$IGNITE_RUNTIME_DIR/queue_monitor.pid"
    fi
    sleep "$(get_delay process_cleanup 1)"

    # --dry-run モード: Phase 1-5 完了後、tmux/CLI/Watcher/Monitor起動をスキップして終了
    if [[ "$dry_run" == true ]]; then
        # Phase 8: ランタイム情報ファイル生成（dry-runでも実行）
        print_info "ランタイム情報を保存中..."
        cat > "$IGNITE_RUNTIME_DIR/runtime.yaml" <<EOF
# IGNITE ランタイム情報（自動生成 - dry-run）
# このファイルはシステム起動時に自動的に更新されます

system:
  started_at: "$(date -Iseconds)"
  agent_mode: "${agent_mode}"
  session_name: "${SESSION_NAME}"
  workspace_dir: "${WORKSPACE_DIR}"
  dry_run: true

ignitians:
  count: 0
  ids: []
EOF

        echo ""
        print_success "[DRY-RUN] 初期化検証完了"
        echo ""
        echo "検証済み項目:"
        echo "  Phase 1: パラメータ解析 ... OK"
        echo "  Phase 2: セッション設定 ... OK"
        echo "  Phase 3: バリデーション ... OK"
        echo "  Phase 4: ディレクトリ/DB初期化 ... OK"
        echo "  Phase 5: PIDクリーンアップ ... OK"
        echo "  Phase 8: システム設定生成 ... OK"
        echo ""
        echo "スキップ項目:"
        echo "  Phase 6: tmuxセッション作成"
        echo "  Phase 7: AI CLI起動"
        echo "  Phase 9: Watcher/Monitor起動"
        echo ""
        # NOTE: Phase 2 self-hosted runner完全統合テストは別Issue（#134完了後）で対応予定
        exit 0
    fi

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

    # Bot Token: GH_TOKEN env var にはexportしない（stale化防止）
    # 理由: GitHub App Token有効期限1時間後にstale化→
    #   credential helper (gh auth git-credential) が失効GH_TOKENを優先参照→認証エラー
    # 代替: git操作はsafe_git_push/fetch/pull(github_helpers.sh)が動的にBot Token取得、
    #   API操作はgithub_api_get()/get_cached_bot_token()が都度取得
    # Bot Tokenキャッシュのプリウォーム（ファイルキャッシュのみ、env varにはセットしない）
    _resolve_bot_token >/dev/null 2>&1 || true
    local _gh_export=""

    # Leaderのインストラクションファイルを決定
    local instruction_file="$IGNITE_INSTRUCTIONS_DIR/leader.md"
    local character_file="$IGNITE_CHARACTERS_DIR/leader.md"
    if [[ "$agent_mode" == "leader" ]]; then
        instruction_file="$IGNITE_INSTRUCTIONS_DIR/leader-solo.md"
        character_file="$IGNITE_CHARACTERS_DIR/leader-solo.md"
        print_info "単独モード: $instruction_file を使用"
    fi

    # プロバイダー固有のプロジェクト設定を生成（インストラクションファイルを渡す）
    cli_setup_project_config "$WORKSPACE_DIR" "leader" "$character_file" "$instruction_file"

    local _launch_cmd
    _launch_cmd=$(cli_build_launch_command "$WORKSPACE_DIR" "" "$_gh_export" "leader")
    tmux send-keys -t "$SESSION_NAME:$TMUX_WINDOW_NAME" "$_launch_cmd" Enter

    # 起動待機（確認プロンプト表示を待つ）
    print_warning "Leaderの起動を待機中... (3秒)"
    sleep "$(get_delay leader_startup 3)"

    # 確認プロンプトを通過（プロバイダーが必要とする場合のみ）
    if cli_needs_permission_accept; then
        print_info "権限確認を承諾中..."
        tmux send-keys -t "$SESSION_NAME:$TMUX_WINDOW_NAME" Down
        sleep "$(get_delay permission_accept 0.5)"
        tmux send-keys -t "$SESSION_NAME:$TMUX_WINDOW_NAME" Enter
    fi

    # CLIの起動完了を待機
    print_warning "${CLI_COMMAND}の起動を待機中... (8秒)"
    sleep "$(get_delay cli_startup 8)"

    # Leaderにシステムプロンプトを読み込ませる（絶対パスを使用）
    print_info "Leaderシステムプロンプトをロード中..."
    local _leader_target="$SESSION_NAME:$TMUX_WINDOW_NAME"
    cli_wait_tui_ready "$_leader_target"

    if cli_needs_prompt_injection; then
        tmux send-keys -l -t "$_leader_target" \
            "以下のファイルを読んでください: $character_file と $instruction_file あなたはLeader（${LEADER_NAME}）として振る舞ってください。ワークスペースは $WORKSPACE_DIR です。起動時の初期化を行ってください。以降のメッセージ通知は queue_monitor が tmux 経由で送信します。instructions内の workspace/ は $WORKSPACE_DIR に、./scripts/utils/ は $IGNITE_SCRIPTS_DIR/utils/ に、config/ は $IGNITE_CONFIG_DIR/ に読み替えてください。"
    else
        # opencode: instructions は設定ファイル経由で読み込み済み。パス読み替え情報 + 起動トリガーを送信
        tmux send-keys -l -t "$_leader_target" \
            "あなたはLeader（${LEADER_NAME}）です。ワークスペースは $WORKSPACE_DIR です。起動時の初期化を行ってください。以降のメッセージ通知は queue_monitor が tmux 経由で送信します。instructions内の workspace/ は $WORKSPACE_DIR に、./scripts/utils/ は $IGNITE_SCRIPTS_DIR/utils/ に、config/ は $IGNITE_CONFIG_DIR/ に読み替えてください。"
    fi
    sleep "$(get_delay prompt_send 0.3)"
    eval "tmux send-keys -t '$_leader_target' $(cli_get_submit_keys)"

    # プロンプトロード完了を待機
    print_warning "Leaderの初期化を待機中... (10秒)"
    sleep "$(get_delay leader_init 10)"

    echo ""
    print_success "IGNITE Leader が起動しました"

    local parallel_slots="$START_PARALLEL_SLOTS"
    local parallel_timeout="$START_PARALLEL_TIMEOUT"
    if [[ -z "$parallel_slots" ]] || [[ "$parallel_slots" -lt 1 ]]; then
        parallel_slots=1
    fi

    _create_agent_pane() {
        local pane_name="$1"
        tmux split-window -t "$SESSION_NAME:$TMUX_WINDOW_NAME" -h
        tmux select-layout -t "$SESSION_NAME:$TMUX_WINDOW_NAME" tiled
        tmux set-option -t "$SESSION_NAME:$TMUX_WINDOW_NAME.$pane_name" -p @agent_name "$2"
    }

    local -a _job_pids=()
    declare -A _job_label=()
    declare -A _job_start=()
    local _job_success=0
    local _job_failed=0

    _start_job() {
        local label="$1"
        shift
        "$@" &
        local pid=$!
        _job_pids+=("$pid")
        _job_label["$pid"]="$label"
        _job_start["$pid"]="$(date +%s)"
    }

    _reap_jobs() {
        local -a remaining=()
        for pid in "${_job_pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                remaining+=("$pid")
            else
                wait "$pid"
                local rc=$?
                if [[ $rc -eq 0 ]]; then
                    _job_success=$(( _job_success + 1 ))
                else
                    _job_failed=$(( _job_failed + 1 ))
                    print_warning "${_job_label[$pid]} 起動失敗 (exit=${rc})"
                fi
            fi
        done
        _job_pids=("${remaining[@]}")
    }

    _check_job_timeouts() {
        local now
        now=$(date +%s)
        local -a remaining=()
        for pid in "${_job_pids[@]}"; do
            local started="${_job_start[$pid]}"
            local elapsed=$((now - started))
            if [[ $elapsed -ge $parallel_timeout ]]; then
                print_warning "${_job_label[$pid]} 起動タイムアウト (${elapsed}s)"
                kill "$pid" 2>/dev/null || true
                wait "$pid" 2>/dev/null || true
                _job_failed=$(( _job_failed + 1 ))
            else
                remaining+=("$pid")
            fi
        done
        _job_pids=("${remaining[@]}")
    }

    _wait_for_slot() {
        while [[ ${#_job_pids[@]} -ge $parallel_slots ]]; do
            sleep 1
            _reap_jobs
            _check_job_timeouts
        done
    }

    _wait_all_jobs() {
        while [[ ${#_job_pids[@]} -gt 0 ]]; do
            sleep 1
            _reap_jobs
            _check_job_timeouts
        done
    }

    # Sub-Leaders の起動 (agent_mode が leader 以外の場合)
    if [[ "$agent_mode" != "leader" ]]; then
        echo ""
        print_header "Sub-Leaders 起動"
        echo ""

        local pane_num=1
        print_info "Sub-Leaders 並列起動: slots=${parallel_slots}, timeout=${parallel_timeout}s"

        for i in "${!SUB_LEADERS[@]}"; do
            local role="${SUB_LEADERS[$i]}"
            local name="${SUB_LEADER_NAMES[$i]}"
            _create_agent_pane "$pane_num" "${name} (${role^})"
            _wait_for_slot
            _start_job "Sub-Leader ${name}" start_agent_in_pane "$role" "$name" "$pane_num" "$_gh_export"
            ((pane_num++))
        done

        _wait_all_jobs
        print_success "Sub-Leaders 起動完了 (${_job_success}/${#SUB_LEADERS[@]}名)"
    fi

    # IGNITIANs の起動 (worker_count > 0 かつ agent_mode が full の場合)
    local actual_ignitian_count=0
    if [[ "$worker_count" -gt 0 ]] && [[ "$agent_mode" == "full" ]]; then
        echo ""
        print_header "IGNITIANs 起動"
        echo ""

        # Sub-Leaders の後のペイン番号から開始
        local start_pane=$((1 + ${#SUB_LEADERS[@]}))

        print_info "IGNITIANs 並列起動: slots=${parallel_slots}, timeout=${parallel_timeout}s"
        _job_pids=()
        declare -A _job_label=()
        declare -A _job_start=()
        _job_success=0
        _job_failed=0

        for ((i=1; i<=worker_count; i++)); do
            local pane_num=$((start_pane + i - 1))
            _create_agent_pane "$pane_num" "IGNITIAN-${i}"
            _wait_for_slot
            _start_job "IGNITIAN-${i}" start_ignitian_in_pane "$i" "$pane_num" "$_gh_export"
        done

        _wait_all_jobs
        actual_ignitian_count=$_job_success
        print_success "IGNITIANs 起動完了 (${actual_ignitian_count}/${worker_count}並列)"
    fi

    # ランタイム情報ファイルを作成（IGNITIANs数などを記録）
    print_info "ランタイム情報を保存中..."
    cat > "$IGNITE_RUNTIME_DIR/runtime.yaml" <<EOF
# IGNITE ランタイム情報（自動生成）
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
    mkdir -p "$IGNITE_RUNTIME_DIR/costs/history"

    local started_timestamp
    started_timestamp=$(date -Iseconds)
    cat > "$IGNITE_RUNTIME_DIR/costs/sessions.yaml" <<EOF
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
    cat >> "$IGNITE_RUNTIME_DIR/costs/sessions.yaml" <<EOF
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
            cat >> "$IGNITE_RUNTIME_DIR/costs/sessions.yaml" <<EOF
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
        echo "" >> "$IGNITE_RUNTIME_DIR/costs/sessions.yaml"
        echo "ignitians:" >> "$IGNITE_RUNTIME_DIR/costs/sessions.yaml"
        for ((i=1; i<=actual_ignitian_count; i++)); do
            local pane=$((5 + i))
            cat >> "$IGNITE_RUNTIME_DIR/costs/sessions.yaml" <<EOF
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
            local watcher_log="$IGNITE_RUNTIME_DIR/logs/github_watcher.log"
            echo "========== ${SESSION_NAME} started at $(date -Iseconds) ==========" >> "$watcher_log"
            export IGNITE_WATCHER_CONFIG="$IGNITE_CONFIG_DIR/github-watcher.yaml"
            export IGNITE_WORKSPACE_DIR="$WORKSPACE_DIR"
            export WORKSPACE_DIR="$WORKSPACE_DIR"
            export IGNITE_RUNTIME_DIR="$IGNITE_RUNTIME_DIR"
            export IGNITE_CONFIG_DIR="$IGNITE_CONFIG_DIR"
            export IGNITE_TMUX_SESSION="$SESSION_NAME"
            "$IGNITE_SCRIPTS_DIR/utils/github_watcher.sh" >> "$watcher_log" 2>&1 &
            local watcher_pid=$!
            echo "$watcher_pid" > "$IGNITE_RUNTIME_DIR/github_watcher.pid"
            print_success "GitHub Watcher起動完了 (PID: $watcher_pid)"
            print_info "ログ: $watcher_log"
        else
            print_warning "github-watcher.yaml が見つかりません。Watcher起動をスキップ"
        fi
    fi

    # キューモニター起動（エージェント間通信に必須）
    print_info "キューモニターを起動中..."
    local queue_log="$IGNITE_RUNTIME_DIR/logs/queue_monitor.log"
    echo "========== ${SESSION_NAME} started at $(date -Iseconds) ==========" >> "$queue_log"
    export WORKSPACE_DIR="$WORKSPACE_DIR"
    export IGNITE_CONFIG_DIR="$IGNITE_CONFIG_DIR"
    export IGNITE_RUNTIME_DIR="$IGNITE_RUNTIME_DIR"
    "$IGNITE_SCRIPTS_DIR/utils/queue_monitor.sh" -s "$SESSION_NAME" >> "$queue_log" 2>&1 &
    local queue_pid=$!
    echo "$queue_pid" > "$IGNITE_RUNTIME_DIR/queue_monitor.pid"
    print_success "キューモニター起動完了 (PID: $queue_pid)"
    print_info "ログ: $queue_log"

    # daemonモード: PIDファイルを書き出して終了
    # systemd Type=forking との整合: このプロセスが終了後もtmuxセッションは残留する
    if [[ "$daemon_mode" == true ]]; then
        local pid_file="$IGNITE_RUNTIME_DIR/ignite-daemon.pid"
        echo $$ > "$pid_file"
        print_success "daemonモードで起動しました (PID: $$, session: $SESSION_NAME)"
        print_info "PIDファイル: $pid_file"
        exit 0
    fi

    # 自動アタッチ（対話環境のみ）
    if [[ "$no_attach" == false ]] && [[ -t 0 ]]; then
        read -p "tmuxセッションにアタッチしますか? (Y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            tmux attach -t "$SESSION_NAME"
        fi
    fi
}

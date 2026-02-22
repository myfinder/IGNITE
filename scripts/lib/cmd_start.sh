# shellcheck shell=bash
# lib/cmd_start.sh - startコマンド（ヘッドレス専用）
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

    # 非対話/NO_COLOR の場合はカラー出力を無効化（stderr含む）
    if [[ -n "${NO_COLOR:-}" ]] || ! [[ -t 1 ]] || ! [[ -t 2 ]]; then
        GREEN='' BLUE='' YELLOW='' RED='' CYAN='' BOLD='' NC=''
    fi

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
    START_PARALLEL_SLOTS="${IGNITE_START_PARALLEL_SLOTS:-0}"
    START_PARALLEL_TIMEOUT="${IGNITE_START_PARALLEL_TIMEOUT:-180}"

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

    # stale セッション YAML のクリーンアップ
    cleanup_stale_sessions "$WORKSPACE_DIR"

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

    # 既存のエージェントプロセスチェック
    local _existing_agents=false
    for _pid_file in "$IGNITE_RUNTIME_DIR"/state/.agent_pid_*; do
        [[ -f "$_pid_file" ]] || continue
        local _epid
        _epid=$(cat "$_pid_file" 2>/dev/null || true)
        if [[ -n "$_epid" ]] && kill -0 "$_epid" 2>/dev/null; then
            _existing_agents=true
            break
        fi
    done
    # セッションファイルのみ残存している場合も検出
    if [[ "$_existing_agents" == false ]]; then
        for _sf in "$IGNITE_RUNTIME_DIR"/state/.agent_session_*; do
            if [[ -f "$_sf" ]]; then
                _existing_agents=true
                break
            fi
        done
    fi

    # セッションのみ残存（PID プロセスなし）→ stale ステートをサイレントにクリーンアップ
    if [[ "$_existing_agents" == true ]]; then
        local _has_live_pid=false
        for _pid_file in "$IGNITE_RUNTIME_DIR"/state/.agent_pid_*; do
            [[ -f "$_pid_file" ]] || continue
            local _epid
            _epid=$(cat "$_pid_file" 2>/dev/null || true)
            if [[ -n "$_epid" ]] && kill -0 "$_epid" 2>/dev/null; then
                _has_live_pid=true; break
            fi
        done
        if [[ "$_has_live_pid" == false ]]; then
            log_info "stale セッションを検出、クリーンアップします"
            for _sf in "$IGNITE_RUNTIME_DIR"/state/.agent_session_*; do
                [[ -f "$_sf" ]] || continue
                local _cidx
                _cidx=$(basename "$_sf" | sed 's/\.agent_session_//')
                cli_cleanup_agent_state "$_cidx"
            done
            _existing_agents=false
        fi
    fi

    if [[ "$_existing_agents" == true ]]; then
        if [[ "$force" == true ]]; then
            print_warning "既存のエージェントプロセスを強制終了します"
            for _pid_file in "$IGNITE_RUNTIME_DIR"/state/.agent_pid_*; do
                [[ -f "$_pid_file" ]] || continue
                local _epid _pane_idx
                _epid=$(cat "$_pid_file" 2>/dev/null || true)
                _pane_idx=$(basename "$_pid_file" | sed 's/\.agent_pid_//')
                if [[ -n "$_epid" ]] && kill -0 "$_epid" 2>/dev/null; then
                    _kill_agent_process "$_pane_idx"
                fi
            done
            print_success "既存エージェントプロセスを終了しました"
        else
            print_warning "既存のエージェントプロセスが見つかりました"
            read -p "既存のプロセスを終了して再起動しますか? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                for _pid_file in "$IGNITE_RUNTIME_DIR"/state/.agent_pid_*; do
                    [[ -f "$_pid_file" ]] || continue
                    local _epid _pane_idx
                    _epid=$(cat "$_pid_file" 2>/dev/null || true)
                    _pane_idx=$(basename "$_pid_file" | sed 's/\.agent_pid_//')
                    if [[ -n "$_epid" ]] && kill -0 "$_epid" 2>/dev/null; then
                        _kill_agent_process "$_pane_idx"
                    fi
                done
                print_success "既存エージェントプロセスを終了しました"
            else
                print_info "既存のエージェントが稼働中です。ignite attach <agent> で接続できます。"
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
    # 孤立エージェントプロセスのクリーンアップ
    for _pid_file in "$IGNITE_RUNTIME_DIR"/state/.agent_pid_*; do
        [[ -f "$_pid_file" ]] || continue
        local old_pid _pane_idx
        old_pid=$(cat "$_pid_file" 2>/dev/null || true)
        _pane_idx=$(basename "$_pid_file" | sed 's/\.agent_pid_//')
        if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
            kill "$old_pid" 2>/dev/null || true
        fi
        cli_cleanup_agent_state "$_pane_idx"
    done
    sleep "$(get_delay process_cleanup 1)"

    # --dry-run モード
    if [[ "$dry_run" == true ]]; then
        # ランタイム情報ファイル生成（dry-runでも実行）
        print_info "ランタイム情報を保存中..."
        cat > "$IGNITE_RUNTIME_DIR/runtime.yaml" <<EOF
# IGNITE ランタイム情報（自動生成 - dry-run）
# このファイルはシステム起動時に自動的に更新されます

system:
  started_at: "$(date -Iseconds)"
  agent_mode: "${agent_mode}"
  session_name: "${SESSION_NAME}"
  workspace_dir: "${WORKSPACE_DIR}"
  startup_status: "complete"
  dry_run: true
  headless: true

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
        echo "  Phase 6: エージェントサーバー起動"
        echo "  Phase 7: AI CLI起動"
        echo "  Phase 9: Watcher/Monitor起動"
        echo ""
        exit 0
    fi

    # Bot Token キャッシュのプリウォーム
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

    # =========================================================================
    # 並列ジョブヘルパー
    # =========================================================================
    local parallel_slots="$START_PARALLEL_SLOTS"
    local parallel_timeout="$START_PARALLEL_TIMEOUT"
    if [[ -z "$parallel_slots" ]]; then
        parallel_slots=0
    fi

    local -a _job_pids=()
    declare -A _job_label=()
    declare -A _job_start=()
    declare -A _job_pane=()
    local _job_success=0
    local _job_failed=0

    _start_job() {
        local label="$1"
        local pane_num="$2"
        shift 2
        "$@" &
        local pid=$!
        _job_pids+=("$pid")
        _job_label["$pid"]="$label"
        _job_start["$pid"]="$(date +%s)"
        _job_pane["$pid"]="$pane_num"
    }

    _reap_jobs() {
        local -a remaining=()
        for pid in "${_job_pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                remaining+=("$pid")
            else
                wait "$pid" && local rc=0 || local rc=$?
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
                if [[ -n "${_job_pane[$pid]:-}" ]]; then
                    _kill_agent_process "${_job_pane[$pid]}"
                fi
                _job_failed=$(( _job_failed + 1 ))
            else
                remaining+=("$pid")
            fi
        done
        _job_pids=("${remaining[@]}")
    }

    _wait_for_slot() {
        [[ "$parallel_slots" -eq 0 ]] && return  # 0=無制限
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

    # =========================================================================
    # 全エージェント一括並列起動
    # =========================================================================
    local total_agents=1  # Leader
    if [[ "$agent_mode" != "leader" ]]; then
        total_agents=$((total_agents + ${#SUB_LEADERS[@]}))
    fi
    if [[ "$worker_count" -gt 0 ]] && [[ "$agent_mode" == "full" ]]; then
        total_agents=$((total_agents + worker_count))
    fi

    echo ""
    print_header "エージェント並列起動"
    print_info "並列起動: agents=${total_agents}, slots=${parallel_slots:-unlimited}, timeout=${parallel_timeout}s"
    echo ""

    # Leader (pane 0)
    _start_job "Leader ($LEADER_NAME)" 0 \
        start_agent_in_pane "leader" "$LEADER_NAME" 0 "$_gh_export" "$character_file" "$instruction_file"

    # Sub-Leaders (pane 1-N)
    if [[ "$agent_mode" != "leader" ]]; then
        local pane_num=1
        for i in "${!SUB_LEADERS[@]}"; do
            _wait_for_slot
            _start_job "Sub-Leader ${SUB_LEADER_NAMES[$i]}" "$pane_num" \
                start_agent_in_pane "${SUB_LEADERS[$i]}" "${SUB_LEADER_NAMES[$i]}" "$pane_num" "$_gh_export"
            ((pane_num++))
        done
    fi

    # IGNITIANs
    if [[ "$worker_count" -gt 0 ]] && [[ "$agent_mode" == "full" ]]; then
        local start_pane=$((1 + ${#SUB_LEADERS[@]}))
        for ((i=1; i<=worker_count; i++)); do
            _wait_for_slot
            _start_job "IGNITIAN-${i}" "$((start_pane + i - 1))" \
                start_ignitian_in_pane "$i" "$((start_pane + i - 1))" "$_gh_export"
        done
    fi

    _wait_all_jobs
    print_success "エージェント起動完了 (成功=${_job_success}/${total_agents}, 失敗=${_job_failed})"

    # ステートファイルからIGNITIANカウントを算出（全プロバイダー統一: session_id ベース）
    local actual_ignitian_count=0
    if [[ "$worker_count" -gt 0 ]] && [[ "$agent_mode" == "full" ]]; then
        local start_pane=$((1 + ${#SUB_LEADERS[@]}))
        for ((i=0; i<worker_count; i++)); do
            local _pane=$((start_pane + i))
            if [[ -f "$IGNITE_RUNTIME_DIR/state/.agent_session_${_pane}" ]]; then
                local _sid
                _sid=$(cat "$IGNITE_RUNTIME_DIR/state/.agent_session_${_pane}" 2>/dev/null || true)
                [[ -n "$_sid" ]] && actual_ignitian_count=$((actual_ignitian_count + 1))
            fi
        done
    fi

    # =========================================================================
    # ポスト起動リカバリ: 全エージェントをチェックし、スタックしたエージェントを復旧
    # =========================================================================
    _verify_agent_prompt() {
        local pane_idx="$1"

        # 全プロバイダー統一: セッション ID ベースで判定
        cli_check_session_alive "$pane_idx"
    }

    # リカバリ用関数: エージェントタイプに応じた再起動
    _recover_agent() {
        local _pidx="$1"
        local _agent_mode="$2"
        local _gh_export="$3"
        local _recovery_max_attempts="$4"
        local _recovery_wait="$5"

        local _agent_name_recov
        cli_load_agent_state "$_pidx"
        _agent_name_recov="${_AGENT_NAME:-agent ${_pidx}}"

        local _attempt=0
        while [[ $_attempt -lt $_recovery_max_attempts ]]; do
            _attempt=$((_attempt + 1))
            print_info "  リカバリ試行 ${_attempt}/${_recovery_max_attempts} (agent ${_pidx}: ${_agent_name_recov})..."
            _kill_agent_process "$_pidx" || true
            sleep "$_recovery_wait"

            # エージェントタイプに応じた再起動（失敗しても続行）
            if [[ $_pidx -eq 0 ]]; then
                restart_leader_in_pane "$_agent_mode" "$_gh_export" || true
            elif [[ $_pidx -ge 1 ]] && [[ $_pidx -le ${#SUB_LEADERS[@]} ]]; then
                local _sl_idx=$((_pidx - 1))
                local _sl_role="${SUB_LEADERS[$_sl_idx]}"
                local _sl_name="${SUB_LEADER_NAMES[$_sl_idx]}"
                restart_agent_in_pane "$_sl_role" "$_sl_name" "$_pidx" "$_gh_export" || true
            else
                local _ig_id=$((_pidx - ${#SUB_LEADERS[@]}))
                restart_ignitian_in_pane "$_ig_id" "$_pidx" "$_gh_export" || true
            fi

            sleep "$(get_delay leader_init 10)"

            if _verify_agent_prompt "$_pidx" 2>/dev/null; then
                print_success "  agent ${_pidx} (${_agent_name_recov}) リカバリ成功"
                return 0
            fi
        done

        print_error "  agent ${_pidx} (${_agent_name_recov}) リカバリ失敗（${_recovery_max_attempts}回試行）"
        return 1
    }

    # リカバリ設定を読み込み
    local _recovery_max_attempts=2
    local _recovery_wait=15
    local sys_yaml="${IGNITE_CONFIG_DIR}/system.yaml"
    if [[ -f "$sys_yaml" ]]; then
        local _val
        _val=$(sed -n '/^health:/,/^[^ ]/p' "$sys_yaml" | awk -F': ' '/^  recovery_max_attempts:/{print $2; exit}' | sed 's/ *#.*//' | xargs)
        _recovery_max_attempts="${_val:-2}"
        _val=$(sed -n '/^health:/,/^[^ ]/p' "$sys_yaml" | awk -F': ' '/^  recovery_wait:/{print $2; exit}' | sed 's/ *#.*//' | xargs)
        _recovery_wait="${_val:-15}"
    fi

    local _startup_status="complete"
    local _session_target="$SESSION_NAME"

    # 全エージェントのリカバリチェック（セッションファイルベース）
    local _total_agents=0
    local -a _agent_indices=()
    for _session_file in "$IGNITE_RUNTIME_DIR"/state/.agent_session_*; do
        [[ -f "$_session_file" ]] || continue
        local _aidx
        _aidx=$(basename "$_session_file" | sed 's/\.agent_session_//')
        _agent_indices+=("$_aidx")
        _total_agents=$((_total_agents + 1))
    done

    if [[ "$_total_agents" -gt 0 ]]; then
        echo ""
        print_info "ポスト起動チェック: ${_total_agents} エージェントを検証中..."

        # ERR trap を一時退避してリカバリ中は無効化
        trap - ERR

        # 1. 異常エージェントを特定（順次、軽量チェック）
        local -a _failed_agents=()
        for _pidx in "${_agent_indices[@]}"; do
            if ! _verify_agent_prompt "$_pidx" 2>/dev/null; then
                _failed_agents+=("$_pidx")
            fi
        done

        # 2. リカバリを並列実行
        if [[ ${#_failed_agents[@]} -gt 0 ]]; then
            print_warning "${#_failed_agents[@]} エージェントに異常検出、リカバリ中..."

            # ジョブヘルパーをリセット（連想配列は再宣言が必要）
            _job_pids=()
            unset _job_label _job_start _job_pane
            declare -A _job_label=()
            declare -A _job_start=()
            declare -A _job_pane=()
            _job_success=0
            _job_failed=0

            for _pidx in "${_failed_agents[@]}"; do
                local _agent_name_recov
                cli_load_agent_state "$_pidx"
                _agent_name_recov="${_AGENT_NAME:-agent ${_pidx}}"
                _wait_for_slot
                _start_job "Recovery ${_agent_name_recov}" "$_pidx" \
                    _recover_agent "$_pidx" "$agent_mode" "$_gh_export" "$_recovery_max_attempts" "$_recovery_wait"
            done

            _wait_all_jobs

            if [[ $_job_failed -gt 0 ]]; then
                _startup_status="partial"
            fi
        fi

        # ERR trap を復元
        trap 'print_error "エラーが発生しました (line $LINENO)"' ERR
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
  startup_status: "${_startup_status}"
  headless: true

ignitians:
  count: ${actual_ignitian_count}
  ids: [$(seq -s ', ' 1 ${actual_ignitian_count} 2>/dev/null || echo "")]
EOF

    # セッション→ワークスペースのマッピングを保存（stop時の自動検出用）
    local _sl_count=${#SUB_LEADERS[@]}
    [[ "$agent_mode" == "leader" ]] && _sl_count=0
    mkdir -p "$IGNITE_CONFIG_DIR/sessions"
    cat > "$IGNITE_CONFIG_DIR/sessions/${SESSION_NAME}.yaml" <<EOF
# IGNITE セッション情報（自動生成）
session_name: "${SESSION_NAME}"
workspace_dir: "${WORKSPACE_DIR}"
started_at: "$(date -Iseconds)"
mode: "${agent_mode}"
agents_total: $((1 + _sl_count + worker_count))
agents_actual: $((1 + _sl_count + actual_ignitian_count))
EOF

    # ワークスペースを workspaces.list に登録（cross-workspace list 用）
    register_workspace "$WORKSPACE_DIR"

    echo ""
    print_header "起動完了"
    echo ""
    echo "次のステップ:"
    echo -e "  1. エージェントに接続: ${YELLOW}ignite attach <agent>${NC}"
    echo -e "  2. ダッシュボード確認: ${YELLOW}ignite status${NC}"
    echo -e "  3. ログ確認: ${YELLOW}ignite logs${NC}"
    echo -e "  4. タスク投入: ${YELLOW}ignite plan \"目標\"${NC}"
    echo ""
    echo "システム操作:"
    echo -e "  - セッション終了: ${YELLOW}ignite stop${NC}"
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
            local watcher_log="$IGNITE_RUNTIME_DIR/logs/github_watcher.log"
            echo "========== ${SESSION_NAME} started at $(date -Iseconds) ==========" >> "$watcher_log"
            export IGNITE_WATCHER_CONFIG="$IGNITE_CONFIG_DIR/github-watcher.yaml"
            export IGNITE_WORKSPACE_DIR="$WORKSPACE_DIR"
            export WORKSPACE_DIR="$WORKSPACE_DIR"
            export IGNITE_RUNTIME_DIR="$IGNITE_RUNTIME_DIR"
            export IGNITE_CONFIG_DIR="$IGNITE_CONFIG_DIR"
            export IGNITE_SESSION="$SESSION_NAME"
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
    # daemon モード + systemd monitor サービスが有効な場合はスキップ
    # （systemd の ignite-monitor@.service が管理するため二重起動を防止）
    local _skip_monitor=false
    if [[ "$daemon_mode" == true ]]; then
        local _session_short="${SESSION_NAME#ignite-}"
        if systemctl --user is-enabled "ignite-monitor@${_session_short}.service" &>/dev/null; then
            _skip_monitor=true
            print_info "キューモニターは systemd (ignite-monitor@${_session_short}) が管理します"
        fi
    fi

    if [[ "$_skip_monitor" == false ]]; then
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
    fi

    # daemonモード: PIDファイルを書き出して終了
    if [[ "$daemon_mode" == true ]]; then
        local pid_file="$IGNITE_RUNTIME_DIR/ignite-daemon.pid"
        echo $$ > "$pid_file"
        print_success "daemonモードで起動しました (PID: $$, session: $SESSION_NAME)"
        print_info "PIDファイル: $pid_file"
        exit 0
    fi

    # ヘッドレスモードで起動完了
    print_info "ヘッドレスモードで起動完了。ignite attach <agent> で接続できます。"
}

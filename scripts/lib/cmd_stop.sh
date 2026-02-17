# shellcheck shell=bash
# lib/cmd_stop.sh - stopコマンド
[[ -n "${__LIB_CMD_STOP_LOADED:-}" ]] && return; __LIB_CMD_STOP_LOADED=1

cmd_stop() {
    local skip_confirm=false

    # オプション解析
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes) skip_confirm=true; shift ;;
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
            -h|--help) cmd_help stop; exit 0 ;;
            *) print_error "Unknown option: $1"; cmd_help stop; exit 1 ;;
        esac
    done

    # ワークスペース解決 → 設定ロード → セッション名解決
    setup_workspace
    setup_workspace_config "$WORKSPACE_DIR"
    setup_session_name

    print_header "IGNITE システム停止"
    echo ""
    echo -e "${BLUE}対象セッション:${NC} $SESSION_NAME"
    echo ""

    # セッションの存在確認
    if ! session_exists; then
        print_error "セッション '$SESSION_NAME' が見つかりません"
        echo ""
        print_info "実行中のセッション一覧:"
        list_sessions 2>/dev/null || true
        exit 1
    fi

    # 確認（非対話環境ではスキップ）
    if [[ "$skip_confirm" == false ]] && [[ -t 0 ]]; then
        read -p "IGNITE システムを停止しますか? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_warning "キャンセルしました"
            exit 0
        fi
    fi

    # GitHub Watcher を停止
    if [[ -f "$IGNITE_RUNTIME_DIR/github_watcher.pid" ]]; then
        local watcher_pid
        watcher_pid=$(cat "$IGNITE_RUNTIME_DIR/github_watcher.pid")
        if kill -0 "$watcher_pid" 2>/dev/null; then
            print_info "GitHub Watcherを停止中..."
            kill "$watcher_pid" 2>/dev/null || true
            # プロセス終了を最大3秒待機
            local wait_count=0
            while kill -0 "$watcher_pid" 2>/dev/null && [[ $wait_count -lt 6 ]]; do
                sleep 0.5
                wait_count=$((wait_count + 1))
            done
            if kill -0 "$watcher_pid" 2>/dev/null; then
                kill -9 "$watcher_pid" 2>/dev/null || true
            fi
            print_success "GitHub Watcher停止完了"
        fi
        rm -f "$IGNITE_RUNTIME_DIR/github_watcher.pid"
    fi

    # キューモニターを停止
    if [[ -f "$IGNITE_RUNTIME_DIR/queue_monitor.pid" ]]; then
        local queue_pid
        queue_pid=$(cat "$IGNITE_RUNTIME_DIR/queue_monitor.pid")
        if kill -0 "$queue_pid" 2>/dev/null; then
            print_info "キューモニターを停止中..."
            kill "$queue_pid" 2>/dev/null || true
            # プロセス終了を最大3秒待機
            local wait_count=0
            while kill -0 "$queue_pid" 2>/dev/null && [[ $wait_count -lt 6 ]]; do
                sleep 0.5
                wait_count=$((wait_count + 1))
            done
            if kill -0 "$queue_pid" 2>/dev/null; then
                kill -9 "$queue_pid" 2>/dev/null || true
            fi
            print_success "キューモニター停止完了"
        fi
        rm -f "$IGNITE_RUNTIME_DIR/queue_monitor.pid"
    fi

    # エージェントプロセス停止（PID ベース）
    print_warning "エージェントプロセスを停止中..."
    for pid_file in "$IGNITE_RUNTIME_DIR/state"/.agent_pid_*; do
        [[ -f "$pid_file" ]] || continue
        local pid
        pid=$(cat "$pid_file" 2>/dev/null || true)
        if [[ -n "$pid" ]] && _validate_pid "$pid" "opencode"; then
            pkill -P "$pid" 2>/dev/null || true
            kill "$pid" 2>/dev/null || true
            local i
            for i in {1..6}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
            if kill -0 "$pid" 2>/dev/null; then
                pkill -9 -P "$pid" 2>/dev/null || true
                kill -9 "$pid" 2>/dev/null || true
            fi
        fi
        rm -f "$pid_file"
    done
    # PID ファイルに載っていない孤立プロセスも掃除
    local _orphan_pids=""
    _orphan_pids=$(pgrep -f "opencode serve.*--print-logs" 2>/dev/null | while read -r _op; do
        # このワークスペースに属するプロセスのみ対象
        if grep -qsF "$WORKSPACE_DIR" "/proc/$_op/environ" 2>/dev/null; then
            echo "$_op"
        fi
    done) || true
    if [[ -n "$_orphan_pids" ]]; then
        echo "$_orphan_pids" | xargs kill 2>/dev/null || true
        sleep 1
        echo "$_orphan_pids" | while read -r _op; do
            kill -0 "$_op" 2>/dev/null && kill -9 "$_op" 2>/dev/null || true
        done
    fi
    rm -f "$IGNITE_RUNTIME_DIR/state"/.agent_{port,session,name}_*
    rm -f "$IGNITE_RUNTIME_DIR/state"/.send_lock_*
    print_success "エージェントプロセスを停止しました"

    # セッション情報ファイルを削除
    rm -f "$IGNITE_CONFIG_DIR/sessions/${SESSION_NAME}.yaml"
    rm -f "$IGNITE_RUNTIME_DIR/ignite-daemon.pid"

    print_success "IGNITE システムを停止しました"
}

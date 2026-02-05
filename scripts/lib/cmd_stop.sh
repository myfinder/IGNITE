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
            -h|--help) cmd_help stop; exit 0 ;;
            *) print_error "Unknown option: $1"; cmd_help stop; exit 1 ;;
        esac
    done

    # セッション名を設定
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

    # 確認
    if [[ "$skip_confirm" == false ]]; then
        read -p "IGNITE システムを停止しますか? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_warning "キャンセルしました"
            exit 0
        fi
    fi

    # セッション情報からワークスペースを自動検出
    local session_info="$IGNITE_CONFIG_DIR/sessions/${SESSION_NAME}.yaml"
    if [[ -f "$session_info" ]]; then
        WORKSPACE_DIR=$(grep "^workspace_dir:" "$session_info" | awk '{print $2}' | tr -d '"')
    fi
    # フォールバック
    if [[ -z "$WORKSPACE_DIR" ]]; then
        setup_workspace
    fi

    # GitHub Watcher を停止
    if [[ -f "$WORKSPACE_DIR/github_watcher.pid" ]]; then
        local watcher_pid
        watcher_pid=$(cat "$WORKSPACE_DIR/github_watcher.pid")
        if kill -0 "$watcher_pid" 2>/dev/null; then
            print_info "GitHub Watcherを停止中..."
            kill "$watcher_pid" 2>/dev/null || true
            print_success "GitHub Watcher停止完了"
        fi
        rm -f "$WORKSPACE_DIR/github_watcher.pid"
    fi

    # キューモニターを停止
    if [[ -f "$WORKSPACE_DIR/queue_monitor.pid" ]]; then
        local queue_pid
        queue_pid=$(cat "$WORKSPACE_DIR/queue_monitor.pid")
        if kill -0 "$queue_pid" 2>/dev/null; then
            print_info "キューモニターを停止中..."
            kill "$queue_pid" 2>/dev/null || true
            print_success "キューモニター停止完了"
        fi
        rm -f "$WORKSPACE_DIR/queue_monitor.pid"
    fi

    # コスト履歴を保存
    save_cost_history

    # セッション終了
    print_warning "tmuxセッションを終了中..."
    tmux kill-session -t "$SESSION_NAME"

    # セッション情報ファイルを削除
    rm -f "$IGNITE_CONFIG_DIR/sessions/${SESSION_NAME}.yaml"

    print_success "IGNITE システムを停止しました"
}

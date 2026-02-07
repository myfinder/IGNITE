# shellcheck shell=bash
# lib/cmd_status.sh - statusコマンド
[[ -n "${__LIB_CMD_STATUS_LOADED:-}" ]] && return; __LIB_CMD_STATUS_LOADED=1

source "${LIB_DIR}/health_check.sh"

cmd_status() {
    # オプション解析
    while [[ $# -gt 0 ]]; do
        case "$1" in
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
            -h|--help) cmd_help status; exit 0 ;;
            *) print_error "Unknown option: $1"; cmd_help status; exit 1 ;;
        esac
    done

    # セッション名とワークスペースを設定
    setup_session_name
    setup_workspace

    cd "$WORKSPACE_DIR" || return 1

    print_header "IGNITE システム状態"
    echo ""
    echo -e "${BLUE}IGNITEバージョン:${NC} v$VERSION"
    echo -e "${BLUE}セッション:${NC} $SESSION_NAME"
    echo -e "${BLUE}ワークスペース:${NC} $WORKSPACE_DIR"
    echo ""

    # tmuxセッション確認
    if session_exists; then
        print_success "tmuxセッション: 実行中"

        # ペイン数確認
        local pane_count
        pane_count=$(tmux list-panes -t "$SESSION_NAME" 2>/dev/null | wc -l)
        echo -e "${BLUE}  ペイン数: ${pane_count}${NC}"

        # エージェント状態（3層ヘルスチェック）
        echo ""
        print_header "エージェント状態"
        echo ""
        local _health_line
        while IFS= read -r _health_line; do
            [[ -z "$_health_line" ]] && continue
            local _pane_idx _agent_name _status
            IFS=':' read -r _pane_idx _agent_name _status <<< "$_health_line"
            local _formatted
            _formatted=$(format_health_status "$_status")
            echo -e "  ${_formatted} pane ${_pane_idx}: ${_agent_name}"
        done < <(get_all_agents_health "$SESSION_NAME:$TMUX_WINDOW_NAME")
    else
        print_error "tmuxセッション: 停止"
        exit 1
    fi

    echo ""

    # ダッシュボード表示
    if [[ -f "$WORKSPACE_DIR/dashboard.md" ]]; then
        print_header "ダッシュボード"
        echo ""
        cat "$WORKSPACE_DIR/dashboard.md"
        echo ""
    else
        print_warning "ダッシュボードが見つかりません"
    fi

    # キュー状態
    print_header "キュー状態"
    echo ""

    for queue_dir in "$WORKSPACE_DIR/queue"/*; do
        if [[ -d "$queue_dir" ]]; then
            local queue_name
            queue_name=$(basename "$queue_dir")
            [[ "$queue_name" == "dead_letter" ]] && continue
            local message_count
            message_count=$(find "$queue_dir" -maxdepth 1 -name "*.yaml" -type f 2>/dev/null | wc -l)

            if [[ "$message_count" -gt 0 ]]; then
                echo -e "${YELLOW}  $queue_name: $message_count メッセージ（未処理）${NC}"
            else
                echo -e "${GREEN}  $queue_name: 0 メッセージ${NC}"
            fi
        fi
    done

    echo ""

    # GitHub Watcher状態
    print_header "GitHub Watcher"
    if [[ -f "$WORKSPACE_DIR/github_watcher.pid" ]]; then
        local watcher_pid
        watcher_pid=$(cat "$WORKSPACE_DIR/github_watcher.pid")
        if kill -0 "$watcher_pid" 2>/dev/null; then
            print_success "GitHub Watcher: 実行中 (PID: $watcher_pid)"
        else
            print_warning "GitHub Watcher: 停止（PIDファイルあり）"
        fi
    else
        print_info "GitHub Watcher: 未起動"
    fi

    # キューモニター状態
    print_header "キューモニター"
    if [[ -f "$WORKSPACE_DIR/queue_monitor.pid" ]]; then
        local queue_pid
        queue_pid=$(cat "$WORKSPACE_DIR/queue_monitor.pid")
        if kill -0 "$queue_pid" 2>/dev/null; then
            print_success "キューモニター: 実行中 (PID: $queue_pid)"
        else
            print_warning "キューモニター: 停止（PIDファイルあり）"
        fi
    else
        print_info "キューモニター: 未起動"
    fi
    echo ""

    # 最新ログ
    print_header "最新ログ (直近5件)"
    echo ""

    if [[ -d "$WORKSPACE_DIR/logs" ]] && [[ "$(ls -A "$WORKSPACE_DIR/logs" 2>/dev/null)" ]]; then
        for log_file in "$WORKSPACE_DIR/logs"/*.log; do
            if [[ -f "$log_file" ]]; then
                echo -e "${BLUE}$(basename "$log_file"):${NC}"
                tail -n 5 "$log_file" 2>/dev/null | sed 's/^/  /'
                echo ""
            fi
        done
    else
        print_warning "ログファイルなし"
        echo ""
    fi

    print_header "コマンド"
    echo -e "  ダッシュボード監視: ${YELLOW}watch -n 5 cat $WORKSPACE_DIR/dashboard.md${NC}"
    echo -e "  tmuxアタッチ: ${YELLOW}./scripts/ignite attach -s $SESSION_NAME${NC}"
    echo -e "  システム停止: ${YELLOW}./scripts/ignite stop -s $SESSION_NAME${NC}"
}

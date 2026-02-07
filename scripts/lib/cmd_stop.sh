# shellcheck shell=bash
# lib/cmd_stop.sh - stopコマンド
[[ -n "${__LIB_CMD_STOP_LOADED:-}" ]] && return; __LIB_CMD_STOP_LOADED=1

# 日次レポートを close するラッパー（失敗してもセッション停止をブロックしない）
close_daily_reports() {
    local daily_report_script="${LIB_DIR}/../utils/daily_report.sh"
    if [[ ! -x "$daily_report_script" ]]; then
        # インストールモードの場合のパスも確認
        local xdg_data="${XDG_DATA_HOME:-$HOME/.local/share}"
        daily_report_script="$xdg_data/ignite/scripts/utils/daily_report.sh"
    fi

    if [[ -x "$daily_report_script" ]]; then
        print_info "日次レポートを close 中..."
        if WORKSPACE_DIR="$WORKSPACE_DIR" IGNITE_CONFIG_DIR="$IGNITE_CONFIG_DIR" "$daily_report_script" close-all 2>/dev/null; then
            print_success "日次レポートを close しました"
        else
            print_warning "日次レポートの close に失敗しました（スキップ）"
        fi
    fi
}

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

    # 確認（非対話環境ではスキップ）
    if [[ "$skip_confirm" == false ]] && [[ -t 0 ]]; then
        read -p "IGNITE システムを停止しますか? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_warning "キャンセルしました"
            exit 0
        fi
    fi

    # ワークスペース解決: -w 指定 > セッション情報 > デフォルト
    if [[ -z "$WORKSPACE_DIR" ]]; then
        local session_info="$IGNITE_CONFIG_DIR/sessions/${SESSION_NAME}.yaml"
        if [[ -f "$session_info" ]]; then
            WORKSPACE_DIR=$(grep "^workspace_dir:" "$session_info" | awk '{print $2}' | tr -d '"')
        fi
    fi
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
        rm -f "$WORKSPACE_DIR/github_watcher.pid"
    fi

    # キューモニターを停止
    if [[ -f "$WORKSPACE_DIR/queue_monitor.pid" ]]; then
        local queue_pid
        queue_pid=$(cat "$WORKSPACE_DIR/queue_monitor.pid")
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
        rm -f "$WORKSPACE_DIR/queue_monitor.pid"
    fi

    # フォールバック: PIDファイルが消えていてもプロセスが残っている場合
    pkill -f "queue_monitor.sh.*${SESSION_NAME}" 2>/dev/null || true
    pkill -f "github_watcher.sh" 2>/dev/null || true

    # コスト履歴を保存
    save_cost_history

    # 日次レポートを close（ベストエフォート）
    close_daily_reports

    # セッション終了
    print_warning "tmuxセッションを終了中..."
    tmux kill-session -t "$SESSION_NAME"

    # セッション情報ファイルを削除
    rm -f "$IGNITE_CONFIG_DIR/sessions/${SESSION_NAME}.yaml"

    print_success "IGNITE システムを停止しました"
}

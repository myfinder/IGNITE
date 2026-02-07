# shellcheck shell=bash
# lib/commands.sh - その他コマンド群（activate, notify, attach, logs, clean, list, watcher）
[[ -n "${__LIB_COMMANDS_LOADED:-}" ]] && return; __LIB_COMMANDS_LOADED=1

# =============================================================================
# activate コマンド - 起動済みエージェントのアクティベート
# =============================================================================

cmd_activate() {
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
            -h|--help) cmd_help activate; exit 0 ;;
            *) print_error "Unknown option: $1"; cmd_help activate; exit 1 ;;
        esac
    done

    # セッション名を設定
    setup_session_name

    if ! session_exists; then
        print_error "セッション '$SESSION_NAME' が見つかりません"
        echo ""
        print_info "実行中のセッション一覧:"
        list_sessions 2>/dev/null || true
        exit 1
    fi

    print_header "エージェントをアクティベート中"
    echo ""
    echo -e "${BLUE}セッション:${NC} $SESSION_NAME"
    echo ""

    # ペイン数を確認
    local pane_count
    pane_count=$(tmux list-panes -t "$SESSION_NAME" 2>/dev/null | wc -l)

    print_info "検出されたペイン数: $pane_count"

    # 各paneに対してEnterを送信して、入力待ちのコマンドを実行
    for ((i=1; i<pane_count; i++)); do
        print_info "pane $i をアクティベート中..."
        tmux send-keys -t "$SESSION_NAME:ignite.$i" Enter
        sleep 1
    done

    print_success "全エージェントにアクティベーション信号を送信しました"
    echo ""
    echo "各エージェントがシステムプロンプトを読み込んでいます。"
    echo -e "状態確認: ${YELLOW}./scripts/ignite status -s $SESSION_NAME${NC}"
}

# =============================================================================
# notify コマンド - 特定のエージェントにメッセージを送信
# =============================================================================

cmd_notify() {
    local target=""
    local message=""

    # 引数解析
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
            -h|--help) cmd_help notify; exit 0 ;;
            *)
                if [[ -z "$target" ]]; then
                    target="$1"
                elif [[ -z "$message" ]]; then
                    message="$1"
                fi
                shift
                ;;
        esac
    done

    # セッション名とワークスペースを設定
    setup_session_name
    setup_workspace

    if [[ -z "$target" ]] || [[ -z "$message" ]]; then
        print_error "ターゲットとメッセージを指定してください"
        echo "使用方法: ./scripts/ignite notify <target> \"message\""
        echo "ターゲット: leader, strategist, architect, evaluator, coordinator, innovator, ignitian_{n}"
        exit 1
    fi

    # ターゲットの正規化（ハイフン形式をアンダースコア形式に）
    case "$target" in
        ignitian-*)
            target="${target//-/_}"
            ;;
    esac

    # ペイン番号を特定
    local pane_num=""
    case "$target" in
        leader) pane_num=0 ;;
        strategist) pane_num=1 ;;
        architect) pane_num=2 ;;
        evaluator) pane_num=3 ;;
        coordinator) pane_num=4 ;;
        innovator) pane_num=5 ;;
        ignitian_*)
            local num=${target#ignitian_}
            if [[ ! "$num" =~ ^[0-9]+$ ]]; then
                print_error "無効なIGNITIANターゲット: $target"
                exit 1
            fi
            pane_num=$((num + 5))
            ;;
        *)
            print_error "不明なターゲット: $target"
            echo "有効なターゲット: leader, strategist, architect, evaluator, coordinator, innovator, ignitian_{n}"
            exit 1
            ;;
    esac

    if ! session_exists; then
        print_error "セッション '$SESSION_NAME' が見つかりません"
        echo ""
        print_info "実行中のセッション一覧:"
        list_sessions 2>/dev/null || true
        exit 1
    fi

    # ペインの存在確認
    local pane_count
    pane_count=$(tmux list-panes -t "$SESSION_NAME:ignite" 2>/dev/null | wc -l)
    if [[ "$pane_num" -ge "$pane_count" ]]; then
        print_error "ターゲット '${target}' のペイン (${pane_num}) が存在しません（ペイン数: ${pane_count}）"
        exit 1
    fi

    cd "$WORKSPACE_DIR" || return 1

    # メッセージファイル作成
    local timestamp
    timestamp=$(date -Iseconds)
    local message_id
    message_id=$(date +%s%6N)
    local escaped_message="${message//\"/\\\"}"
    mkdir -p "$WORKSPACE_DIR/queue/${target}/processed"
    local message_file="$WORKSPACE_DIR/queue/${target}/processed/notify_${message_id}.yaml"

    cat > "$message_file" <<EOF
type: notification
from: user
to: ${target}
timestamp: "${timestamp}"
priority: normal
payload:
  message: "${escaped_message}"
EOF

    print_success "メッセージを送信しました: $message_file"

    tmux send-keys -t "$SESSION_NAME:ignite.$pane_num" \
        "$WORKSPACE_DIR/queue/${target}/processed/ に新しいメッセージがあります。${message_file} を確認してください。" Enter

    print_success "pane $pane_num に通知を送信しました"
}

# =============================================================================
# attach コマンド - tmuxセッションに接続
# =============================================================================

cmd_attach() {
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
            -h|--help) cmd_help attach; exit 0 ;;
            *) print_error "Unknown option: $1"; cmd_help attach; exit 1 ;;
        esac
    done

    # セッション名を設定
    setup_session_name

    if ! session_exists; then
        print_error "セッション '$SESSION_NAME' が見つかりません"
        echo ""
        print_info "実行中のセッション一覧:"
        list_sessions 2>/dev/null || true
        echo -e "${YELLOW}先に起動してください: ./scripts/ignite start${NC}"
        exit 1
    fi

    tmux attach -t "$SESSION_NAME"
}

# =============================================================================
# logs コマンド - ログ表示
# =============================================================================

cmd_logs() {
    local follow=false
    local lines=20

    # オプション解析
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--follow) follow=true; shift ;;
            -n|--lines) lines="$2"; shift 2 ;;
            -w|--workspace)
                WORKSPACE_DIR="$2"
                if [[ ! "$WORKSPACE_DIR" = /* ]]; then
                    WORKSPACE_DIR="$(pwd)/$WORKSPACE_DIR"
                fi
                shift 2
                ;;
            -h|--help) cmd_help logs; exit 0 ;;
            *) print_error "Unknown option: $1"; cmd_help logs; exit 1 ;;
        esac
    done

    # ワークスペースを設定
    setup_workspace

    cd "$WORKSPACE_DIR" || return 1

    if [[ ! -d "$WORKSPACE_DIR/logs" ]] || [[ -z "$(ls -A "$WORKSPACE_DIR/logs" 2>/dev/null)" ]]; then
        print_warning "ログファイルが見つかりません"
        exit 0
    fi

    if [[ "$follow" == true ]]; then
        print_info "ログをリアルタイム監視中... (Ctrl+C で終了)"
        tail -f "$WORKSPACE_DIR/logs"/*.log 2>/dev/null
    else
        print_header "ログ (直近${lines}行)"
        echo ""
        for log_file in "$WORKSPACE_DIR/logs"/*.log; do
            if [[ -f "$log_file" ]]; then
                echo -e "${BLUE}=== $(basename "$log_file") ===${NC}"
                tail -n "$lines" "$log_file" 2>/dev/null
                echo ""
            fi
        done
    fi
}

# =============================================================================
# clean コマンド - workspaceクリア
# =============================================================================

cmd_clean() {
    local skip_confirm=false

    # オプション解析
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes) skip_confirm=true; shift ;;
            -w|--workspace)
                WORKSPACE_DIR="$2"
                if [[ ! "$WORKSPACE_DIR" = /* ]]; then
                    WORKSPACE_DIR="$(pwd)/$WORKSPACE_DIR"
                fi
                shift 2
                ;;
            -s|--session)
                SESSION_NAME="$2"
                if [[ ! "$SESSION_NAME" =~ ^ignite- ]]; then
                    SESSION_NAME="ignite-$SESSION_NAME"
                fi
                shift 2
                ;;
            -h|--help) cmd_help clean; exit 0 ;;
            *) print_error "Unknown option: $1"; cmd_help clean; exit 1 ;;
        esac
    done

    # セッション名とワークスペースを設定
    setup_session_name
    setup_workspace

    cd "$WORKSPACE_DIR" || return 1

    print_header "IGNITE workspaceクリア"
    echo ""
    echo -e "${BLUE}ワークスペース:${NC} $WORKSPACE_DIR"
    echo ""

    # セッションが実行中の場合は警告
    if session_exists; then
        print_warning "セッション '$SESSION_NAME' が実行中です"
        echo "先にシステムを停止することをお勧めします: ./scripts/ignite stop -s $SESSION_NAME"
        echo ""
    fi

    # 確認
    if [[ "$skip_confirm" == false ]]; then
        echo "以下のディレクトリがクリアされます:"
        echo "  - $WORKSPACE_DIR/queue/*"
        echo "  - $WORKSPACE_DIR/logs/*"
        echo "  - $WORKSPACE_DIR/context/*"
        echo "  - $WORKSPACE_DIR/state/*"
        echo "  - $WORKSPACE_DIR/archive/*"
        echo "  - $WORKSPACE_DIR/costs/sessions.yaml"
        echo "  - $WORKSPACE_DIR/dashboard.md"
        echo "  - $WORKSPACE_DIR/system_config.yaml"
        echo "  - $WORKSPACE_DIR/coordinator_state.yaml"
        echo ""
        echo -e "${YELLOW}注意: costs/history/ はクリアされません（履歴保持）${NC}"
        echo ""
        read -p "続行しますか? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_warning "キャンセルしました"
            exit 0
        fi
    fi

    # クリーンアップ実行
    print_info "workspaceをクリア中..."

    rm -rf "$WORKSPACE_DIR/queue"/*/
    mkdir -p "$WORKSPACE_DIR/queue"/{leader,strategist,architect,evaluator,coordinator,innovator}
    # IGNITIANキューディレクトリの動的作成
    local _worker_count
    _worker_count=$(get_worker_count)
    for i in $(seq 1 "$_worker_count"); do
        mkdir -p "$WORKSPACE_DIR/queue/ignitian_${i}"
    done

    rm -rf "$WORKSPACE_DIR/logs"/*
    rm -rf "$WORKSPACE_DIR/context"/*
    rm -f "$WORKSPACE_DIR/dashboard.md"
    rm -f "$WORKSPACE_DIR/system_config.yaml"
    rm -f "$WORKSPACE_DIR/coordinator_state.yaml"
    rm -rf "$WORKSPACE_DIR/state"/*
    rm -rf "$WORKSPACE_DIR/archive"/*
    mkdir -p "$WORKSPACE_DIR/archive"/{leader,strategist,coordinator}

    # コストのセッション情報をクリア（履歴は保持）
    rm -f "$WORKSPACE_DIR/costs/sessions.yaml"

    print_success "workspaceをクリアしました"
}

# =============================================================================
# list コマンド - セッション一覧表示
# =============================================================================

cmd_list() {
    print_header "IGNITEセッション一覧"
    echo ""

    local session_dir="$IGNITE_CONFIG_DIR/sessions"
    local found=0
    # 表示済みセッション名を記録（tmuxフォールバック時の重複防止）
    local shown_sessions=""

    # テーブルヘッダー
    printf "  %-16s %-10s %-8s %s\n" "SESSION" "STATUS" "AGENTS" "WORKSPACE"
    printf "  %-16s %-10s %-8s %s\n" "────────────────" "──────────" "────────" "─────────────────"

    # Step 2: sessions/*.yaml を走査
    if [[ -d "$session_dir" ]]; then
        for f in "$session_dir"/*.yaml; do
            [[ -f "$f" ]] || continue
            local s_name s_workspace s_mode s_total s_actual
            s_name=$(grep '^session_name:' "$f" | awk '{print $2}' | tr -d '"')
            s_workspace=$(grep '^workspace_dir:' "$f" | awk '{print $2}' | tr -d '"')
            s_mode=$(grep '^mode:' "$f" | awk '{print $2}' | tr -d '"')
            s_total=$(grep '^agents_total:' "$f" | awk '{print $2}')
            s_actual=$(grep '^agents_actual:' "$f" | awk '{print $2}')
            # 後方互換フォールバック
            s_mode=${s_mode:-unknown}
            s_total=${s_total:-"-"}
            s_actual=${s_actual:-"-"}
            # STATUS判定
            local s_status="stopped"
            if tmux has-session -t "$s_name" 2>/dev/null; then
                s_status="running"
            fi
            # AGENTS列
            local agents_display="${s_actual}/${s_total}"
            if [[ "$s_mode" == "leader" ]]; then
                agents_display="${agents_display} (solo)"
            fi
            printf "  %-16s %-10s %-8s %s\n" "$s_name" "$s_status" "$agents_display" "$s_workspace"
            shown_sessions="${shown_sessions}${s_name} "
            found=$((found + 1))
        done
    fi

    # Step 3: tmuxフォールバック（YAMLなしのセッションを補完）
    local tmux_sessions
    tmux_sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^ignite-" || true)
    if [[ -n "$tmux_sessions" ]]; then
        while IFS= read -r s_name; do
            # 既にYAMLで表示済みならスキップ
            if [[ "$shown_sessions" == *"$s_name "* ]]; then
                continue
            fi
            printf "  %-16s %-10s %-8s %s\n" "$s_name" "running" "-" "-"
            found=$((found + 1))
        done <<< "$tmux_sessions"
    fi

    # Step 4: 結果なし
    if [[ "$found" -eq 0 ]]; then
        echo ""
        print_warning "実行中のIGNITEセッションはありません"
        echo ""
        echo -e "新しいセッションを起動: ${YELLOW}./scripts/ignite start${NC}"
    else
        echo ""
        echo -e "セッションに接続: ${YELLOW}./scripts/ignite attach -s <session-id>${NC}"
        echo -e "セッションを停止: ${YELLOW}./scripts/ignite stop -s <session-id>${NC}"
    fi
}

# =============================================================================
# watcher コマンド - GitHub Watcher管理
# =============================================================================

cmd_watcher() {
    local action="${1:-}"
    shift 2>/dev/null || true

    case "$action" in
        start)
            print_info "GitHub Watcherを起動します..."
            "$IGNITE_SCRIPTS_DIR/utils/github_watcher.sh" &
            print_success "GitHub Watcherをバックグラウンドで起動しました"
            ;;
        stop)
            print_info "GitHub Watcherを停止します..."
            pkill -f "github_watcher.sh" 2>/dev/null || true
            print_success "GitHub Watcherを停止しました"
            ;;
        status)
            if pgrep -f "github_watcher.sh" > /dev/null; then
                print_success "GitHub Watcher: 実行中"
                pgrep -f "github_watcher.sh" | while read -r pid; do
                    echo "  PID: $pid"
                done
            else
                print_warning "GitHub Watcher: 停止中"
            fi
            ;;
        once)
            print_info "GitHub Watcherを単発実行します..."
            "$IGNITE_SCRIPTS_DIR/utils/github_watcher.sh" --once
            ;;
        comment)
            # Issueにコメント投稿
            "$IGNITE_SCRIPTS_DIR/utils/comment_on_issue.sh" "$@"
            ;;
        ack)
            # 受付応答を投稿
            local issue="${1:-}"
            local repo="${2:-}"
            if [[ -z "$issue" ]]; then
                print_error "Issue番号を指定してください"
                echo "使用方法: ./scripts/ignite watcher ack <issue_number> [repo]"
                exit 1
            fi
            if [[ -n "$repo" ]]; then
                "$IGNITE_SCRIPTS_DIR/utils/comment_on_issue.sh" "$issue" --repo "$repo" --bot --template acknowledge
            else
                "$IGNITE_SCRIPTS_DIR/utils/comment_on_issue.sh" "$issue" --bot --template acknowledge
            fi
            ;;
        *)
            echo "使用方法: ./scripts/ignite watcher <action>"
            echo ""
            echo "アクション:"
            echo "  start                       バックグラウンドで起動"
            echo "  stop                        停止"
            echo "  status                      状態確認"
            echo "  once                        単発実行"
            echo "  comment <issue> [options]   Issueにコメント投稿"
            echo "  ack <issue> [repo]          受付応答を投稿"
            echo ""
            echo "コメント例:"
            echo "  ./scripts/ignite watcher comment 123 --repo owner/repo --bot --body \"メッセージ\""
            echo "  ./scripts/ignite watcher ack 123 owner/repo"
            ;;
    esac
}

# =============================================================================
# validate コマンド - 設定ファイル検証
# =============================================================================

cmd_validate() {
    local target="all"

    # オプション解析
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--config) target="$2"; shift 2 ;;
            -h|--help)
                echo "使用方法: ./scripts/ignite validate [options]"
                echo ""
                echo "設定ファイルを検証し、エラーや警告を表示します。"
                echo ""
                echo "オプション:"
                echo "  -c, --config <name>   検証対象を指定"
                echo "                        system      - system.yaml"
                echo "                        watcher     - github-watcher.yaml"
                echo "                        github-app  - github-app.yaml"
                echo "                        all (default) - 全ファイル"
                echo "  -h, --help            この使い方を表示"
                echo ""
                echo "例:"
                echo "  ./scripts/ignite validate"
                echo "  ./scripts/ignite validate --config system"
                echo "  ./scripts/ignite validate --config watcher"
                exit 0
                ;;
            *) print_error "Unknown option: $1"; echo "使用方法: ./scripts/ignite validate -h"; exit 1 ;;
        esac
    done

    print_header "IGNITE 設定ファイル検証"
    echo ""

    # config_validator.sh の関数が利用可能か確認
    if ! declare -f validate_required &>/dev/null; then
        print_warning "config_validator が読み込まれていません"
        return 1
    fi

    # ディレクトリ解決
    local config_dir="$IGNITE_CONFIG_DIR"
    local xdg_dir="${XDG_CONFIG_HOME:-$HOME/.config}/ignite"

    # エラー蓄積リセット
    _VALIDATION_ERRORS=()
    _VALIDATION_WARNINGS=()

    case "$target" in
        system)
            local f="${config_dir}/system.yaml"
            if [[ ! -e "$f" ]]; then
                print_error "ファイルが見つかりません: $f"
                return 1
            fi
            validate_system_yaml "$f"
            ;;
        watcher)
            local f="${xdg_dir}/github-watcher.yaml"
            if [[ ! -e "$f" ]]; then
                f="${config_dir}/github-watcher.yaml"
            fi
            if [[ ! -e "$f" ]]; then
                print_warning "github-watcher.yaml が見つかりません（スキップ）"
                return 0
            fi
            validate_watcher_yaml "$f"
            ;;
        github-app)
            local f="${xdg_dir}/github-app.yaml"
            if [[ ! -e "$f" ]]; then
                f="${config_dir}/github-app.yaml"
            fi
            if [[ ! -e "$f" ]]; then
                print_warning "github-app.yaml が見つかりません（スキップ）"
                return 0
            fi
            validate_github_app_yaml "$f"
            ;;
        all)
            # config_dir の system.yaml
            if [[ -d "$config_dir" ]]; then
                validate_system_yaml "${config_dir}/system.yaml"
            else
                validation_error "$config_dir" "(dir)" "設定ディレクトリが見つかりません"
            fi
            # XDG 設定はオプショナル
            if [[ -d "$xdg_dir" ]]; then
                validate_watcher_yaml    "${xdg_dir}/github-watcher.yaml"
                validate_github_app_yaml "${xdg_dir}/github-app.yaml"
            fi
            ;;
        *)
            print_error "不明な検証対象: $target"
            echo "有効な値: system, watcher, github-app, all"
            return 1
            ;;
    esac

    # 個別検証時のレポート出力
    _colorize_and_report
}

# カラー付きレポート出力（内部関数）
_colorize_and_report() {
    local has_error=0

    if [[ ${#_VALIDATION_WARNINGS[@]} -gt 0 ]]; then
        for w in "${_VALIDATION_WARNINGS[@]}"; do
            echo -e "${YELLOW}${w}${NC}"
        done
    fi

    if [[ ${#_VALIDATION_ERRORS[@]} -gt 0 ]]; then
        for e in "${_VALIDATION_ERRORS[@]}"; do
            echo -e "${RED}${e}${NC}"
        done
        has_error=1
    fi

    local total=$(( ${#_VALIDATION_ERRORS[@]} + ${#_VALIDATION_WARNINGS[@]} ))
    echo ""
    if [[ $total -eq 0 ]]; then
        echo -e "${GREEN}✓ 検証に成功しました（エラー: 0, 警告: 0）${NC}"
    else
        echo -e "エラー: ${RED}${#_VALIDATION_ERRORS[@]}${NC} 件, 警告: ${YELLOW}${#_VALIDATION_WARNINGS[@]}${NC} 件"
    fi

    _VALIDATION_ERRORS=()
    _VALIDATION_WARNINGS=()

    return "$has_error"
}

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
            -w|--workspace)
                WORKSPACE_DIR="$2"
                if [[ ! "$WORKSPACE_DIR" = /* ]]; then
                    WORKSPACE_DIR="$(pwd)/$WORKSPACE_DIR"
                fi
                shift 2
                ;;
            -h|--help) cmd_help activate; exit 0 ;;
            *) print_error "Unknown option: $1"; cmd_help activate; exit 1 ;;
        esac
    done

    # ワークスペース解決 → 設定ロード → セッション名解決
    setup_workspace
    setup_workspace_config "$WORKSPACE_DIR"
    setup_session_name

    if ! session_exists; then
        print_error "セッション '$SESSION_NAME' が見つかりません"
        echo ""
        print_info "実行中のセッション一覧:"
        list_sessions 2>/dev/null || true
        exit 1
    fi

    # ヘッドレスモード: エージェントは HTTP API 経由で初期化済み
    print_info "エージェントは HTTP 経由で初期化済みです"
    echo ""
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

    # ワークスペース解決 → 設定ロード → セッション名解決
    setup_workspace
    setup_workspace_config "$WORKSPACE_DIR"
    setup_session_name

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

    # PID ファイルでエージェント存在確認
    local state_dir="$IGNITE_RUNTIME_DIR/state"
    if [[ ! -f "${state_dir}/.agent_pid_${pane_num}" ]]; then
        print_error "ターゲット '${target}' のエージェント (idx=${pane_num}) が存在しません"
        exit 1
    fi

    require_workspace
    cd "$WORKSPACE_DIR" || return 1

    # メッセージファイル作成（MIMEフォーマット）
    local IGNITE_MIME="${SCRIPT_DIR}/ignite_mime.py"
    local timestamp
    timestamp=$(date -Iseconds)
    local message_id
    message_id=$(date +%s%6N)
    mkdir -p "$IGNITE_RUNTIME_DIR/queue/${target}"
    local message_file="$IGNITE_RUNTIME_DIR/queue/${target}/notify_${message_id}.mime"

    local body_yaml
    body_yaml="message: |
$(printf '%s' "$message" | sed 's/^/  /')"
    python3 "$IGNITE_MIME" build \
        --from user --to "$target" --type notification \
        --priority "${DEFAULT_MESSAGE_PRIORITY}" \
        --body "$body_yaml" -o "$message_file"

    print_success "メッセージをキューに配置しました: $message_file"
}

# =============================================================================
# attach コマンド - エージェントに接続
# =============================================================================

cmd_attach() {
    local agent_name=""

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
            -h|--help) cmd_help attach; exit 0 ;;
            -*)
                print_error "Unknown option: $1"; cmd_help attach; exit 1
                ;;
            *)
                agent_name="$1"
                shift
                ;;
        esac
    done

    # ワークスペース解決 → 設定ロード → セッション名解決
    setup_workspace
    setup_workspace_config "$WORKSPACE_DIR"
    setup_session_name

    if ! session_exists; then
        print_error "セッション '$SESSION_NAME' が見つかりません"
        echo ""
        print_info "実行中のセッション一覧:"
        list_sessions 2>/dev/null || true
        echo -e "${YELLOW}先に起動してください: ./scripts/ignite start${NC}"
        exit 1
    fi

    local state_dir="$IGNITE_RUNTIME_DIR/state"

    if [[ -n "$agent_name" ]]; then
        # 指定エージェントに接続
        local found_idx=""
        for name_file in "$state_dir"/.agent_name_*; do
            [[ -f "$name_file" ]] || continue
            local stored_name
            stored_name=$(cat "$name_file")
            if [[ "$stored_name" == "$agent_name" ]]; then
                found_idx=$(basename "$name_file" | sed 's/^\.agent_name_//')
                break
            fi
        done

        if [[ -z "$found_idx" ]]; then
            print_error "エージェント '$agent_name' が見つかりません"
            return 1
        fi

        local port
        port=$(cat "${state_dir}/.agent_port_${found_idx}" 2>/dev/null || true)
        if [[ -z "$port" ]]; then
            print_error "エージェント '$agent_name' のポートが見つかりません"
            return 1
        fi

        exec opencode attach "http://localhost:${port}"
    else
        # エージェント一覧を表示して選択
        print_header "実行中のエージェント"
        echo ""
        local agents=()
        local idx=0
        for name_file in "$state_dir"/.agent_name_*; do
            [[ -f "$name_file" ]] || continue
            local _name _idx _port
            _idx=$(basename "$name_file" | sed 's/^\.agent_name_//')
            _name=$(cat "$name_file")
            _port=$(cat "${state_dir}/.agent_port_${_idx}" 2>/dev/null || echo "-")
            agents+=("${_name}")
            printf "  %d) %-20s (idx=%s, port=%s)\n" "$((idx + 1))" "$_name" "$_idx" "$_port"
            idx=$((idx + 1))
        done

        if [[ ${#agents[@]} -eq 0 ]]; then
            print_warning "実行中のエージェントはありません"
            return 1
        fi

        echo ""
        read -p "接続するエージェント番号を選択 (1-${#agents[@]}): " -r choice
        if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#agents[@]} ]]; then
            print_error "無効な選択: $choice"
            return 1
        fi

        local selected_name="${agents[$((choice - 1))]}"
        # 再帰的に呼び出し
        cmd_attach "$selected_name"
    fi
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
    setup_workspace_config "$WORKSPACE_DIR"
    require_workspace

    cd "$WORKSPACE_DIR" || return 1

    if [[ ! -d "$IGNITE_RUNTIME_DIR/logs" ]] || [[ -z "$(ls -A "$IGNITE_RUNTIME_DIR/logs" 2>/dev/null)" ]]; then
        print_warning "ログファイルが見つかりません"
        exit 0
    fi

    if [[ "$follow" == true ]]; then
        print_info "ログをリアルタイム監視中... (Ctrl+C で終了)"
        tail -f "$IGNITE_RUNTIME_DIR/logs"/*.log 2>/dev/null
    else
        print_header "ログ (直近${lines}行)"
        echo ""
        for log_file in "$IGNITE_RUNTIME_DIR/logs"/*.log; do
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

    # ワークスペース解決 → 設定ロード → セッション名解決
    setup_workspace
    setup_workspace_config "$WORKSPACE_DIR"
    setup_session_name
    require_workspace

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
        echo "  - $IGNITE_RUNTIME_DIR/queue/*"
        echo "  - $IGNITE_RUNTIME_DIR/logs/*"
        echo "  - $IGNITE_RUNTIME_DIR/context/*"
        echo "  - $IGNITE_RUNTIME_DIR/state/*"
        echo "  - $IGNITE_RUNTIME_DIR/archive/*"
        echo "  - $IGNITE_RUNTIME_DIR/dashboard.md"
        echo "  - $IGNITE_RUNTIME_DIR/runtime.yaml"
        echo "  - $IGNITE_RUNTIME_DIR/coordinator_state.yaml"
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

    rm -rf "$IGNITE_RUNTIME_DIR/queue"/*/
    mkdir -p "$IGNITE_RUNTIME_DIR/queue"/{leader,strategist,architect,evaluator,coordinator,innovator}
    # IGNITIANキューディレクトリの動的作成
    local _worker_count
    _worker_count=$(get_worker_count)
    for i in $(seq 1 "$_worker_count"); do
        mkdir -p "$IGNITE_RUNTIME_DIR/queue/ignitian_${i}"
    done

    rm -rf "$IGNITE_RUNTIME_DIR/logs"/*
    rm -rf "$IGNITE_RUNTIME_DIR/context"/*
    rm -f "$IGNITE_RUNTIME_DIR/dashboard.md"
    rm -f "$IGNITE_RUNTIME_DIR/runtime.yaml"
    rm -f "$IGNITE_RUNTIME_DIR/coordinator_state.yaml"
    rm -rf "$IGNITE_RUNTIME_DIR/state"/*
    rm -rf "$IGNITE_RUNTIME_DIR/archive"/*
    mkdir -p "$IGNITE_RUNTIME_DIR/archive"/{leader,strategist,coordinator}

    print_success "workspaceをクリアしました"
}

# =============================================================================
# list コマンド - セッション一覧表示
# =============================================================================

cmd_list() {
    # オプション解析
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -w|--workspace)
                WORKSPACE_DIR="$2"
                if [[ ! "$WORKSPACE_DIR" = /* ]]; then
                    WORKSPACE_DIR="$(pwd)/$WORKSPACE_DIR"
                fi
                shift 2
                ;;
            -h|--help) cmd_help list; exit 0 ;;
            *) print_error "Unknown option: $1"; cmd_help list; exit 1 ;;
        esac
    done

    # ワークスペース解決 → 設定ロード
    setup_workspace
    setup_workspace_config "$WORKSPACE_DIR"

    print_header "IGNITEセッション一覧"
    echo ""

    local session_dir="$IGNITE_CONFIG_DIR/sessions"
    local found=0
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
            # STATUS判定: Leader PID で判定
            local s_status="stopped"
            local _leader_pid
            if [[ -n "$s_workspace" ]] && [[ -f "$s_workspace/.ignite/state/.agent_pid_0" ]]; then
                _leader_pid=$(cat "$s_workspace/.ignite/state/.agent_pid_0" 2>/dev/null || true)
                if [[ -n "$_leader_pid" ]] && kill -0 "$_leader_pid" 2>/dev/null; then
                    s_status="running"
                fi
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

    # Step 3: フォールバック（YAMLなしのセッションを補完）
    # runtime.yaml ベースで補完
    local _ws="${WORKSPACE_DIR:-}"
    if [[ -n "$_ws" ]] && [[ -f "$_ws/.ignite/runtime.yaml" ]]; then
        local _rt_name
        _rt_name=$(yaml_get "$_ws/.ignite/runtime.yaml" "session_name" 2>/dev/null || true)
        if [[ -n "$_rt_name" ]] && [[ "$shown_sessions" != *"$_rt_name "* ]]; then
            local _leader_pid
            _leader_pid=$(cat "$_ws/.ignite/state/.agent_pid_0" 2>/dev/null || true)
            if [[ -n "$_leader_pid" ]] && kill -0 "$_leader_pid" 2>/dev/null; then
                printf "  %-16s %-10s %-8s %s\n" "$_rt_name" "running" "-" "$_ws"
                found=$((found + 1))
            fi
        fi
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

    # ワークスペース解決 → 設定ロード → セッション名解決
    setup_workspace
    setup_workspace_config "$WORKSPACE_DIR"
    setup_session_name

    case "$action" in
        start)
            print_info "GitHub Watcherを起動します..."
            # 既存プロセスの停止（PIDベース）
            if [[ -f "$IGNITE_RUNTIME_DIR/github_watcher.pid" ]]; then
                local old_pid
                old_pid=$(cat "$IGNITE_RUNTIME_DIR/github_watcher.pid")
                if kill -0 "$old_pid" 2>/dev/null; then
                    kill "$old_pid" 2>/dev/null || true
                    sleep 1
                fi
                rm -f "$IGNITE_RUNTIME_DIR/github_watcher.pid"
            fi
            local watcher_log="$IGNITE_RUNTIME_DIR/logs/github_watcher.log"
            mkdir -p "$IGNITE_RUNTIME_DIR/logs"
            export IGNITE_WATCHER_CONFIG="$IGNITE_CONFIG_DIR/github-watcher.yaml"
            export IGNITE_WORKSPACE_DIR="$WORKSPACE_DIR"
            export WORKSPACE_DIR="$WORKSPACE_DIR"
            export IGNITE_CONFIG_DIR="$IGNITE_CONFIG_DIR"
            export IGNITE_RUNTIME_DIR="$IGNITE_RUNTIME_DIR"
            export IGNITE_SESSION="${SESSION_NAME:-}"
            "$IGNITE_SCRIPTS_DIR/utils/github_watcher.sh" >> "$watcher_log" 2>&1 &
            local watcher_pid=$!
            echo "$watcher_pid" > "$IGNITE_RUNTIME_DIR/github_watcher.pid"
            print_success "GitHub Watcherをバックグラウンドで起動しました (PID: $watcher_pid)"
            ;;
        stop)
            print_info "GitHub Watcherを停止します..."
            if [[ -f "$IGNITE_RUNTIME_DIR/github_watcher.pid" ]]; then
                local watcher_pid
                watcher_pid=$(cat "$IGNITE_RUNTIME_DIR/github_watcher.pid")
                if kill -0 "$watcher_pid" 2>/dev/null; then
                    kill "$watcher_pid" 2>/dev/null || true
                    local wait_count=0
                    while kill -0 "$watcher_pid" 2>/dev/null && [[ $wait_count -lt 6 ]]; do
                        sleep 0.5
                        wait_count=$((wait_count + 1))
                    done
                    if kill -0 "$watcher_pid" 2>/dev/null; then
                        kill -9 "$watcher_pid" 2>/dev/null || true
                    fi
                    print_success "GitHub Watcherを停止しました"
                else
                    print_warning "GitHub Watcher (PID: $watcher_pid) は既に停止しています"
                fi
                rm -f "$IGNITE_RUNTIME_DIR/github_watcher.pid"
            else
                print_warning "PIDファイルが見つかりません"
            fi
            ;;
        status)
            if [[ -f "$IGNITE_RUNTIME_DIR/github_watcher.pid" ]]; then
                local watcher_pid
                watcher_pid=$(cat "$IGNITE_RUNTIME_DIR/github_watcher.pid")
                if kill -0 "$watcher_pid" 2>/dev/null; then
                    print_success "GitHub Watcher: 実行中 (PID: $watcher_pid)"
                else
                    print_warning "GitHub Watcher: 停止中 (stale PID: $watcher_pid)"
                    rm -f "$IGNITE_RUNTIME_DIR/github_watcher.pid"
                fi
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

    # ワークスペース設定を解決
    setup_workspace_config ""

    # config_validator.sh の関数が利用可能か確認
    if ! declare -f validate_required &>/dev/null; then
        print_warning "config_validator が読み込まれていません"
        return 1
    fi

    # ディレクトリ解決（IGNITE_CONFIG_DIRベースに統一）
    local config_dir="$IGNITE_CONFIG_DIR"

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
            local f="${config_dir}/github-watcher.yaml"
            if [[ ! -e "$f" ]]; then
                print_warning "github-watcher.yaml が見つかりません（スキップ）"
                return 0
            fi
            validate_watcher_yaml "$f"
            ;;
        github-app)
            local f="${config_dir}/github-app.yaml"
            if [[ ! -e "$f" ]]; then
                print_warning "github-app.yaml が見つかりません（スキップ）"
                return 0
            fi
            validate_github_app_yaml "$f"
            ;;
        all)
            # config_dir 内の全設定ファイルを検証
            if [[ -d "$config_dir" ]]; then
                validate_system_yaml "${config_dir}/system.yaml"
                [[ -f "${config_dir}/github-watcher.yaml" ]] && validate_watcher_yaml "${config_dir}/github-watcher.yaml"
                [[ -f "${config_dir}/github-app.yaml" ]] && validate_github_app_yaml "${config_dir}/github-app.yaml"
            else
                validation_error "$config_dir" "(dir)" "設定ディレクトリが見つかりません"
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

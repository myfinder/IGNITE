# shellcheck shell=bash
# lib/cmd_plan.sh - planコマンド
[[ -n "${__LIB_CMD_PLAN_LOADED:-}" ]] && return; __LIB_CMD_PLAN_LOADED=1

cmd_plan() {
    local goal=""
    local context=""

    # オプション解析
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--context) context="$2"; shift 2 ;;
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
            -h|--help) cmd_help plan; exit 0 ;;
            -*) print_error "Unknown option: $1"; cmd_help plan; exit 1 ;;
            *)
                if [[ -z "$goal" ]]; then
                    goal="$1"
                    shift
                else
                    print_error "引数が多すぎます"
                    cmd_help plan
                    exit 1
                fi
                ;;
        esac
    done

    # セッション名とワークスペースを設定
    setup_session_name
    setup_workspace
    setup_workspace_config "$WORKSPACE_DIR"

    # 引数チェック
    if [[ -z "$goal" ]]; then
        print_error "目標を指定してください"
        echo ""
        echo "使用方法:"
        echo "  ./scripts/ignite plan \"目標の内容\""
        echo "  ./scripts/ignite plan \"目標\" -c \"コンテキスト\""
        echo ""
        echo "例:"
        echo "  ./scripts/ignite plan \"READMEファイルを作成する\""
        echo "  ./scripts/ignite plan \"認証機能を実装\" -c \"JWT認証、セッション管理\""
        exit 1
    fi

    require_workspace
    cd "$WORKSPACE_DIR" || return 1

    # セッションの存在確認
    if ! session_exists; then
        print_error "セッション '$SESSION_NAME' が見つかりません"
        echo ""
        print_info "実行中のセッション一覧:"
        list_sessions 2>/dev/null || true
        echo -e "${YELLOW}先に起動してください: ./scripts/ignite start${NC}"
        exit 1
    fi

    print_header "IGNITE タスク投入"
    echo ""
    echo -e "${BLUE}目標:${NC} $goal"
    if [[ -n "$context" ]]; then
        echo -e "${BLUE}コンテキスト:${NC} $context"
    fi
    echo ""

    # タイムスタンプとメッセージID生成
    local timestamp
    timestamp=$(date -Iseconds)
    local message_id
    message_id=$(date +%s%6N)
    local escaped_goal="${goal//\"/\\\"}"

    # Leaderへメッセージ送信（MIMEフォーマット）
    # キューディレクトリ直下に配置 → queue_monitor が検知して Leader に配信
    local IGNITE_MIME="${SCRIPT_DIR}/ignite_mime.py"
    mkdir -p "$IGNITE_RUNTIME_DIR/queue/leader"
    local message_file="$IGNITE_RUNTIME_DIR/queue/leader/user_goal_${message_id}.mime"

    local body_yaml="goal: \"${escaped_goal}\""
    if [[ -n "$context" ]]; then
        local escaped_context="${context//\"/\\\"}"
        body_yaml="${body_yaml}
context: \"${escaped_context}\""
    fi
    python3 "$IGNITE_MIME" build \
        --from user --to leader --type user_goal \
        --priority high --body "$body_yaml" -o "$message_file"

    print_success "メッセージをキューに配置しました: $message_file"

    echo ""
    print_success "タスク '${goal}' を投入しました"
    echo ""
    echo "次のステップ:"
    echo -e "  1. ダッシュボード確認: ${YELLOW}./scripts/ignite status${NC}"
    echo -e "  2. ログ確認: ${YELLOW}./scripts/ignite logs${NC}"
    echo -e "  3. tmuxセッション表示: ${YELLOW}./scripts/ignite attach${NC}"
}

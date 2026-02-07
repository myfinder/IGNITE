# shellcheck shell=bash
# lib/cmd_work_on.sh - work-onコマンド
[[ -n "${__LIB_CMD_WORK_ON_LOADED:-}" ]] && return; __LIB_CMD_WORK_ON_LOADED=1

# =============================================================================
# work-on コマンド - Issue番号を指定して実装開始
# =============================================================================

cmd_work_on() {
    local issue_input=""
    local repo=""

    # オプション解析
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -r|--repo)
                repo="$2"
                shift 2
                ;;
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
            -h|--help) cmd_help work-on; exit 0 ;;
            -*)
                print_error "Unknown option: $1"
                cmd_help work-on
                exit 1
                ;;
            *)
                if [[ -z "$issue_input" ]]; then
                    issue_input="$1"
                fi
                shift
                ;;
        esac
    done

    # セッション名とワークスペースを設定
    setup_session_name
    setup_workspace

    # Issue入力チェック
    if [[ -z "$issue_input" ]]; then
        print_error "Issue番号またはURLを指定してください"
        echo ""
        echo "使用方法:"
        echo "  ./scripts/ignite work-on 123 --repo owner/repo"
        echo "  ./scripts/ignite work-on https://github.com/owner/repo/issues/123"
        exit 1
    fi

    # URLかどうかチェック
    local issue_number=""
    if [[ "$issue_input" =~ ^https?://.*github\.com/([^/]+)/([^/]+)/issues/([0-9]+) ]]; then
        repo="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        issue_number="${BASH_REMATCH[3]}"
    else
        issue_number="$issue_input"
        if [[ -z "$repo" ]]; then
            # リポジトリを推測
            repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
            if [[ -z "$repo" ]]; then
                print_error "リポジトリを指定してください: --repo owner/repo"
                exit 1
            fi
        fi
    fi

    # セッションの存在確認
    if ! session_exists; then
        print_error "セッション '$SESSION_NAME' が見つかりません"
        echo ""
        print_info "実行中のセッション一覧:"
        list_sessions 2>/dev/null || true
        echo -e "${YELLOW}先に起動してください: ./scripts/ignite start${NC}"
        exit 1
    fi

    print_header "IGNITE Work-on Issue"
    echo ""
    echo -e "${BLUE}Issue:${NC} #$issue_number"
    echo -e "${BLUE}リポジトリ:${NC} $repo"
    echo ""

    # Issue情報を取得
    print_info "Issue情報を取得中..."
    local issue_info
    issue_info=$(gh api "/repos/${repo}/issues/${issue_number}" 2>/dev/null || echo "")

    if [[ -z "$issue_info" ]] || [[ "$issue_info" == "null" ]]; then
        print_error "Issue #${issue_number} が見つかりません"
        exit 1
    fi

    local issue_title
    issue_title=$(echo "$issue_info" | jq -r '.title')
    local issue_body
    issue_body=$(echo "$issue_info" | jq -r '.body // ""' | head -c 2000)
    local issue_url
    issue_url=$(echo "$issue_info" | jq -r '.html_url')

    print_success "Issue: $issue_title"
    echo ""

    # タイムスタンプとメッセージID生成
    local timestamp
    timestamp=$(date -Iseconds)
    local message_id
    message_id=$(date +%s%6N)

    # github_taskメッセージを作成
    mkdir -p "$WORKSPACE_DIR/queue/leader/processed"
    local message_file="$WORKSPACE_DIR/queue/leader/processed/github_task_${message_id}.yaml"

    cat > "$message_file" <<EOF
type: github_task
from: user
to: leader
timestamp: "${timestamp}"
priority: high
payload:
  trigger: "implement"
  repository: ${repo}
  issue_number: ${issue_number}
  issue_title: "${issue_title//\"/\\\"}"
  issue_body: |
$(echo "$issue_body" | sed 's/^/    /')
  requested_by: user
  trigger_comment: "work-onコマンドによる手動トリガー"
  branch_prefix: "ignite/"
  url: "${issue_url}"
EOF

    print_success "タスクメッセージを作成しました: $message_file"

    # Leaderに通知
    sleep 0.5
    tmux send-keys -t "$SESSION_NAME:$TMUX_WINDOW_NAME.0" \
        "$WORKSPACE_DIR/queue/leader/processed/ に新しいタスクがあります。${message_file} を確認してください。Issue #${issue_number}「${issue_title}」の実装を開始してください。"
    sleep 0.3
    tmux send-keys -t "$SESSION_NAME:$TMUX_WINDOW_NAME.0" C-m

    echo ""
    print_success "Issue #${issue_number} の実装タスクを投入しました"
    echo ""
    echo "次のステップ:"
    echo -e "  1. 進捗確認: ${YELLOW}./scripts/ignite status${NC}"
    echo -e "  2. ログ確認: ${YELLOW}./scripts/ignite logs -f${NC}"
    echo -e "  3. tmux確認: ${YELLOW}./scripts/ignite attach${NC}"
}

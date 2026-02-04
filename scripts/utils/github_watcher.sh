#!/bin/bash
# GitHub イベント監視デーモン
# 定期的にGitHub APIをポーリングしてイベントを検知し、
# 新規イベントを workspace/queue/ に投入します

set -e
set -u

# スクリプトのディレクトリを取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# デフォルト設定
DEFAULT_INTERVAL=60
DEFAULT_STATE_FILE="workspace/state/github_watcher_state.json"
DEFAULT_CONFIG_FILE="config/github-watcher.yaml"

# カラー定義
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# ログ出力
log_info() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${RED}[ERROR]${NC} $1"; }
log_event() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${CYAN}[EVENT]${NC} $1"; }

# =============================================================================
# 設定読み込み
# =============================================================================

load_config() {
    local config_file="${IGNITE_WATCHER_CONFIG:-${PROJECT_ROOT}/${DEFAULT_CONFIG_FILE}}"

    if [[ ! -f "$config_file" ]]; then
        log_error "設定ファイルが見つかりません: $config_file"
        echo ""
        echo "設定ファイルを作成してください:"
        echo "  cp config/github-watcher.yaml.example config/github-watcher.yaml"
        exit 1
    fi

    # YAMLから設定を読み込み
    POLL_INTERVAL=$(grep -E '^\s*interval:' "$config_file" | head -1 | awk '{print $2}' | tr -d '"')
    POLL_INTERVAL=${POLL_INTERVAL:-$DEFAULT_INTERVAL}

    STATE_FILE=$(grep -E '^\s*state_file:' "$config_file" | head -1 | awk '{print $2}' | tr -d '"')
    STATE_FILE=${STATE_FILE:-$DEFAULT_STATE_FILE}
    STATE_FILE="${PROJECT_ROOT}/${STATE_FILE}"

    IGNORE_BOT=$(grep -E '^\s*ignore_bot:' "$config_file" | head -1 | awk '{print $2}' | tr -d '"')
    IGNORE_BOT=${IGNORE_BOT:-true}

    # 監視対象リポジトリを取得
    REPOSITORIES=()
    local in_repos=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*repositories: ]]; then
            in_repos=true
            continue
        fi
        if [[ "$in_repos" == true ]]; then
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*repo:[[:space:]]*(.+) ]]; then
                # - repo: owner/repo 形式
                local repo="${BASH_REMATCH[1]}"
                repo=$(echo "$repo" | tr -d '"' | tr -d "'" | xargs)
                REPOSITORIES+=("$repo")
            elif [[ "$line" =~ ^[[:space:]]*-[[:space:]]*([^:]+)$ ]]; then
                # - owner/repo 形式（シンプル形式）
                local repo="${BASH_REMATCH[1]}"
                repo=$(echo "$repo" | tr -d '"' | tr -d "'" | xargs)
                REPOSITORIES+=("$repo")
            elif [[ "$line" =~ ^[[:space:]]*[a-z_]+:[[:space:]] ]] && [[ ! "$line" =~ ^[[:space:]]*base_branch: ]]; then
                # 新しいセクションが始まったら終了（base_branchは除く）
                in_repos=false
            fi
        fi
    done < "$config_file"

    # イベントタイプ設定
    WATCH_ISSUES=$(grep -E '^\s*issues:' "$config_file" | head -1 | awk '{print $2}' | tr -d '"')
    WATCH_ISSUES=${WATCH_ISSUES:-true}

    WATCH_ISSUE_COMMENTS=$(grep -E '^\s*issue_comments:' "$config_file" | head -1 | awk '{print $2}' | tr -d '"')
    WATCH_ISSUE_COMMENTS=${WATCH_ISSUE_COMMENTS:-true}

    WATCH_PRS=$(grep -E '^\s*pull_requests:' "$config_file" | head -1 | awk '{print $2}' | tr -d '"')
    WATCH_PRS=${WATCH_PRS:-true}

    WATCH_PR_COMMENTS=$(grep -E '^\s*pr_comments:' "$config_file" | head -1 | awk '{print $2}' | tr -d '"')
    WATCH_PR_COMMENTS=${WATCH_PR_COMMENTS:-true}

    # トリガー設定
    MENTION_PATTERN=$(grep -E '^\s*mention_pattern:' "$config_file" | head -1 | awk '{print $2}' | tr -d '"')
    MENTION_PATTERN=${MENTION_PATTERN:-"@ignite-gh-app"}

    # ワークスペース設定
    WORKSPACE_DIR=$(grep -E '^\s*workspace:' "$config_file" | head -1 | awk '{print $2}' | tr -d '"')
    WORKSPACE_DIR=${WORKSPACE_DIR:-"workspace"}
    WORKSPACE_DIR="${PROJECT_ROOT}/${WORKSPACE_DIR}"
}

# =============================================================================
# ステート管理
# =============================================================================

init_state() {
    mkdir -p "$(dirname "$STATE_FILE")"
    if [[ ! -f "$STATE_FILE" ]]; then
        # 新規作成時は現在時刻を記録
        # これ以降のイベントのみ処理対象とする（過去イベントの再処理防止）
        local now=$(date -Iseconds)
        echo "{\"processed_events\":{},\"last_check\":{},\"initialized_at\":\"$now\"}" > "$STATE_FILE"
        log_info "新規ステートファイル作成: $now 以降のイベントを監視"
    fi
}

# 初期化時刻を取得（sinceパラメータのフォールバック用）
get_initialized_at() {
    jq -r '.initialized_at // empty' "$STATE_FILE" 2>/dev/null
}

# イベントIDが処理済みかチェック
is_event_processed() {
    local event_type="$1"
    local event_id="$2"
    local key="${event_type}_${event_id}"

    jq -e ".processed_events[\"$key\"]" "$STATE_FILE" > /dev/null 2>&1
}

# イベントIDを処理済みとして記録
mark_event_processed() {
    local event_type="$1"
    local event_id="$2"
    local key="${event_type}_${event_id}"
    local timestamp=$(date -Iseconds)

    local tmp_file=$(mktemp)
    jq ".processed_events[\"$key\"] = \"$timestamp\"" "$STATE_FILE" > "$tmp_file"
    mv "$tmp_file" "$STATE_FILE"
}

# 最終チェック時刻を更新
update_last_check() {
    local repo="$1"
    local event_type="$2"
    local timestamp=$(date -Iseconds)

    local tmp_file=$(mktemp)
    jq ".last_check[\"${repo}_${event_type}\"] = \"$timestamp\"" "$STATE_FILE" > "$tmp_file"
    mv "$tmp_file" "$STATE_FILE"
}

# 古い処理済みイベントをクリーンアップ（24時間以上前）
cleanup_old_events() {
    local cutoff=$(date -d "24 hours ago" -Iseconds 2>/dev/null || date -v-24H -Iseconds 2>/dev/null || echo "")
    if [[ -z "$cutoff" ]]; then
        return
    fi

    local tmp_file=$(mktemp)
    jq --arg cutoff "$cutoff" '
        .processed_events |= with_entries(select(.value >= $cutoff))
    ' "$STATE_FILE" > "$tmp_file" 2>/dev/null && mv "$tmp_file" "$STATE_FILE"
}

# =============================================================================
# Bot判別
# =============================================================================

is_human_event() {
    local author_type="$1"
    local author_login="$2"

    # User タイプで、かつ [bot] サフィックスがない場合のみtrue
    [[ "$author_type" == "User" ]] && [[ ! "$author_login" =~ \[bot\]$ ]]
}

# =============================================================================
# イベント取得
# =============================================================================

# GitHub Appトークンを取得
get_bot_token() {
    if [[ -f "${PROJECT_ROOT}/scripts/utils/get_github_app_token.sh" ]]; then
        "${PROJECT_ROOT}/scripts/utils/get_github_app_token.sh" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# Issueイベントを取得
fetch_issues() {
    local repo="$1"
    local since=""

    # 最終チェック時刻があれば使用、なければ初期化時刻を使用
    since=$(jq -r ".last_check[\"${repo}_issues\"] // .initialized_at // empty" "$STATE_FILE")

    local api_url="/repos/${repo}/issues?state=all&sort=created&direction=desc&per_page=30"
    if [[ -n "$since" ]]; then
        api_url="${api_url}&since=${since}"
    fi

    gh api "$api_url" \
        --jq '.[] | select(.pull_request == null) | {
            id: .id,
            number: .number,
            title: .title,
            body: .body,
            author: .user.login,
            author_type: .user.type,
            state: .state,
            created_at: .created_at,
            updated_at: .updated_at,
            url: .html_url
        }' 2>/dev/null || echo ""
}

# Issueコメントを取得
fetch_issue_comments() {
    local repo="$1"
    local since=""

    # 最終チェック時刻があれば使用、なければ初期化時刻を使用
    since=$(jq -r ".last_check[\"${repo}_issue_comments\"] // .initialized_at // empty" "$STATE_FILE")

    local api_url="/repos/${repo}/issues/comments?sort=created&direction=desc&per_page=30"
    if [[ -n "$since" ]]; then
        api_url="${api_url}&since=${since}"
    fi

    gh api "$api_url" \
        --jq '.[] | {
            id: .id,
            issue_number: (.issue_url | split("/") | last | tonumber),
            body: .body,
            author: .user.login,
            author_type: .user.type,
            created_at: .created_at,
            url: .html_url
        }' 2>/dev/null || echo ""
}

# PRイベントを取得
fetch_prs() {
    local repo="$1"
    local since=""

    # 最終チェック時刻があれば使用、なければ初期化時刻を使用
    since=$(jq -r ".last_check[\"${repo}_prs\"] // .initialized_at // empty" "$STATE_FILE")

    # PRs API は since パラメータをサポートしていないので、
    # 取得後に created_at でフィルタリングする
    gh api "/repos/${repo}/pulls?state=open&sort=created&direction=desc&per_page=30" \
        --jq --arg since "${since:-1970-01-01T00:00:00Z}" '.[] | select(.created_at >= $since) | {
            id: .id,
            number: .number,
            title: .title,
            body: .body,
            author: .user.login,
            author_type: .user.type,
            state: .state,
            created_at: .created_at,
            updated_at: .updated_at,
            url: .html_url,
            head_ref: .head.ref,
            base_ref: .base.ref
        }' 2>/dev/null || echo ""
}

# PRコメントを取得（レビューコメントも含む）
fetch_pr_comments() {
    local repo="$1"
    local since=""

    # 最終チェック時刻があれば使用、なければ初期化時刻を使用
    since=$(jq -r ".last_check[\"${repo}_pr_comments\"] // .initialized_at // empty" "$STATE_FILE")

    local api_url="/repos/${repo}/pulls/comments?sort=created&direction=desc&per_page=30"
    if [[ -n "$since" ]]; then
        api_url="${api_url}&since=${since}"
    fi

    gh api "$api_url" \
        --jq '.[] | {
            id: .id,
            pr_number: (.pull_request_url | split("/") | last | tonumber),
            body: .body,
            author: .user.login,
            author_type: .user.type,
            created_at: .created_at,
            url: .html_url,
            path: .path,
            line: .line
        }' 2>/dev/null || echo ""
}

# =============================================================================
# メッセージ生成
# =============================================================================

create_event_message() {
    local event_type="$1"
    local repo="$2"
    local event_data="$3"

    local timestamp=$(date -Iseconds)
    local message_id=$(date +%s%N)
    local queue_dir="${WORKSPACE_DIR}/queue/leader"

    mkdir -p "$queue_dir"

    local message_file="${queue_dir}/github_event_${message_id}.yaml"

    # イベントタイプに応じてメッセージを構築
    case "$event_type" in
        issue_created|issue_updated)
            local issue_number=$(echo "$event_data" | jq -r '.number')
            local issue_title=$(echo "$event_data" | jq -r '.title')
            local issue_body=$(echo "$event_data" | jq -r '.body // ""' | head -c 1000)
            local author=$(echo "$event_data" | jq -r '.author')
            local author_type=$(echo "$event_data" | jq -r '.author_type')
            local url=$(echo "$event_data" | jq -r '.url')

            cat > "$message_file" <<EOF
type: github_event
from: github_watcher
to: leader
timestamp: "${timestamp}"
priority: normal
payload:
  event_type: ${event_type}
  repository: ${repo}
  issue_number: ${issue_number}
  issue_title: "${issue_title}"
  author: ${author}
  author_type: ${author_type}
  body: |
$(echo "$issue_body" | sed 's/^/    /')
  url: "${url}"
status: pending
EOF
            ;;

        issue_comment)
            local issue_number=$(echo "$event_data" | jq -r '.issue_number')
            local comment_id=$(echo "$event_data" | jq -r '.id')
            local body=$(echo "$event_data" | jq -r '.body // ""' | head -c 1000)
            local author=$(echo "$event_data" | jq -r '.author')
            local author_type=$(echo "$event_data" | jq -r '.author_type')
            local url=$(echo "$event_data" | jq -r '.url')

            cat > "$message_file" <<EOF
type: github_event
from: github_watcher
to: leader
timestamp: "${timestamp}"
priority: normal
payload:
  event_type: ${event_type}
  repository: ${repo}
  issue_number: ${issue_number}
  comment_id: ${comment_id}
  author: ${author}
  author_type: ${author_type}
  body: |
$(echo "$body" | sed 's/^/    /')
  url: "${url}"
status: pending
EOF
            ;;

        pr_created|pr_updated)
            local pr_number=$(echo "$event_data" | jq -r '.number')
            local pr_title=$(echo "$event_data" | jq -r '.title')
            local pr_body=$(echo "$event_data" | jq -r '.body // ""' | head -c 1000)
            local author=$(echo "$event_data" | jq -r '.author')
            local author_type=$(echo "$event_data" | jq -r '.author_type')
            local url=$(echo "$event_data" | jq -r '.url')
            local head_ref=$(echo "$event_data" | jq -r '.head_ref')
            local base_ref=$(echo "$event_data" | jq -r '.base_ref')

            cat > "$message_file" <<EOF
type: github_event
from: github_watcher
to: leader
timestamp: "${timestamp}"
priority: normal
payload:
  event_type: ${event_type}
  repository: ${repo}
  pr_number: ${pr_number}
  pr_title: "${pr_title}"
  author: ${author}
  author_type: ${author_type}
  head_ref: ${head_ref}
  base_ref: ${base_ref}
  body: |
$(echo "$pr_body" | sed 's/^/    /')
  url: "${url}"
status: pending
EOF
            ;;

        pr_comment)
            local pr_number=$(echo "$event_data" | jq -r '.pr_number')
            local comment_id=$(echo "$event_data" | jq -r '.id')
            local body=$(echo "$event_data" | jq -r '.body // ""' | head -c 1000)
            local author=$(echo "$event_data" | jq -r '.author')
            local author_type=$(echo "$event_data" | jq -r '.author_type')
            local url=$(echo "$event_data" | jq -r '.url')

            cat > "$message_file" <<EOF
type: github_event
from: github_watcher
to: leader
timestamp: "${timestamp}"
priority: normal
payload:
  event_type: ${event_type}
  repository: ${repo}
  pr_number: ${pr_number}
  comment_id: ${comment_id}
  author: ${author}
  author_type: ${author_type}
  body: |
$(echo "$body" | sed 's/^/    /')
  url: "${url}"
status: pending
EOF
            ;;
    esac

    echo "$message_file"
}

# トリガーメッセージを検出（@ignite-gh-app など）
create_task_message() {
    local event_type="$1"
    local repo="$2"
    local event_data="$3"
    local trigger_type="$4"

    local timestamp=$(date -Iseconds)
    local message_id=$(date +%s%N)
    local queue_dir="${WORKSPACE_DIR}/queue/leader"

    mkdir -p "$queue_dir"

    local message_file="${queue_dir}/github_task_${message_id}.yaml"

    local issue_number=$(echo "$event_data" | jq -r '.issue_number // .number // 0')
    local author=$(echo "$event_data" | jq -r '.author')
    local body=$(echo "$event_data" | jq -r '.body // ""' | head -c 2000)
    local url=$(echo "$event_data" | jq -r '.url')

    # Issue情報を取得（コメントからの場合）
    local issue_title=""
    local issue_body=""
    if [[ "$event_type" == "issue_comment" ]] && [[ "$issue_number" != "0" ]]; then
        local issue_info=$(gh api "/repos/${repo}/issues/${issue_number}" 2>/dev/null || echo "{}")
        issue_title=$(echo "$issue_info" | jq -r '.title // ""')
        issue_body=$(echo "$issue_info" | jq -r '.body // ""' | head -c 1000)
    else
        issue_title=$(echo "$event_data" | jq -r '.title // ""')
        issue_body=$(echo "$event_data" | jq -r '.body // ""' | head -c 1000)
    fi

    cat > "$message_file" <<EOF
type: github_task
from: github_watcher
to: leader
timestamp: "${timestamp}"
priority: high
payload:
  trigger: "${trigger_type}"
  repository: ${repo}
  issue_number: ${issue_number}
  issue_title: "${issue_title}"
  issue_body: |
$(echo "$issue_body" | sed 's/^/    /')
  requested_by: ${author}
  trigger_comment: |
$(echo "$body" | sed 's/^/    /')
  branch_prefix: "ignite/"
  url: "${url}"
status: pending
EOF

    echo "$message_file"
}

# =============================================================================
# イベント処理
# =============================================================================

process_events() {
    for repo in "${REPOSITORIES[@]}"; do
        log_info "リポジトリ監視: $repo"

        # Issues
        if [[ "$WATCH_ISSUES" == "true" ]]; then
            process_issues "$repo"
        fi

        # Issue Comments
        if [[ "$WATCH_ISSUE_COMMENTS" == "true" ]]; then
            process_issue_comments "$repo"
        fi

        # PRs
        if [[ "$WATCH_PRS" == "true" ]]; then
            process_prs "$repo"
        fi

        # PR Comments
        if [[ "$WATCH_PR_COMMENTS" == "true" ]]; then
            process_pr_comments "$repo"
        fi
    done
}

process_issues() {
    local repo="$1"
    local issues=$(fetch_issues "$repo")

    if [[ -z "$issues" ]]; then
        return
    fi

    echo "$issues" | while IFS= read -r issue; do
        [[ -z "$issue" ]] && continue

        local id=$(echo "$issue" | jq -r '.id')
        local author_type=$(echo "$issue" | jq -r '.author_type')
        local author=$(echo "$issue" | jq -r '.author')

        # 処理済みチェック
        if is_event_processed "issue" "$id"; then
            continue
        fi

        # Bot判別
        if [[ "$IGNORE_BOT" == "true" ]] && ! is_human_event "$author_type" "$author"; then
            mark_event_processed "issue" "$id"
            continue
        fi

        log_event "新規Issue検知: #$(echo "$issue" | jq -r '.number') by $author"

        local message_file=$(create_event_message "issue_created" "$repo" "$issue")
        log_success "メッセージ作成: $message_file"

        mark_event_processed "issue" "$id"
    done

    update_last_check "$repo" "issues"
}

process_issue_comments() {
    local repo="$1"
    local comments=$(fetch_issue_comments "$repo")

    if [[ -z "$comments" ]]; then
        return
    fi

    echo "$comments" | while IFS= read -r comment; do
        [[ -z "$comment" ]] && continue

        local id=$(echo "$comment" | jq -r '.id')
        local author_type=$(echo "$comment" | jq -r '.author_type')
        local author=$(echo "$comment" | jq -r '.author')
        local body=$(echo "$comment" | jq -r '.body // ""')

        # 処理済みチェック
        if is_event_processed "issue_comment" "$id"; then
            continue
        fi

        # Bot判別
        if [[ "$IGNORE_BOT" == "true" ]] && ! is_human_event "$author_type" "$author"; then
            mark_event_processed "issue_comment" "$id"
            continue
        fi

        log_event "新規Issueコメント検知: #$(echo "$comment" | jq -r '.issue_number') by $author"

        # トリガーパターンをチェック
        if [[ "$body" =~ $MENTION_PATTERN ]]; then
            log_event "トリガー検知: $MENTION_PATTERN"

            # トリガータイプを判別
            local trigger_type="implement"
            if [[ "$body" =~ (レビュー|review) ]]; then
                trigger_type="review"
            elif [[ "$body" =~ (説明|explain) ]]; then
                trigger_type="explain"
            fi

            local message_file=$(create_task_message "issue_comment" "$repo" "$comment" "$trigger_type")
            log_success "タスクメッセージ作成: $message_file"
        else
            local message_file=$(create_event_message "issue_comment" "$repo" "$comment")
            log_success "メッセージ作成: $message_file"
        fi

        mark_event_processed "issue_comment" "$id"
    done

    update_last_check "$repo" "issue_comments"
}

process_prs() {
    local repo="$1"
    local prs=$(fetch_prs "$repo")

    if [[ -z "$prs" ]]; then
        return
    fi

    echo "$prs" | while IFS= read -r pr; do
        [[ -z "$pr" ]] && continue

        local id=$(echo "$pr" | jq -r '.id')
        local author_type=$(echo "$pr" | jq -r '.author_type')
        local author=$(echo "$pr" | jq -r '.author')

        # 処理済みチェック
        if is_event_processed "pr" "$id"; then
            continue
        fi

        # Bot判別
        if [[ "$IGNORE_BOT" == "true" ]] && ! is_human_event "$author_type" "$author"; then
            mark_event_processed "pr" "$id"
            continue
        fi

        log_event "新規PR検知: #$(echo "$pr" | jq -r '.number') by $author"

        local message_file=$(create_event_message "pr_created" "$repo" "$pr")
        log_success "メッセージ作成: $message_file"

        mark_event_processed "pr" "$id"
    done

    update_last_check "$repo" "prs"
}

process_pr_comments() {
    local repo="$1"
    local comments=$(fetch_pr_comments "$repo")

    if [[ -z "$comments" ]]; then
        return
    fi

    echo "$comments" | while IFS= read -r comment; do
        [[ -z "$comment" ]] && continue

        local id=$(echo "$comment" | jq -r '.id')
        local author_type=$(echo "$comment" | jq -r '.author_type')
        local author=$(echo "$comment" | jq -r '.author')

        # 処理済みチェック
        if is_event_processed "pr_comment" "$id"; then
            continue
        fi

        # Bot判別
        if [[ "$IGNORE_BOT" == "true" ]] && ! is_human_event "$author_type" "$author"; then
            mark_event_processed "pr_comment" "$id"
            continue
        fi

        log_event "新規PRコメント検知: #$(echo "$comment" | jq -r '.pr_number') by $author"

        local message_file=$(create_event_message "pr_comment" "$repo" "$comment")
        log_success "メッセージ作成: $message_file"

        mark_event_processed "pr_comment" "$id"
    done

    update_last_check "$repo" "pr_comments"
}

# =============================================================================
# メインループ
# =============================================================================

run_daemon() {
    log_info "GitHub Watcher を起動します"
    log_info "監視間隔: ${POLL_INTERVAL}秒"
    log_info "監視対象リポジトリ: ${REPOSITORIES[*]}"
    log_info "ステートファイル: $STATE_FILE"

    while true; do
        process_events

        # 定期的に古いイベントをクリーンアップ
        cleanup_old_events

        sleep "$POLL_INTERVAL"
    done
}

run_once() {
    log_info "GitHub Watcher を単発実行します"
    log_info "監視対象リポジトリ: ${REPOSITORIES[*]}"

    process_events

    log_success "処理完了"
}

# =============================================================================
# ヘルプ
# =============================================================================

show_help() {
    cat << 'EOF'
GitHub イベント監視デーモン

使用方法:
  ./scripts/utils/github_watcher.sh [オプション]

オプション:
  -d, --daemon    デーモンモードで起動（デフォルト）
  -o, --once      単発実行
  -c, --config    設定ファイルを指定
  -h, --help      このヘルプを表示

環境変数:
  IGNITE_WATCHER_CONFIG    設定ファイルのパス

使用例:
  # デーモンモードで起動
  ./scripts/utils/github_watcher.sh

  # 単発実行
  ./scripts/utils/github_watcher.sh --once

  # バックグラウンドで起動
  ./scripts/utils/github_watcher.sh &

  # 設定ファイルを指定
  ./scripts/utils/github_watcher.sh -c /path/to/config.yaml

設定ファイル:
  config/github-watcher.yaml を編集して監視対象リポジトリを設定してください。
  詳細は docs/github-watcher.md を参照してください。
EOF
}

# =============================================================================
# メイン
# =============================================================================

main() {
    local mode="daemon"
    local config_file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--daemon)
                mode="daemon"
                shift
                ;;
            -o|--once)
                mode="once"
                shift
                ;;
            -c|--config)
                config_file="$2"
                export IGNITE_WATCHER_CONFIG="$config_file"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    # 設定読み込み
    load_config

    # ステート初期化
    init_state

    # 実行モード
    case "$mode" in
        daemon)
            run_daemon
            ;;
        once)
            run_once
            ;;
    esac
}

main "$@"

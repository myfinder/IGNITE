#!/bin/bash
# PR作成ヘルパースクリプト
# Issue番号からPRを作成します
#
# 使用方法:
#   ./scripts/utils/create_pr.sh <issue_number> [options]

set -e
set -u

# スクリプトのディレクトリを取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/core.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${WORKSPACE_DIR:-}" ]] && setup_workspace_config "$WORKSPACE_DIR"

# Bot Token / GitHub API 共通関数の読み込み
source "${SCRIPT_DIR}/github_helpers.sh"

# =============================================================================
# ヘルプ
# =============================================================================

show_help() {
    cat << 'EOF'
PR作成ヘルパースクリプト

使用方法:
  ./scripts/utils/create_pr.sh <issue_number> [オプション]
  ./scripts/utils/create_pr.sh <issue_url> [オプション]

引数:
  <issue_number>    Issue番号（例: 123）
  <issue_url>       IssueのURL（例: https://github.com/owner/repo/issues/123）

オプション:
  -r, --repo <repo>       リポジトリ（owner/repo形式）
  -b, --base <branch>     ベースブランチ（デフォルト: main）
  -p, --prefix <prefix>   ブランチ名プレフィックス（デフォルト: ignite/）
  -t, --title <title>     PRタイトル（デフォルト: Issue番号から生成）
  -m, --message <msg>     コミットメッセージ（デフォルト: 自動生成）
  --draft                 ドラフトPRとして作成
  --bot                   Bot名義で作成（GitHub App Token使用）
  --no-push               プッシュせずにブランチ作成のみ
  -h, --help              このヘルプを表示

使用例:
  # Issue #123 に対するPRを作成
  ./scripts/utils/create_pr.sh 123 --repo owner/repo

  # Issue URLから作成
  ./scripts/utils/create_pr.sh https://github.com/owner/repo/issues/123

  # Bot名義で作成
  ./scripts/utils/create_pr.sh 123 --repo owner/repo --bot

  # ドラフトPRとして作成
  ./scripts/utils/create_pr.sh 123 --repo owner/repo --draft

注意:
  - 現在のディレクトリがgitリポジトリである必要があります
  - ステージングされた変更がある場合、それらがコミットされます
  - 変更がない場合はPR作成に失敗します
EOF
}

# =============================================================================
# URL パース
# =============================================================================

parse_issue_url() {
    local url="$1"

    # https://github.com/owner/repo/issues/123 形式をパース
    if [[ "$url" =~ github\.com/([^/]+)/([^/]+)/issues/([0-9]+) ]]; then
        REPO="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        ISSUE_NUMBER="${BASH_REMATCH[3]}"
        return 0
    fi

    return 1
}

# =============================================================================
# Issue 情報取得
# =============================================================================

get_issue_info() {
    local repo="$1"
    local issue_number="$2"

    github_api_get "$repo" "/repos/${repo}/issues/${issue_number}" 2>/dev/null
}

# =============================================================================
# ブランチ作成
# =============================================================================

create_branch() {
    local branch_name="$1"
    local base_branch="$2"
    local non_interactive="${3:-false}"

    # ベースブランチを更新
    log_info "ベースブランチを更新中: $base_branch"
    safe_git_fetch origin "$base_branch" 2>/dev/null || true

    # 既存のブランチがあるか確認
    if git show-ref --verify --quiet "refs/heads/${branch_name}"; then
        log_warn "ブランチが既に存在します: $branch_name"
        if [[ "$non_interactive" == "true" ]] || [[ ! -t 0 ]]; then
            # 非対話環境: 既存ブランチに自動切り替え
            log_info "非対話環境のため、既存ブランチに自動切り替えします"
            git checkout "$branch_name"
            return 0
        fi
        read -p "既存のブランチに切り替えますか? (Y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            git checkout "$branch_name"
            return 0
        else
            log_error "ブランチ作成をキャンセルしました"
            exit 1
        fi
    fi

    # 新しいブランチを作成
    log_info "ブランチを作成中: $branch_name"
    git checkout -b "$branch_name" "origin/${base_branch}"
}

# =============================================================================
# コミット
# =============================================================================

create_commit() {
    local message="$1"
    local co_author="${2:-}"

    # ステージされた変更があるか確認
    if git diff --cached --quiet; then
        # ステージされていない変更があるか確認
        if git diff --quiet; then
            log_error "コミットする変更がありません"
            return 1
        fi

        log_info "変更をステージング中..."
        git add -A
    fi

    # コミットメッセージを作成
    local full_message="$message"
    if [[ -n "$co_author" ]]; then
        full_message="${message}

Co-Authored-By: ${co_author}"
    fi

    log_info "コミットを作成中..."
    git commit -m "$full_message"
}

# =============================================================================
# プッシュ
# =============================================================================

push_branch() {
    local branch_name="$1"

    log_info "ブランチをプッシュ中: $branch_name"
    safe_git_push -u origin "$branch_name"
}

# =============================================================================
# PR 作成
# =============================================================================

create_pull_request() {
    local repo="$1"
    local title="$2"
    local body="$3"
    local base_branch="$4"
    local head_branch="$5"
    local is_draft="$6"
    local use_bot="$7"

    log_info "PRを作成中..."

    local draft_flag=""
    if [[ "$is_draft" == "true" ]]; then
        draft_flag="--draft"
    fi

    # 認証トークン設定（GitHub App > PAT）
    local auth_token=""
    auth_token=$(get_auth_token "$repo") || true
    if [[ -z "$auth_token" ]]; then
        _print_auth_error "$repo"
        return 1
    fi
    if [[ "$use_bot" == "true" ]] && [[ "$AUTH_TOKEN_SOURCE" == "pat" ]]; then
        log_warn "GitHub App Token取得失敗のため、PATでPRを作成します。"
    fi

    # PR作成（curl + GitHub API）
    local json_data
    json_data=$(jq -n \
        --arg title "$title" \
        --arg body "$body" \
        --arg head "$head_branch" \
        --arg base "$base_branch" \
        --argjson draft "$( [[ "$is_draft" == "true" ]] && echo true || echo false )" \
        '{"title": $title, "body": $body, "head": $head, "base": $base, "draft": $draft}')

    local pr_response
    pr_response=$(github_api_post "$repo" "/repos/${repo}/pulls" "$json_data")

    local pr_url
    pr_url=$(printf '%s' "$pr_response" | _json_get '.html_url')
    echo "$pr_url"
}

# =============================================================================
# メイン
# =============================================================================

main() {
    local issue_input=""
    local repo=""
    local base_branch="main"
    local branch_prefix="ignite/"
    local pr_title=""
    local commit_message=""
    local is_draft=false
    local use_bot=false
    local no_push=false

    # 引数解析
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -r|--repo)
                repo="$2"
                shift 2
                ;;
            -b|--base)
                base_branch="$2"
                shift 2
                ;;
            -p|--prefix)
                branch_prefix="$2"
                shift 2
                ;;
            -t|--title)
                pr_title="$2"
                shift 2
                ;;
            -m|--message)
                commit_message="$2"
                shift 2
                ;;
            --draft)
                is_draft=true
                shift
                ;;
            --bot)
                use_bot=true
                shift
                ;;
            --no-push)
                no_push=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_help
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

    # Issue入力チェック
    if [[ -z "$issue_input" ]]; then
        log_error "Issue番号またはURLを指定してください"
        show_help
        exit 1
    fi

    # URLかどうかチェック
    if [[ "$issue_input" =~ ^https?:// ]]; then
        if ! parse_issue_url "$issue_input"; then
            log_error "無効なIssue URL: $issue_input"
            exit 1
        fi
    else
        ISSUE_NUMBER="$issue_input"
        if [[ -z "$repo" ]]; then
            # リポジトリを推測（git remote から検出）
            repo=$(_get_repo_from_remote 2>/dev/null || echo "")
            if [[ -z "$repo" ]]; then
                log_error "リポジトリを指定してください: --repo owner/repo"
                exit 1
            fi
        fi
        REPO="$repo"
    fi

    log_info "Issue #${ISSUE_NUMBER} に対するPRを作成します"
    log_info "リポジトリ: $REPO"

    # Issue情報を取得
    log_info "Issue情報を取得中..."
    local issue_info
    issue_info=$(get_issue_info "$REPO" "$ISSUE_NUMBER")

    if [[ -z "$issue_info" ]] || [[ "$issue_info" == "null" ]]; then
        log_error "Issue #${ISSUE_NUMBER} が見つかりません"
        exit 1
    fi

    local issue_title
    issue_title=$(echo "$issue_info" | jq -r '.title')
    local issue_body
    issue_body=$(echo "$issue_info" | jq -r '.body // ""')

    log_info "Issue: $issue_title"

    # ブランチ名を生成
    local branch_name="${branch_prefix}issue-${ISSUE_NUMBER}"

    # PRタイトルを生成
    if [[ -z "$pr_title" ]]; then
        pr_title="fix: resolve issue #${ISSUE_NUMBER}"
    fi

    # コミットメッセージを生成
    if [[ -z "$commit_message" ]]; then
        commit_message="fix: resolve issue #${ISSUE_NUMBER} - ${issue_title}"
    fi

    # Co-Author（Bot使用時）
    local co_author=""
    if [[ "$use_bot" == "true" ]]; then
        co_author="IGNITE AI Team <noreply@ignite.local>"
    fi

    # ブランチ作成
    create_branch "$branch_name" "$base_branch" "$use_bot"

    # 変更がある場合のみコミット
    if ! git diff --cached --quiet || ! git diff --quiet; then
        if ! create_commit "$commit_message" "$co_author"; then
            log_warn "コミットをスキップ（変更なし）"
        fi
    else
        log_warn "変更がありません。既存のコミットでPRを作成します。"
    fi

    # プッシュ
    if [[ "$no_push" == "false" ]]; then
        push_branch "$branch_name"

        # PR本文を生成
        local issue_body_truncated
        issue_body_truncated=$(echo "$issue_body" | head -c 500)
        local pr_body="Closes #${ISSUE_NUMBER}

## Summary
This PR was automatically generated by IGNITE.

## Original Issue
**${issue_title}**

${issue_body_truncated}

## Changes
- (変更内容を記述してください)

---
*Generated by IGNITE AI Team*"

        # PR作成
        local pr_url
        pr_url=$(create_pull_request "$REPO" "$pr_title" "$pr_body" "$base_branch" "$branch_name" "$is_draft" "$use_bot")

        echo ""
        log_success "PRを作成しました!"
        echo ""
        echo -e "  ${BLUE}PR URL:${NC} $pr_url"
        echo ""
    else
        echo ""
        log_success "ブランチを作成しました: $branch_name"
        echo ""
        echo "プッシュとPR作成は手動で行ってください:"
        echo "  git push -u origin $branch_name"
        echo "  ./scripts/utils/create_pr.sh $ISSUE_NUMBER --repo $REPO --base $base_branch"
        echo ""
    fi
}

main "$@"

#!/bin/bash
# PRの修正スクリプト
# リベース、追加コミット、force push対応
#
# 使用方法:
#   ./scripts/utils/update_pr.sh rebase <repo_path> [base_branch]
#   ./scripts/utils/update_pr.sh continue <repo_path>
#   ./scripts/utils/update_pr.sh abort <repo_path>
#   ./scripts/utils/update_pr.sh commit <repo_path> "message"
#   ./scripts/utils/update_pr.sh amend <repo_path> ["new message"]
#   ./scripts/utils/update_pr.sh push <repo_path>
#   ./scripts/utils/update_pr.sh force-push <repo_path>

set -e
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# カラー定義
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# ログ出力（すべて標準エラー出力に出力して、コマンド置換で混入しないようにする）
log_info() { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
log_success() { echo -e "${GREEN}[OK]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# =============================================================================
# ヘルプ
# =============================================================================

show_help() {
    cat << 'EOF'
PR修正スクリプト

使用方法:
  ./scripts/utils/update_pr.sh <action> <repo_path> [options]

コマンド:
  rebase <repo_path> [base_branch]
      リベースを実行します。
      コンフリクトが発生した場合は終了コード1を返し、
      コンフリクトファイルの一覧を出力します。

  continue <repo_path>
      コンフリクト解決後、リベースを継続します。

  abort <repo_path>
      リベースを中止し、元の状態に戻します。

  commit <repo_path> "message"
      変更を追加コミットします。

  amend <repo_path> ["new message"]
      直前のコミットを修正します。
      メッセージを省略した場合はコミットメッセージは変更しません。

  push <repo_path>
      通常のpushを実行します。

  force-push <repo_path>
      --force-with-lease を使用したforce pushを実行します。

  status <repo_path>
      リベース中かどうかを確認します。

例:
  # リベース
  ./scripts/utils/update_pr.sh rebase workspace/repos/owner_repo main

  # コンフリクト解決後
  ./scripts/utils/update_pr.sh continue workspace/repos/owner_repo

  # リベース中止
  ./scripts/utils/update_pr.sh abort workspace/repos/owner_repo

  # 追加コミット
  ./scripts/utils/update_pr.sh commit workspace/repos/owner_repo "fix: address review comments"

  # Force push（リベース後）
  ./scripts/utils/update_pr.sh force-push workspace/repos/owner_repo
EOF
}

# =============================================================================
# リベース操作
# =============================================================================

# リベース実行
rebase_pr() {
    local repo_path="$1"
    local base_branch="${2:-main}"

    cd "$repo_path"

    # 現在のブランチを保存
    local current_branch
    current_branch=$(git branch --show-current)
    log_info "現在のブランチ: $current_branch"
    log_info "ベースブランチ: $base_branch"

    # ベースブランチを更新
    log_info "ベースブランチを更新中..."
    git fetch origin "$base_branch"

    # リベース実行
    log_info "リベースを実行中..."
    if git rebase "origin/$base_branch"; then
        log_success "リベース成功"
        return 0
    else
        log_error "コンフリクトが発生しました"
        echo ""
        echo "コンフリクトファイル:"
        git diff --name-only --diff-filter=U
        echo ""
        echo "解決後、以下を実行してください:"
        echo "  ./scripts/utils/update_pr.sh continue $repo_path"
        echo ""
        echo "中止する場合:"
        echo "  ./scripts/utils/update_pr.sh abort $repo_path"
        return 1
    fi
}

# コンフリクト解決後の継続
continue_rebase() {
    local repo_path="$1"
    cd "$repo_path"

    log_info "コンフリクト解決済みファイルをステージング..."
    git add -A

    log_info "リベースを継続中..."
    if git rebase --continue; then
        log_success "リベース継続成功"
        return 0
    else
        log_error "まだコンフリクトがあります"
        echo ""
        echo "コンフリクトファイル:"
        git diff --name-only --diff-filter=U
        return 1
    fi
}

# リベース中止
abort_rebase() {
    local repo_path="$1"
    cd "$repo_path"

    log_info "リベースを中止中..."
    git rebase --abort
    log_success "リベースを中止しました"
}

# リベース中かどうか確認
check_rebase_status() {
    local repo_path="$1"
    cd "$repo_path"

    if [[ -d ".git/rebase-merge" ]] || [[ -d ".git/rebase-apply" ]]; then
        log_info "リベース中です"
        echo ""
        echo "コンフリクトファイル:"
        git diff --name-only --diff-filter=U 2>/dev/null || echo "なし"
        return 0
    else
        log_info "リベース中ではありません"
        return 1
    fi
}

# =============================================================================
# コミット操作
# =============================================================================

# 追加コミット
add_commit() {
    local repo_path="$1"
    local message="$2"

    cd "$repo_path"

    # 変更があるか確認
    if git diff --cached --quiet && git diff --quiet; then
        log_warn "コミットする変更がありません"
        return 1
    fi

    log_info "変更をステージング中..."
    git add -A

    log_info "コミットを作成中..."
    git commit -m "$message"

    log_success "コミット作成完了"
}

# Amendコミット
amend_commit() {
    local repo_path="$1"
    local message="${2:-}"

    cd "$repo_path"

    log_info "変更をステージング中..."
    git add -A

    log_info "コミットを修正中..."
    if [[ -n "$message" ]]; then
        git commit --amend -m "$message"
    else
        git commit --amend --no-edit
    fi

    log_success "コミット修正完了"
}

# =============================================================================
# プッシュ操作
# =============================================================================

# 通常push
push() {
    local repo_path="$1"

    cd "$repo_path"

    local current_branch
    current_branch=$(git branch --show-current)
    log_info "ブランチ $current_branch をプッシュ中..."

    git push

    log_success "プッシュ完了"
}

# Force push（with lease）
force_push() {
    local repo_path="$1"

    cd "$repo_path"

    local current_branch
    current_branch=$(git branch --show-current)
    log_info "ブランチ $current_branch を force push 中..."

    git push --force-with-lease

    log_success "Force push 完了"
}

# =============================================================================
# メイン
# =============================================================================

main() {
    local action="${1:-}"
    shift || true

    case "$action" in
        rebase)
            rebase_pr "$@"
            ;;
        continue)
            continue_rebase "$@"
            ;;
        abort)
            abort_rebase "$@"
            ;;
        commit)
            add_commit "$@"
            ;;
        amend)
            amend_commit "$@"
            ;;
        push)
            push "$@"
            ;;
        force-push)
            force_push "$@"
            ;;
        status)
            check_rebase_status "$@"
            ;;
        -h|--help|help)
            show_help
            ;;
        "")
            log_error "アクションを指定してください"
            echo ""
            show_help
            exit 1
            ;;
        *)
            log_error "Unknown action: $action"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

main "$@"

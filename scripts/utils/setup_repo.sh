#!/bin/bash
# 外部リポジトリのセットアップスクリプト
# clone, ブランチ作成, 作業ディレクトリ管理
#
# 使用方法:
#   ./scripts/utils/setup_repo.sh clone <owner/repo> [base_branch]
#   ./scripts/utils/setup_repo.sh branch <repo_path> <issue_number> [base_branch]
#   ./scripts/utils/setup_repo.sh path <owner/repo>
#   ./scripts/utils/setup_repo.sh default-branch <owner/repo>

set -e
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPOS_DIR="${WORKSPACE_DIR:-$PROJECT_ROOT/workspace}/repos"

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
リポジトリ管理スクリプト

使用方法:
  ./scripts/utils/setup_repo.sh clone <owner/repo> [base_branch]
  ./scripts/utils/setup_repo.sh branch <repo_path> <issue_number> [base_branch]
  ./scripts/utils/setup_repo.sh path <owner/repo>
  ./scripts/utils/setup_repo.sh default-branch <owner/repo>
  ./scripts/utils/setup_repo.sh base-branch <owner/repo>

コマンド:
  clone <owner/repo> [base_branch]
      リポジトリをclone（または更新）します。
      base_branch を省略した場合はリポジトリのデフォルトブランチを使用。

  branch <repo_path> <issue_number> [base_branch]
      Issue用のブランチを作成します。
      ブランチ名は ignite/issue-{issue_number} になります。

  path <owner/repo>
      リポジトリのローカルパスを取得します。

  default-branch <owner/repo>
      リポジトリのデフォルトブランチを取得します（GitHub API使用）。

  base-branch <owner/repo>
      設定ファイルからベースブランチを取得します。
      設定がない場合はリポジトリのデフォルトブランチを使用。

環境変数:
  WORKSPACE_DIR    ワークスペースディレクトリ（デフォルト: workspace）

例:
  # リポジトリをclone
  ./scripts/utils/setup_repo.sh clone owner/repo

  # 特定のブランチを指定してclone
  ./scripts/utils/setup_repo.sh clone owner/repo develop

  # パス取得
  REPO_PATH=$(./scripts/utils/setup_repo.sh path owner/repo)
  echo $REPO_PATH  # workspace/repos/owner_repo

  # Issue用ブランチ作成
  ./scripts/utils/setup_repo.sh branch "$REPO_PATH" 123

  # 作業
  cd "$REPO_PATH"
  # ... 編集 ...

  # PR作成
  ./scripts/utils/create_pr.sh 123 --repo owner/repo
EOF
}

# =============================================================================
# ユーティリティ関数
# =============================================================================

# リポジトリのデフォルトブランチを取得
get_default_branch() {
    local repo="$1"
    gh api "/repos/${repo}" --jq '.default_branch' 2>/dev/null || echo "main"
}

# 設定ファイルからベースブランチを取得（なければデフォルトブランチ）
get_base_branch() {
    local repo="$1"
    local config_file="$PROJECT_ROOT/config/github-watcher.yaml"

    if [[ -f "$config_file" ]]; then
        # リポジトリ別の設定を取得
        # repositories セクションから repo に対応する base_branch を探す
        local configured_branch=""

        # YAMLのパース（簡易版）
        local in_repo_section=false
        local found_repo=false
        while IFS= read -r line; do
            # repositories: セクションに入ったか確認
            if [[ "$line" =~ ^[[:space:]]*repositories: ]]; then
                in_repo_section=true
                continue
            fi

            if [[ "$in_repo_section" == true ]]; then
                # 新しいリポジトリエントリ
                if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*repo:[[:space:]]*\"?([^\"]+)\"? ]]; then
                    local current_repo="${BASH_REMATCH[1]}"
                    current_repo=$(echo "$current_repo" | tr -d '"' | tr -d "'" | xargs)
                    if [[ "$current_repo" == "$repo" ]]; then
                        found_repo=true
                    else
                        found_repo=false
                    fi
                    continue
                fi

                # base_branch 設定
                if [[ "$found_repo" == true ]] && [[ "$line" =~ ^[[:space:]]*base_branch:[[:space:]]*\"?([^\"]+)\"? ]]; then
                    configured_branch="${BASH_REMATCH[1]}"
                    configured_branch=$(echo "$configured_branch" | tr -d '"' | tr -d "'" | xargs)
                    break
                fi

                # 別のトップレベルセクションに移動したら終了
                if [[ "$line" =~ ^[a-z]+: ]]; then
                    in_repo_section=false
                fi
            fi
        done < "$config_file"

        if [[ -n "$configured_branch" ]]; then
            echo "$configured_branch"
            return
        fi
    fi

    # デフォルトブランチを取得
    get_default_branch "$repo"
}

# リポジトリ名からローカルパスを生成
# IGNITE_WORKER_ID が設定されている場合は per-IGNITIAN パスを返す
repo_to_path() {
    local repo="$1"
    # owner/repo → owner_repo
    local repo_name=$(echo "$repo" | tr '/' '_')
    if [[ -n "${IGNITE_WORKER_ID:-}" ]]; then
        echo "$REPOS_DIR/${repo_name}_ignitian_${IGNITE_WORKER_ID}"
    else
        echo "$REPOS_DIR/$repo_name"
    fi
}

# =============================================================================
# リポジトリ操作
# =============================================================================

# リポジトリをclone（または更新）
setup_repo() {
    local repo="$1"
    local branch="${2:-}"

    # ベースブランチを決定
    if [[ -z "$branch" ]]; then
        branch=$(get_base_branch "$repo")
    fi

    local repo_path=$(repo_to_path "$repo")

    mkdir -p "$REPOS_DIR"

    if [[ -d "$repo_path/.git" ]]; then
        log_info "リポジトリが既に存在します。更新中..."
        cd "$repo_path"
        git fetch origin
        git checkout "$branch" 2>/dev/null || git checkout -b "$branch" "origin/$branch"
        git pull origin "$branch" || log_warn "pull に失敗しました（ローカル変更がある可能性）"
    else
        # per-IGNITIAN clone: primary clone が存在すればローカルから高速clone
        local repo_name=$(echo "$repo" | tr '/' '_')
        local primary_path="$REPOS_DIR/$repo_name"
        if [[ -n "${IGNITE_WORKER_ID:-}" ]] && [[ -d "$primary_path/.git" ]]; then
            log_info "primary clone からローカルclone: $repo (worker ${IGNITE_WORKER_ID})"
            git clone --no-hardlinks --branch "$branch" "$primary_path" "$repo_path"
            # origin URL をGitHubに再設定（ローカルcloneだとoriginがローカルパスになるため）
            git -C "$repo_path" remote set-url origin "https://github.com/${repo}.git"
        else
            log_info "リポジトリをclone中: $repo"
            # privateリポジトリ対応：GitHub App Tokenを使用
            local bot_token
            # IGNITE_CONFIG_DIR が設定されていれば、github-app.yaml のパスを渡す
            # --repo オプションでリポジトリを指定（Organization対応）
            if [[ -n "${IGNITE_CONFIG_DIR:-}" ]]; then
                bot_token=$(IGNITE_GITHUB_CONFIG="${IGNITE_CONFIG_DIR}/github-app.yaml" "${SCRIPT_DIR}/get_github_app_token.sh" --repo "$repo" 2>/dev/null || echo "")
            else
                bot_token=$("${SCRIPT_DIR}/get_github_app_token.sh" --repo "$repo" 2>/dev/null || echo "")
            fi
            if [[ -n "$bot_token" ]]; then
                log_info "GitHub App Token を使用してclone"
                GH_TOKEN="$bot_token" gh repo clone "$repo" "$repo_path" -- --branch "$branch"
            else
                gh repo clone "$repo" "$repo_path" -- --branch "$branch" || git clone "https://github.com/${repo}.git" "$repo_path" --branch "$branch"
            fi
        fi
        cd "$repo_path"
    fi

    log_success "リポジトリのセットアップ完了: $repo_path"
    echo "$repo_path"
}

# Issue用のブランチを作成
create_issue_branch() {
    local repo_path="$1"
    local issue_number="$2"
    local base_branch="${3:-}"

    # ベースブランチが未指定の場合はリポジトリのデフォルトを取得
    if [[ -z "$base_branch" ]]; then
        cd "$repo_path"
        # リモートからデフォルトブランチを取得
        base_branch=$(git remote show origin | grep 'HEAD branch' | awk '{print $NF}')
        if [[ -z "$base_branch" ]]; then
            base_branch="main"
        fi
    fi

    local branch_name="ignite/issue-${issue_number}"

    cd "$repo_path"
    git fetch origin

    # ベースブランチを更新
    git checkout "$base_branch" 2>/dev/null || git checkout -b "$base_branch" "origin/$base_branch"
    git pull origin "$base_branch" || log_warn "pull に失敗しました"

    # ブランチが既に存在するか確認
    if git show-ref --verify --quiet "refs/heads/${branch_name}"; then
        log_warn "ブランチが既に存在します: $branch_name"
        git checkout "$branch_name"
        # リモートの変更を取り込む
        git pull origin "$branch_name" 2>/dev/null || true
    else
        log_info "ブランチを作成中: $branch_name"
        git checkout -b "$branch_name"
    fi

    log_success "ブランチ作成完了: $branch_name"
    echo "$branch_name"
}

# リポジトリのパスを取得
get_repo_path() {
    local repo="$1"
    repo_to_path "$repo"
}

# =============================================================================
# メイン
# =============================================================================

main() {
    local action="${1:-}"
    shift || true

    case "$action" in
        clone|setup)
            setup_repo "$@"
            ;;
        branch)
            create_issue_branch "$@"
            ;;
        path)
            get_repo_path "$@"
            ;;
        default-branch)
            get_default_branch "$@"
            ;;
        base-branch)
            get_base_branch "$@"
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

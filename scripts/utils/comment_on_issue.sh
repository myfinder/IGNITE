#!/bin/bash
# Issue/PR へのコメント投稿スクリプト
# Bot名義またはユーザー名義でコメントを投稿
#
# 使用方法:
#   ./scripts/utils/comment_on_issue.sh <issue_number> [options]

set -e
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# =============================================================================
# XDG パス解決（インストールモード vs 開発モード）
# =============================================================================

XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"

# インストールモード判定: ~/.config/ignite/.install_paths が存在するか
if [[ -z "${IGNITE_CONFIG_DIR:-}" ]]; then
    if [[ -f "$XDG_CONFIG_HOME/ignite/.install_paths" ]]; then
        # インストールモード: XDGパスを使用
        IGNITE_CONFIG_DIR="$XDG_CONFIG_HOME/ignite"
    else
        # 開発モード: PROJECT_ROOTを使用
        IGNITE_CONFIG_DIR="$PROJECT_ROOT/config"
    fi
fi

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
Issue/PR へのコメント投稿スクリプト

使用方法:
  ./scripts/utils/comment_on_issue.sh <issue_number> [オプション]

オプション:
  -r, --repo <repo>       リポジトリ（owner/repo形式）
  -b, --body <body>       コメント本文
  -t, --template <type>   テンプレートを使用
                          (acknowledge, success, error, progress)
  -c, --context <text>    テンプレート内で使用するコンテキスト
  --bot                   Bot名義で投稿（GitHub App Token使用）
  -h, --help              このヘルプを表示

テンプレートタイプ:
  acknowledge   タスク受付時の応答
  success       処理完了時の応答
  error         エラー発生時の応答
  progress      進捗報告

使用例:
  # 直接メッセージ投稿
  ./scripts/utils/comment_on_issue.sh 123 --repo owner/repo --body "コメント内容"

  # Bot名義で投稿
  ./scripts/utils/comment_on_issue.sh 123 --repo owner/repo --bot --body "Bot応答"

  # テンプレート使用（受付応答）
  ./scripts/utils/comment_on_issue.sh 123 --repo owner/repo --bot --template acknowledge

  # テンプレート使用（成功報告）
  ./scripts/utils/comment_on_issue.sh 123 --repo owner/repo --bot \
    --template success --context "PR #456 を作成しました"

  # テンプレート使用（エラー報告）
  ./scripts/utils/comment_on_issue.sh 123 --repo owner/repo --bot \
    --template error --context "ビルドが失敗しました: npm test でエラー"

  # 現在のディレクトリからリポジトリを推測
  cd /path/to/repo
  ./scripts/utils/comment_on_issue.sh 123 --body "コメント"
EOF
}

# =============================================================================
# Bot Token 取得（キャッシュ + リトライ機構付き）
# =============================================================================

# 設定
BOT_TOKEN_MAX_RETRIES="${BOT_TOKEN_MAX_RETRIES:-3}"
BOT_TOKEN_RETRY_DELAY="${BOT_TOKEN_RETRY_DELAY:-2}"
BOT_TOKEN_CACHE_TTL="${BOT_TOKEN_CACHE_TTL:-3300}"  # 55分（トークン有効期限1時間より余裕を持たせる）

# キャッシュディレクトリの決定
_get_cache_dir() {
    if [[ -n "${WORKSPACE_DIR:-}" ]]; then
        echo "$WORKSPACE_DIR/state"
    elif [[ -n "${IGNITE_WORKSPACE_DIR:-}" ]]; then
        echo "$IGNITE_WORKSPACE_DIR/state"
    else
        echo "/tmp/ignite-token-cache"
    fi
}

# キャッシュからBot Tokenを取得（なければ新規取得してキャッシュ）
get_cached_bot_token() {
    local repo="$1"
    local cache_dir
    cache_dir=$(_get_cache_dir)
    local cache_key
    cache_key=$(echo "$repo" | tr '/' '_')
    local cache_file="$cache_dir/.bot_token_${cache_key}"

    mkdir -p "$cache_dir"
    chmod 700 "$cache_dir" 2>/dev/null || true

    # キャッシュ確認
    if [[ -f "$cache_file" ]]; then
        local cached_at now remaining
        cached_at=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)
        now=$(date +%s)
        remaining=$((BOT_TOKEN_CACHE_TTL - (now - cached_at)))

        if (( remaining > 0 )); then
            local cached_token
            cached_token=$(cat "$cache_file" 2>/dev/null)
            if [[ "$cached_token" == ghs_* ]]; then
                log_info "キャッシュからBot Tokenを使用 (残り: ${remaining}秒)"
                echo "$cached_token"
                return 0
            fi
        else
            # キャッシュ期限切れ
            rm -f "$cache_file"
        fi
    fi

    # キャッシュなし/期限切れ: 新規取得
    local token
    token=$(_get_bot_token_internal "$repo")

    if [[ -n "$token" ]] && [[ "$token" == ghs_* ]]; then
        echo "$token" > "$cache_file"
        chmod 600 "$cache_file"
        log_info "Bot Tokenを新規取得しキャッシュ (TTL: ${BOT_TOKEN_CACHE_TTL}秒)"
        echo "$token"
        return 0
    fi

    echo ""
    return 1
}

# 内部用: 実際のトークン取得（リトライ機構付き）
_get_bot_token_internal() {
    local repo="${1:-}"
    local retry_count=0
    local token=""
    local last_error=""
    local token_script="${SCRIPT_DIR}/get_github_app_token.sh"
    local repo_option=""

    # リポジトリが指定されている場合は --repo オプションを使用（Organization対応）
    if [[ -n "$repo" ]]; then
        repo_option="--repo $repo"
    fi

    while [[ $retry_count -lt $BOT_TOKEN_MAX_RETRIES ]]; do
        # トークン取得を試行
        # IGNITE_CONFIG_DIR が設定されていれば、github-app.yaml のパスを渡す
        if [[ -n "${IGNITE_CONFIG_DIR:-}" ]]; then
            token=$(IGNITE_GITHUB_CONFIG="${IGNITE_CONFIG_DIR}/github-app.yaml" "$token_script" $repo_option 2>&1)
        else
            token=$("$token_script" $repo_option 2>&1)
        fi
        local exit_code=$?

        if [[ $exit_code -eq 0 ]] && [[ -n "$token" ]] && [[ "$token" == ghs_* ]]; then
            # 成功: ghs_ プレフィックスで始まる有効なトークン
            echo "$token"
            return 0
        fi

        # 失敗: エラー内容を保存
        last_error="$token"
        retry_count=$((retry_count + 1))

        if [[ $retry_count -lt $BOT_TOKEN_MAX_RETRIES ]]; then
            log_warn "Bot Token取得失敗 (試行 $retry_count/$BOT_TOKEN_MAX_RETRIES)。${BOT_TOKEN_RETRY_DELAY}秒後にリトライ..."
            sleep "$BOT_TOKEN_RETRY_DELAY"
        fi
    done

    # 全リトライ失敗
    log_warn "Bot Token取得失敗 (全${BOT_TOKEN_MAX_RETRIES}回の試行が失敗)"
    if [[ -n "$last_error" ]]; then
        log_warn "最後のエラー: $last_error"
    fi
    echo ""
    return 1
}

# 後方互換性のためのラッパー（get_cached_bot_token を使用）
get_bot_token() {
    get_cached_bot_token "$@"
}

# =============================================================================
# テンプレート生成
# =============================================================================

generate_from_template() {
    local template_type="$1"
    local context="${2:-}"

    case "$template_type" in
        acknowledge)
            cat <<'EOF'
このIssueを確認しました。処理を開始します。

---
*Generated by IGNITE AI Team*
EOF
            ;;
        success)
            cat <<EOF
✅ 処理が完了しました！

${context}

---
*Generated by IGNITE AI Team*
EOF
            ;;
        error)
            cat <<EOF
❌ 処理中にエラーが発生しました。

**エラー内容:**
${context}

---
*Generated by IGNITE AI Team*
EOF
            ;;
        progress)
            cat <<EOF
⏳ 処理中...

${context}

---
*Generated by IGNITE AI Team*
EOF
            ;;
        pr_created)
            cat <<EOF
✅ PRを作成しました！

${context}

レビューをお願いします。

---
*Generated by IGNITE AI Team*
EOF
            ;;
        review_complete)
            cat <<EOF
✅ レビューが完了しました！

${context}

---
*Generated by IGNITE AI Team*
EOF
            ;;
        *)
            log_error "Unknown template type: $template_type"
            exit 1
            ;;
    esac
}

# =============================================================================
# コメント投稿
# =============================================================================

post_comment() {
    local repo="$1"
    local issue_number="$2"
    local body="$3"
    local use_bot="$4"

    local token_args=""

    if [[ "$use_bot" == "true" ]]; then
        # リポジトリを渡してトークン取得（Organization対応）
        local bot_token
        bot_token=$(get_bot_token "$repo")
        if [[ -n "$bot_token" ]]; then
            log_info "Bot名義でコメントを投稿中..."
            GH_TOKEN="$bot_token" gh issue comment "$issue_number" --repo "$repo" --body "$body"
            return $?
        else
            log_warn "Bot Token取得失敗。通常のトークンで投稿します。"
        fi
    fi

    log_info "コメントを投稿中..."
    gh issue comment "$issue_number" --repo "$repo" --body "$body"
}

# =============================================================================
# メイン
# =============================================================================

main() {
    local issue_number=""
    local repo=""
    local body=""
    local template=""
    local template_context=""
    local use_bot=false

    # 引数解析
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -r|--repo)
                repo="$2"
                shift 2
                ;;
            -b|--body)
                body="$2"
                shift 2
                ;;
            -t|--template)
                template="$2"
                shift 2
                ;;
            -c|--context)
                template_context="$2"
                shift 2
                ;;
            --bot)
                use_bot=true
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
                if [[ -z "$issue_number" ]]; then
                    issue_number="$1"
                fi
                shift
                ;;
        esac
    done

    # Issue番号チェック
    if [[ -z "$issue_number" ]]; then
        log_error "Issue番号を指定してください"
        echo ""
        show_help
        exit 1
    fi

    # リポジトリ推測
    if [[ -z "$repo" ]]; then
        repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
        if [[ -z "$repo" ]]; then
            log_error "リポジトリを指定してください: --repo owner/repo"
            exit 1
        fi
        log_info "リポジトリを自動検出: $repo"
    fi

    # テンプレート使用
    if [[ -n "$template" ]]; then
        body=$(generate_from_template "$template" "$template_context")
    fi

    # 本文チェック
    if [[ -z "$body" ]]; then
        log_error "コメント本文を指定してください: --body または --template"
        exit 1
    fi

    # 投稿
    if post_comment "$repo" "$issue_number" "$body" "$use_bot"; then
        log_success "コメントを投稿しました: Issue #$issue_number"
    else
        log_error "コメント投稿に失敗しました"
        exit 1
    fi
}

main "$@"

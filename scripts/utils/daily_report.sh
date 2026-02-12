#!/bin/bash
# 日次レポート Issue 管理スクリプト
# 作業対象リポジトリごとに日次レポート Issue を自動作成・管理する
#
# 使用方法:
#   ./scripts/utils/daily_report.sh <subcommand> [options]
#
# サブコマンド:
#   create    --repo owner/repo [--date YYYY-MM-DD] [--body "..."]
#   update    --repo owner/repo --issue NUM --body "..."
#   comment   --repo owner/repo [--issue NUM] --body "..."
#   close     --repo owner/repo [--issue NUM]
#   close-all [--date YYYY-MM-DD]
#   ensure    --repo owner/repo [--date YYYY-MM-DD]

set -e
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/core.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${WORKSPACE_DIR:-}" ]] && setup_workspace_config "$WORKSPACE_DIR"

# バージョン（core.sh から取得済み）
IGNITE_VERSION="${VERSION:-unknown}"

# =============================================================================
# 定数
# =============================================================================

REPORT_LABEL="ignite-report"
REPORT_LABEL_COLOR="1d76db"
REPORT_LABEL_DESCRIPTION="IGNITE daily activity report"

# =============================================================================
# 入力バリデーション
# =============================================================================

_validate_repo() {
    local repo="$1"
    # owner/repo 形式: 英数字・ハイフン・アンダースコア・ドットのみ許可
    if [[ ! "$repo" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
        log_error "無効なリポジトリ形式です: $repo（owner/repo 形式で指定してください）"
        return 1
    fi
}

_validate_issue_num() {
    local num="$1"
    if [[ ! "$num" =~ ^[1-9][0-9]*$ ]]; then
        log_error "無効な Issue 番号です: $num"
        return 1
    fi
}

_validate_date() {
    local d="$1"
    if [[ ! "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        log_error "無効な日付形式です: $d（YYYY-MM-DD 形式で指定してください）"
        return 1
    fi
}

# =============================================================================
# Bot Token / GitHub API 共通関数の読み込み
# =============================================================================

source "${SCRIPT_DIR}/github_helpers.sh"

# =============================================================================
# キャッシュ管理
# =============================================================================

_get_cache_file() {
    local cache_dir
    cache_dir=$(_get_cache_dir)
    mkdir -p "$cache_dir"
    echo "$cache_dir/report_issues.json"
}

_read_cache() {
    local cache_file
    cache_file=$(_get_cache_file)
    if [[ -f "$cache_file" ]] && jq empty "$cache_file" 2>/dev/null; then
        cat "$cache_file"
    else
        echo "{}"
    fi
}

_update_cache() {
    local repo="$1"
    local date="$2"
    local issue_num="$3"
    local cache_file
    cache_file=$(_get_cache_file)

    local tmp_file
    tmp_file=$(mktemp)

    local current
    current=$(_read_cache)

    if echo "$current" | jq --arg repo "$repo" --arg date "$date" --argjson num "$issue_num" \
        '.[$repo][$date] = $num' > "$tmp_file" 2>/dev/null; then
        mv "$tmp_file" "$cache_file"
    else
        rm -f "$tmp_file"
        log_warn "キャッシュの更新に失敗しました ($repo, $date)"
    fi
}

_get_cached_issue() {
    local repo="$1"
    local date="$2"

    local cache
    cache=$(_read_cache)
    echo "$cache" | jq -r --arg repo "$repo" --arg date "$date" \
        '.[$repo][$date] // empty'
}

_list_cached_repos() {
    local date="$1"

    local cache
    cache=$(_read_cache)
    echo "$cache" | jq -r --arg date "$date" \
        'to_entries[] | select(.value[$date] != null) | .key'
}

# =============================================================================
# ラベル管理
# =============================================================================

ensure_label() {
    local repo="$1"

    # ラベルが存在するか REST API で確認（冪等）
    if _gh_api "$repo" api "repos/$repo/labels/$REPORT_LABEL" &>/dev/null; then
        return 0
    fi

    log_info "ラベル '$REPORT_LABEL' を作成中..."
    if _gh_api "$repo" label create "$REPORT_LABEL" \
        --repo "$repo" \
        --color "$REPORT_LABEL_COLOR" \
        --description "$REPORT_LABEL_DESCRIPTION" &>/dev/null; then
        log_success "ラベル '$REPORT_LABEL' を作成しました"
    else
        log_warn "ラベル作成に失敗しました（既に存在する可能性があります）"
    fi
}

# =============================================================================
# Issue ディスカバリー
# =============================================================================

find_today_issue() {
    local repo="$1"
    local date="$2"

    # Step 1: キャッシュを確認
    local cached_num
    cached_num=$(_get_cached_issue "$repo" "$date")
    if [[ -n "$cached_num" ]]; then
        # キャッシュに Issue がある場合、まだ open か確認
        local state
        state=$(_gh_api "$repo" issue view "$cached_num" --repo "$repo" --json state -q '.state' 2>/dev/null || echo "")
        if [[ "$state" == "OPEN" ]]; then
            echo "$cached_num"
            return 0
        fi
        # close されていたらキャッシュは無効（再作成が必要）
        log_warn "キャッシュされたIssue #$cached_num は既にcloseされています"
    fi

    # Step 2: API で検索
    local title_prefix="IGNITE Daily Report - $date"
    local issue_num
    issue_num=$(_gh_api "$repo" issue list \
        --repo "$repo" \
        --label "$REPORT_LABEL" \
        --state open \
        --search "in:title \"$title_prefix\"" \
        --json number \
        -q '.[0].number // empty' 2>/dev/null || echo "")

    if [[ -n "$issue_num" ]]; then
        # キャッシュを更新
        _update_cache "$repo" "$date" "$issue_num"
        echo "$issue_num"
        return 0
    fi

    # Issue が見つからない
    echo ""
    return 1
}

# =============================================================================
# Issue 本文生成
# =============================================================================

generate_initial_body() {
    local repo="$1"
    local date="$2"

    cat <<EOF
# IGNITE Daily Report

**IGNITE Version:** v$IGNITE_VERSION
**Repository:** \`$repo\`
**Date:** $date

---

## Activity Log

_Activities will be logged as comments on this issue._

---
*Generated by [IGNITE](https://github.com/myfinder/ignite) AI Team*
EOF
}

# =============================================================================
# サブコマンド実装
# =============================================================================

cmd_create() {
    local repo="" date="" body=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo) repo="$2"; shift 2 ;;
            --date) date="$2"; shift 2 ;;
            --body) body="$2"; shift 2 ;;
            *) log_error "不明なオプション: $1"; return 1 ;;
        esac
    done

    if [[ -z "$repo" ]]; then
        log_error "--repo は必須です"
        return 1
    fi

    date="${date:-$(date +%Y-%m-%d)}"
    _validate_repo "$repo" || return 1
    _validate_date "$date" || return 1

    if [[ -z "$body" ]]; then
        body=$(generate_initial_body "$repo" "$date")
    fi

    # ラベルを確保
    ensure_label "$repo"

    local title="IGNITE Daily Report - $date"

    log_info "日次レポート Issue を作成中: $repo ($date)"
    local issue_url
    issue_url=$(_gh_api "$repo" issue create \
        --repo "$repo" \
        --title "$title" \
        --body "$body" \
        --label "$REPORT_LABEL" 2>/dev/null) || true

    if [[ -z "$issue_url" ]]; then
        log_error "Issue の作成に失敗しました"
        return 1
    fi

    # URL から Issue 番号を抽出
    local issue_num
    issue_num=$(echo "$issue_url" | grep -oE '[0-9]+$' || true)

    if [[ -n "$issue_num" ]]; then
        _update_cache "$repo" "$date" "$issue_num"
        log_success "日次レポート Issue #$issue_num を作成しました: $issue_url"
        echo "$issue_num"
        return 0
    else
        log_error "Issue 番号の抽出に失敗しました: $issue_url"
        return 1
    fi
}

cmd_update() {
    local repo="" issue_num="" body=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo) repo="$2"; shift 2 ;;
            --issue) issue_num="$2"; shift 2 ;;
            --body) body="$2"; shift 2 ;;
            *) log_error "不明なオプション: $1"; return 1 ;;
        esac
    done

    if [[ -z "$repo" ]] || [[ -z "$issue_num" ]] || [[ -z "$body" ]]; then
        log_error "--repo, --issue, --body は全て必須です"
        return 1
    fi
    _validate_repo "$repo" || return 1
    _validate_issue_num "$issue_num" || return 1

    log_info "Issue #$issue_num の本文を更新中..."
    if _gh_api "$repo" issue edit "$issue_num" --repo "$repo" --body "$body" &>/dev/null; then
        log_success "Issue #$issue_num を更新しました"
    else
        log_error "Issue #$issue_num の更新に失敗しました"
        return 1
    fi
}

cmd_comment() {
    local repo="" issue_num="" body="" date=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo) repo="$2"; shift 2 ;;
            --issue) issue_num="$2"; shift 2 ;;
            --body) body="$2"; shift 2 ;;
            --date) date="$2"; shift 2 ;;
            *) log_error "不明なオプション: $1"; return 1 ;;
        esac
    done

    if [[ -z "$repo" ]] || [[ -z "$body" ]]; then
        log_error "--repo と --body は必須です"
        return 1
    fi

    date="${date:-$(date +%Y-%m-%d)}"
    _validate_repo "$repo" || return 1
    _validate_date "$date" || return 1
    if [[ -n "$issue_num" ]]; then
        _validate_issue_num "$issue_num" || return 1
    fi

    # Issue 番号が未指定の場合は ensure で取得
    if [[ -z "$issue_num" ]]; then
        issue_num=$(cmd_ensure --repo "$repo" --date "$date") || true
        if [[ -z "$issue_num" ]]; then
            log_error "日次レポート Issue の確保に失敗しました"
            return 1
        fi
    fi

    log_info "Issue #$issue_num にコメントを追加中..."
    if _gh_api "$repo" api "/repos/${repo}/issues/${issue_num}/comments" -f body="$body" --silent &>/dev/null; then
        log_success "Issue #$issue_num にコメントを追加しました"
    else
        log_error "Issue #$issue_num へのコメント追加に失敗しました"
        return 1
    fi
}

cmd_close() {
    local repo="" issue_num="" date=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo) repo="$2"; shift 2 ;;
            --issue) issue_num="$2"; shift 2 ;;
            --date) date="$2"; shift 2 ;;
            *) log_error "不明なオプション: $1"; return 1 ;;
        esac
    done

    if [[ -z "$repo" ]]; then
        log_error "--repo は必須です"
        return 1
    fi

    date="${date:-$(date +%Y-%m-%d)}"
    _validate_repo "$repo" || return 1
    _validate_date "$date" || return 1
    if [[ -n "$issue_num" ]]; then
        _validate_issue_num "$issue_num" || return 1
    fi

    # Issue 番号が未指定の場合はキャッシュ/検索で取得
    if [[ -z "$issue_num" ]]; then
        issue_num=$(find_today_issue "$repo" "$date") || true
        if [[ -z "$issue_num" ]]; then
            log_info "close 対象の日次レポート Issue が見つかりません ($repo, $date)"
            return 0
        fi
    fi

    log_info "Issue #$issue_num を close 中..."

    # close 時にサマリーコメントを追加
    local close_comment
    close_comment=$(cat <<EOF
## Session Closed

IGNITE session ended at $(date '+%Y-%m-%d %H:%M:%S %Z').

---
*Generated by [IGNITE](https://github.com/myfinder/ignite) AI Team*
EOF
)
    _gh_api "$repo" api "/repos/${repo}/issues/${issue_num}/comments" -f body="$close_comment" --silent &>/dev/null || true
    if _gh_api "$repo" issue close "$issue_num" --repo "$repo" &>/dev/null; then
        log_success "Issue #$issue_num を close しました"
    else
        log_error "Issue #$issue_num の close に失敗しました"
        return 1
    fi
}

cmd_close_all() {
    local date=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --date) date="$2"; shift 2 ;;
            *) log_error "不明なオプション: $1"; return 1 ;;
        esac
    done

    date="${date:-$(date +%Y-%m-%d)}"
    _validate_date "$date" || return 1

    log_info "全リポジトリの日次レポートを close 中 ($date)..."

    local repos
    repos=$(_list_cached_repos "$date" || true)

    if [[ -z "$repos" ]]; then
        log_info "close 対象の日次レポートはありません"
        return 0
    fi

    local failed=0
    while IFS= read -r repo; do
        [[ -z "$repo" ]] && continue
        if ! cmd_close --repo "$repo" --date "$date"; then
            log_warn "$repo の日次レポート close に失敗しました"
            failed=1
        fi
    done <<< "$repos"

    if [[ $failed -eq 0 ]]; then
        log_success "全リポジトリの日次レポートを close しました"
    else
        log_warn "一部のリポジトリで close に失敗しました"
    fi
}

cmd_ensure() {
    local repo="" date=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo) repo="$2"; shift 2 ;;
            --date) date="$2"; shift 2 ;;
            *) log_error "不明なオプション: $1"; return 1 ;;
        esac
    done

    if [[ -z "$repo" ]]; then
        log_error "--repo は必須です"
        return 1
    fi

    date="${date:-$(date +%Y-%m-%d)}"
    _validate_repo "$repo" || return 1
    _validate_date "$date" || return 1

    # 既存の Issue を検索
    local issue_num
    issue_num=$(find_today_issue "$repo" "$date") || true

    if [[ -n "$issue_num" ]]; then
        log_info "既存の日次レポート Issue #$issue_num を使用します ($repo, $date)"
        echo "$issue_num"
        return 0
    fi

    # 存在しない場合は新規作成
    log_info "日次レポート Issue が存在しないため新規作成します ($repo, $date)"
    issue_num=$(cmd_create --repo "$repo" --date "$date") || true

    if [[ -n "$issue_num" ]]; then
        echo "$issue_num"
        return 0
    fi

    # create 失敗: 別プロセスが先に作成した可能性があるので再検索
    issue_num=$(find_today_issue "$repo" "$date") || true
    if [[ -n "$issue_num" ]]; then
        log_info "他プロセスが作成した日次レポート Issue #$issue_num を使用します ($repo, $date)"
        echo "$issue_num"
        return 0
    fi

    log_error "日次レポート Issue の作成に失敗しました"
    return 1
}

# =============================================================================
# ヘルプ
# =============================================================================

show_help() {
    cat << 'EOF'
日次レポート Issue 管理スクリプト

使用方法:
  daily_report.sh <subcommand> [options]

サブコマンド:
  create      日次レポート Issue を新規作成
  update      Issue 本文を更新
  comment     Issue にコメントを追加
  close       日次レポート Issue を close
  close-all   キャッシュ内の全リポジトリの当日 Issue を close
  ensure      Issue が存在しなければ作成、あれば番号を返す

共通オプション:
  --repo <owner/repo>   対象リポジトリ（必須: create, update, comment, close, ensure）
  --date <YYYY-MM-DD>   対象日付（デフォルト: 今日）
  --issue <NUM>         Issue 番号（update では必須、comment/close では省略可）
  --body <text>         本文（update/comment では必須、create では省略可）
  -h, --help            このヘルプを表示

使用例:
  # Issue を確保（なければ作成）
  daily_report.sh ensure --repo myfinder/IGNITE

  # コメント追加
  daily_report.sh comment --repo myfinder/IGNITE --body "作業開始: Issue #42"

  # 当日の全レポートを close
  daily_report.sh close-all
EOF
}

# =============================================================================
# メイン
# =============================================================================

main() {
    if [[ $# -eq 0 ]]; then
        show_help
        exit 1
    fi

    local subcommand="$1"
    shift

    case "$subcommand" in
        create)    cmd_create "$@" ;;
        update)    cmd_update "$@" ;;
        comment)   cmd_comment "$@" ;;
        close)     cmd_close "$@" ;;
        close-all) cmd_close_all "$@" ;;
        ensure)    cmd_ensure "$@" ;;
        -h|--help) show_help ;;
        *)
            log_error "不明なサブコマンド: $subcommand"
            show_help
            exit 1
            ;;
    esac
}

main "$@"

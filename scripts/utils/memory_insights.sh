#!/bin/bash
# Memory Insights CLI ツール
# memoriesテーブルからデータ抽出・重複検索・Issue起票を行う
#
# 使用方法:
#   ./scripts/utils/memory_insights.sh <subcommand> [options]
#
# サブコマンド:
#   analyze           memoriesテーブルからデータ抽出（JSON配列）
#   check-duplicates  既存Issueとの重複検索
#   create-issue      Issue起票
#   comment-duplicate 既存Issueにコメント追加
#   list-issues       対象リポの既存openIssue一覧取得
#   summary           分析サマリー出力（デバッグ用）

set -e
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/core.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${WORKSPACE_DIR:-}" ]] && setup_workspace_config "$WORKSPACE_DIR"

# =============================================================================
# 共通関数の読み込み
# =============================================================================

source "${SCRIPT_DIR}/github_helpers.sh"

# =============================================================================
# 定数
# =============================================================================

INSIGHT_LABEL="ignite-insight"
INSIGHT_LABEL_COLOR="7057ff"
INSIGHT_LABEL_DESCRIPTION="Auto-generated improvement insight from IGNITE memory analysis"

# =============================================================================
# データベースパス解決
# =============================================================================

_get_db_path() {
    if [[ -n "${WORKSPACE_DIR:-}" ]]; then
        echo "$IGNITE_RUNTIME_DIR/state/memory.db"
    elif [[ -n "${IGNITE_WORKSPACE_DIR:-}" ]]; then
        echo "$IGNITE_WORKSPACE_DIR/.ignite/state/memory.db"
    else
        log_error "WORKSPACE_DIR または IGNITE_WORKSPACE_DIR が未設定です"
        return 1
    fi
}

# =============================================================================
# 入力バリデーション
# =============================================================================

_validate_repo() {
    local repo="$1"
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

# =============================================================================
# ラベル管理
# =============================================================================

ensure_insight_label() {
    local repo="$1"

    if _gh_api "$repo" api "repos/$repo/labels/$INSIGHT_LABEL" &>/dev/null; then
        return 0
    fi

    log_info "ラベル '$INSIGHT_LABEL' を作成中..."
    if _gh_api "$repo" label create "$INSIGHT_LABEL" \
        --repo "$repo" \
        --color "$INSIGHT_LABEL_COLOR" \
        --description "$INSIGHT_LABEL_DESCRIPTION" &>/dev/null; then
        log_success "ラベル '$INSIGHT_LABEL' を作成しました"
    else
        log_warn "ラベル作成に失敗しました（既に存在する可能性があります）"
    fi
}

# =============================================================================
# サブコマンド: analyze
# =============================================================================

cmd_analyze() {
    local types="learning,error,observation"
    local since=""
    local limit=200

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --types) types="$2"; shift 2 ;;
            --since) since="$2"; shift 2 ;;
            --limit) limit="$2"; shift 2 ;;
            *) log_error "不明なオプション: $1"; return 1 ;;
        esac
    done

    local db_path
    db_path=$(_get_db_path) || return 1

    if [[ ! -f "$db_path" ]]; then
        log_error "データベースが見つかりません: $db_path"
        echo "[]"
        return 0
    fi

    # insight_log テーブルが存在しなければ作成
    sqlite3 "$db_path" <<'ENDSQL' &>/dev/null || true
.timeout 5000
CREATE TABLE IF NOT EXISTS insight_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    memory_ids TEXT NOT NULL,
    repository TEXT NOT NULL,
    issue_number INTEGER,
    action TEXT NOT NULL,
    title TEXT,
    timestamp DATETIME DEFAULT (datetime('now', '+9 hours'))
);
CREATE INDEX IF NOT EXISTS idx_insight_log_repo ON insight_log(repository);
ENDSQL

    # types をSQL IN句に変換（'learning','error','observation'）
    local type_list=""
    IFS=',' read -ra TYPE_ARRAY <<< "$types"
    for t in "${TYPE_ARRAY[@]}"; do
        t=$(echo "$t" | xargs)  # trim
        if [[ -n "$type_list" ]]; then
            type_list="${type_list},"
        fi
        type_list="${type_list}'${t}'"
    done

    # since 条件
    local since_clause=""
    if [[ -n "$since" ]]; then
        since_clause="AND m.timestamp >= '${since}'"
    fi

    # 処理済みmemory IDを除外しつつ、指定typeのメモリをJSON出力
    local result
    result=$(sqlite3 -json "$db_path" 2>/dev/null <<ENDSQL
.timeout 5000
SELECT m.id, m.agent, m.type, m.content, m.context, m.task_id, m.timestamp
FROM memories m
WHERE m.type IN (${type_list})
  AND m.id NOT IN (
    SELECT DISTINCT value FROM insight_log, json_each(insight_log.memory_ids)
  )
  ${since_clause}
ORDER BY m.timestamp DESC
LIMIT ${limit};
ENDSQL
    ) || true

    if [[ -z "$result" ]]; then
        echo "[]"
    else
        echo "$result"
    fi
}

# =============================================================================
# サブコマンド: check-duplicates
# =============================================================================

cmd_check_duplicates() {
    local repo="" title=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo) repo="$2"; shift 2 ;;
            --title) title="$2"; shift 2 ;;
            *) log_error "不明なオプション: $1"; return 1 ;;
        esac
    done

    if [[ -z "$repo" ]] || [[ -z "$title" ]]; then
        log_error "--repo と --title は必須です"
        return 1
    fi
    _validate_repo "$repo" || return 1

    # ignite-insight ラベル + タイトルキーワードで検索
    local result
    result=$(_gh_api "$repo" issue list --repo "$repo" \
        --label "$INSIGHT_LABEL" \
        --state open \
        --search "in:title \"${title}\"" \
        --json number,title,url \
        -q '.' 2>/dev/null) || true

    if [[ -z "$result" ]]; then
        echo "[]"
    else
        echo "$result"
    fi
}

# =============================================================================
# サブコマンド: create-issue
# =============================================================================

cmd_create_issue() {
    local repo="" title="" body_file="" labels="" memory_ids=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo) repo="$2"; shift 2 ;;
            --title) title="$2"; shift 2 ;;
            --body-file) body_file="$2"; shift 2 ;;
            --labels) labels="$2"; shift 2 ;;
            --memory-ids) memory_ids="$2"; shift 2 ;;
            *) log_error "不明なオプション: $1"; return 1 ;;
        esac
    done

    if [[ -z "$repo" ]] || [[ -z "$title" ]] || [[ -z "$body_file" ]]; then
        log_error "--repo, --title, --body-file は必須です"
        return 1
    fi
    _validate_repo "$repo" || return 1

    if [[ ! -f "$body_file" ]]; then
        log_error "本文ファイルが見つかりません: $body_file"
        return 1
    fi

    # ラベルを確保
    ensure_insight_label "$repo"

    # ラベルの組み立て
    local label_args="--label $INSIGHT_LABEL"
    if [[ -n "$labels" ]]; then
        IFS=',' read -ra LABEL_ARRAY <<< "$labels"
        for l in "${LABEL_ARRAY[@]}"; do
            l=$(echo "$l" | xargs)  # trim
            label_args="${label_args} --label ${l}"
        done
    fi

    log_info "Issue を作成中: $repo - $title"
    local issue_url
    issue_url=$(_gh_api "$repo" issue create \
        --repo "$repo" \
        --title "$title" \
        --body-file "$body_file" \
        $label_args 2>/dev/null) || true

    if [[ -z "$issue_url" ]]; then
        log_error "Issue の作成に失敗しました"
        return 1
    fi

    # URL から Issue 番号を抽出
    local issue_num
    issue_num=$(echo "$issue_url" | grep -oE '[0-9]+$' || true)

    if [[ -z "$issue_num" ]]; then
        log_error "Issue 番号の抽出に失敗しました: $issue_url"
        return 1
    fi

    # insight_log に記録
    if [[ -n "$memory_ids" ]]; then
        _record_insight_log "$memory_ids" "$repo" "$issue_num" "created" "$title"
    fi

    log_success "Issue #$issue_num を作成しました: $issue_url"
    echo "$issue_num"
}

# =============================================================================
# サブコマンド: comment-duplicate
# =============================================================================

cmd_comment_duplicate() {
    local repo="" issue_num="" body_file="" memory_ids=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo) repo="$2"; shift 2 ;;
            --issue) issue_num="$2"; shift 2 ;;
            --body-file) body_file="$2"; shift 2 ;;
            --memory-ids) memory_ids="$2"; shift 2 ;;
            *) log_error "不明なオプション: $1"; return 1 ;;
        esac
    done

    if [[ -z "$repo" ]] || [[ -z "$issue_num" ]] || [[ -z "$body_file" ]]; then
        log_error "--repo, --issue, --body-file は必須です"
        return 1
    fi
    _validate_repo "$repo" || return 1
    _validate_issue_num "$issue_num" || return 1

    if [[ ! -f "$body_file" ]]; then
        log_error "本文ファイルが見つかりません: $body_file"
        return 1
    fi

    log_info "Issue #$issue_num にコメントを追加中..."
    if _gh_api "$repo" issue comment "$issue_num" \
        --repo "$repo" \
        --body-file "$body_file" &>/dev/null; then

        # insight_log に記録
        if [[ -n "$memory_ids" ]]; then
            _record_insight_log "$memory_ids" "$repo" "$issue_num" "commented" ""
        fi

        log_success "Issue #$issue_num にコメントを追加しました"
    else
        log_error "Issue #$issue_num へのコメント追加に失敗しました"
        return 1
    fi
}

# =============================================================================
# サブコマンド: list-issues
# =============================================================================

cmd_list_issues() {
    local repo="" limit=30

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo) repo="$2"; shift 2 ;;
            --limit) limit="$2"; shift 2 ;;
            *) log_error "不明なオプション: $1"; return 1 ;;
        esac
    done

    if [[ -z "$repo" ]]; then
        log_error "--repo は必須です"
        return 1
    fi
    _validate_repo "$repo" || return 1

    local result
    result=$(_gh_api "$repo" issue list --repo "$repo" \
        --state open \
        --limit "$limit" \
        --json number,title,labels,url \
        -q '.' 2>/dev/null) || true

    if [[ -z "$result" ]]; then
        echo "[]"
    else
        echo "$result"
    fi
}

# =============================================================================
# サブコマンド: summary
# =============================================================================

cmd_summary() {
    local since=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --since) since="$2"; shift 2 ;;
            *) log_error "不明なオプション: $1"; return 1 ;;
        esac
    done

    local db_path
    db_path=$(_get_db_path) || return 1

    if [[ ! -f "$db_path" ]]; then
        log_error "データベースが見つかりません: $db_path"
        return 1
    fi

    local since_clause=""
    if [[ -n "$since" ]]; then
        since_clause="AND timestamp >= '${since}'"
    fi

    echo "=== Memory Insights Summary ==="
    echo ""

    # タイプ別件数
    echo "--- メモリ件数（タイプ別） ---"
    sqlite3 "$db_path" 2>/dev/null <<ENDSQL || echo "(データなし)"
.timeout 5000
SELECT type, COUNT(*) as count
FROM memories
WHERE type IN ('learning','error','observation')
  ${since_clause}
GROUP BY type
ORDER BY count DESC;
ENDSQL

    echo ""

    # エージェント別件数
    echo "--- メモリ件数（エージェント別） ---"
    sqlite3 "$db_path" 2>/dev/null <<ENDSQL || echo "(データなし)"
.timeout 5000
SELECT agent, COUNT(*) as count
FROM memories
WHERE type IN ('learning','error','observation')
  ${since_clause}
GROUP BY agent
ORDER BY count DESC;
ENDSQL

    echo ""

    # 処理済み件数
    echo "--- Insight処理済み件数 ---"
    sqlite3 "$db_path" 2>/dev/null <<'ENDSQL' || echo "(insight_logテーブルなし)"
.timeout 5000
SELECT COUNT(*) as total_insights,
       SUM(CASE WHEN action='created' THEN 1 ELSE 0 END) as issues_created,
       SUM(CASE WHEN action='commented' THEN 1 ELSE 0 END) as comments_added
FROM insight_log;
ENDSQL

    echo ""

    # 未処理件数
    echo "--- 未処理メモリ件数 ---"
    # insight_log テーブルが存在するかチェック
    local has_insight_log
    has_insight_log=$(sqlite3 "$db_path" 2>/dev/null <<'ENDSQL' || echo "0"
.timeout 5000
SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='insight_log';
ENDSQL
    )

    if [[ "$has_insight_log" == "1" ]]; then
        sqlite3 "$db_path" 2>/dev/null <<ENDSQL || echo "(データなし)"
.timeout 5000
SELECT COUNT(*) as unprocessed
FROM memories m
WHERE m.type IN ('learning','error','observation')
  AND m.id NOT IN (
    SELECT DISTINCT value FROM insight_log, json_each(insight_log.memory_ids)
  )
  ${since_clause};
ENDSQL
    else
        sqlite3 "$db_path" 2>/dev/null <<ENDSQL || echo "(データなし)"
.timeout 5000
SELECT COUNT(*) as unprocessed
FROM memories
WHERE type IN ('learning','error','observation')
  ${since_clause};
ENDSQL
    fi
}

# =============================================================================
# 内部関数: insight_log 記録
# =============================================================================

_record_insight_log() {
    local memory_ids="$1"
    local repo="$2"
    local issue_num="$3"
    local action="$4"
    local title="${5:-}"

    local db_path
    db_path=$(_get_db_path) || return 1

    if [[ ! -f "$db_path" ]]; then
        log_warn "データベースが見つかりません。insight_log 記録をスキップします"
        return 0
    fi

    # insight_log テーブルが存在しなければ作成
    sqlite3 "$db_path" &>/dev/null <<'ENDSQL' || true
.timeout 5000
CREATE TABLE IF NOT EXISTS insight_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    memory_ids TEXT NOT NULL,
    repository TEXT NOT NULL,
    issue_number INTEGER,
    action TEXT NOT NULL,
    title TEXT,
    timestamp DATETIME DEFAULT (datetime('now', '+9 hours'))
);
ENDSQL

    # SQL injection対策: シングルクォートを二重化
    local safe_title="${title//\'/\'\'}"
    local safe_repo="${repo//\'/\'\'}"
    local safe_memory_ids="${memory_ids//\'/\'\'}"

    sqlite3 "$db_path" &>/dev/null <<ENDSQL || log_warn "insight_log への記録に失敗しました"
.timeout 5000
INSERT INTO insight_log (memory_ids, repository, issue_number, action, title)
VALUES ('${safe_memory_ids}', '${safe_repo}', ${issue_num}, '${action}', '${safe_title}');
ENDSQL
}

# =============================================================================
# ヘルプ
# =============================================================================

show_help() {
    cat << 'EOF'
Memory Insights CLI ツール

使用方法:
  memory_insights.sh <subcommand> [options]

サブコマンド:
  analyze           memoriesテーブルからデータ抽出（JSON配列）
  check-duplicates  既存Issueとの重複検索
  create-issue      Issue起票
  comment-duplicate 既存Issueにコメント追加
  list-issues       対象リポの既存openIssue一覧取得
  summary           分析サマリー出力（デバッグ用）

analyze オプション:
  --types <types>     カンマ区切りのタイプ（デフォルト: learning,error,observation）
  --since <datetime>  指定日時以降のみ抽出
  --limit <num>       最大件数（デフォルト: 200）

check-duplicates オプション:
  --repo <owner/repo>  対象リポジトリ（必須）
  --title <title>      検索タイトル（必須）

create-issue オプション:
  --repo <owner/repo>  対象リポジトリ（必須）
  --title <title>      Issueタイトル（必須）
  --body-file <path>   本文ファイルパス（必須）
  --labels <labels>    追加ラベル（カンマ区切り）
  --memory-ids <json>  処理対象のmemory IDリスト（JSON配列文字列）

comment-duplicate オプション:
  --repo <owner/repo>  対象リポジトリ（必須）
  --issue <num>        Issue番号（必須）
  --body-file <path>   本文ファイルパス（必須）
  --memory-ids <json>  処理対象のmemory IDリスト（JSON配列文字列）

list-issues オプション:
  --repo <owner/repo>  対象リポジトリ（必須）
  --limit <num>        最大件数（デフォルト: 30）

summary オプション:
  --since <datetime>  指定日時以降のみ集計

使用例:
  # メモリ抽出
  memory_insights.sh analyze --types learning,error,observation

  # 重複検索
  memory_insights.sh check-duplicates --repo myfinder/ignite --title "git操作"

  # Issue起票
  memory_insights.sh create-issue --repo myfinder/ignite --title "改善提案" \
    --body-file /tmp/body.md --memory-ids "[1,5,12]"

  # サマリー表示
  memory_insights.sh summary
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
        analyze)           cmd_analyze "$@" ;;
        check-duplicates)  cmd_check_duplicates "$@" ;;
        create-issue)      cmd_create_issue "$@" ;;
        comment-duplicate) cmd_comment_duplicate "$@" ;;
        list-issues)       cmd_list_issues "$@" ;;
        summary)           cmd_summary "$@" ;;
        -h|--help)         show_help ;;
        *)
            log_error "不明なサブコマンド: $subcommand"
            show_help
            exit 1
            ;;
    esac
}

main "$@"

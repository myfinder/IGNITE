#!/bin/bash
# キュー監視・自動処理スクリプト
# キューに新しいメッセージが来たら、対応するエージェントに処理を指示
#
# 配信保証: at-least-once（リトライ機構統合済み）
#   - at-most-once: mv → process の原子性で重複防止
#   - タイムアウト検知 + process_retry() でリトライ保証
#
# 状態遷移図:
#   queue/*.mime
#     │ mv → processed/
#     ▼
#   [processing] ── send_to_agent成功 ──→ [delivered] (完了)
#     │
#     │ timeout (mtime > task_timeout)
#     ▼
#   [retrying] ── retry_count < MAX ──→ queue/*.mime に戻す (再処理)
#     │
#     │ retry_count >= MAX
#     ▼
#   [dead_letter] + escalate_to_leader()

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# グレースフル停止用フラグ（trap内ではフラグを立てるだけ、exit()を呼ばない）
_SHUTDOWN_REQUESTED=false
_SHUTDOWN_SIGNAL=""
_EXIT_CODE=0

# SIGHUP設定リロード用フラグ（trap内では直接設定変更を行わない）
_RELOAD_REQUESTED=false

# カラー定義
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# ログ出力（すべて標準エラー出力に出力して、コマンド置換で混入しないようにする）
log_info() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${BLUE}[QUEUE]${NC} $1" >&2; }
log_success() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${GREEN}[QUEUE]${NC} $1" >&2; }
log_warn() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${YELLOW}[QUEUE]${NC} $1" >&2; }
log_error() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${RED}[QUEUE]${NC} $1" >&2; }

# リトライ/DLQ ハンドラーの読み込み（SCRIPT_DIR/WORKSPACE_DIR保護）
_QM_SCRIPT_DIR="$SCRIPT_DIR"
_QM_WORKSPACE_DIR="${WORKSPACE_DIR:-}"
source "${SCRIPT_DIR}/../lib/retry_handler.sh"
source "${SCRIPT_DIR}/../lib/dlq_handler.sh"
SCRIPT_DIR="$_QM_SCRIPT_DIR"
WORKSPACE_DIR="${_QM_WORKSPACE_DIR}"

# yaml_utils（task_timeout動的読み取り用）
if [[ -f "${SCRIPT_DIR}/../lib/yaml_utils.sh" ]]; then
    source "${SCRIPT_DIR}/../lib/yaml_utils.sh"
fi

# MIME ヘルパー
IGNITE_MIME="${SCRIPT_DIR}/../lib/ignite_mime.py"

# MIMEメッセージからフィールドを取得する
mime_get() {
    local file="$1" field="$2"
    python3 "$IGNITE_MIME" parse "$file" 2>/dev/null | jq -r ".${field} // empty" 2>/dev/null
}

# MIMEメッセージからボディ内のYAMLフィールドを取得する
mime_body_get() {
    local file="$1" field="$2"
    python3 "$IGNITE_MIME" extract-body "$file" 2>/dev/null | grep -E "^\\s*${field}:" | head -1 | sed "s/.*${field}:[[:space:]]*//" | tr -d '"'
}

# MIMEメッセージのステータスを更新する
mime_update_status() {
    local file="$1" new_status="$2"
    local extra_args=()
    if [[ $# -ge 3 ]]; then
        extra_args=("--processed-at" "$3")
    fi
    python3 "$IGNITE_MIME" update-status "$file" "$new_status" "${extra_args[@]}" 2>/dev/null
}

# Bot Token キャッシュのプリウォーム（有効期限前に更新）
_refresh_bot_token_cache() {
    local config_dir="${IGNITE_CONFIG_DIR:-$PROJECT_ROOT/config}"
    local watcher_config="$config_dir/github-watcher.yaml"
    [[ -f "$watcher_config" ]] || return 0

    # NOTE: 同一の sed パターンが agent.sh _resolve_bot_token にも存在する
    local repo
    repo=$(sed -n '/repositories:/,/^[^ ]/{
        /- repo:/{
            s/.*- repo: *//
            s/ *#.*//
            s/["\x27]//g
            s/ *$//
            p; q
        }
    }' "$watcher_config" 2>/dev/null)
    [[ -z "$repo" ]] && return 0

    (
        SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
        source "${SCRIPT_DIR}/github_helpers.sh" 2>/dev/null
        get_cached_bot_token "$repo" >/dev/null 2>&1
    ) && log_info "Bot Tokenキャッシュを更新しました" || true
}

# 設定
WORKSPACE_DIR="${WORKSPACE_DIR:-$PROJECT_ROOT/workspace}"
POLL_INTERVAL="${QUEUE_POLL_INTERVAL:-10}"
TMUX_SESSION="${IGNITE_TMUX_SESSION:-}"

# tmux window名を system.yaml から取得
_QM_CONFIG_DIR="${IGNITE_CONFIG_DIR:-$PROJECT_ROOT/config}"
TMUX_WINDOW_NAME=$(sed -n '/^tmux:/,/^[^ ]/p' "$_QM_CONFIG_DIR/system.yaml" 2>/dev/null \
    | awk -F': ' '/^  window_name:/{print $2; exit}' | tr -d '"' | tr -d "'")
TMUX_WINDOW_NAME="${TMUX_WINDOW_NAME:-ignite}"

# task_timeout を system.yaml から動的取得（デフォルト: 300秒）
_TASK_TIMEOUT=""
_resolve_task_timeout() {
    if [[ -n "$_TASK_TIMEOUT" ]]; then
        echo "$_TASK_TIMEOUT"
        return
    fi
    local config_dir="${IGNITE_CONFIG_DIR:-$PROJECT_ROOT/config}"
    local sys_yaml="${config_dir}/system.yaml"
    if declare -f yaml_get &>/dev/null && [[ -f "$sys_yaml" ]]; then
        _TASK_TIMEOUT=$(yaml_get "$sys_yaml" "task_timeout" "300")
    else
        _TASK_TIMEOUT="${RETRY_TIMEOUT:-300}"
    fi
    echo "$_TASK_TIMEOUT"
}

# =============================================================================
# tmux セッションへのメッセージ送信
# =============================================================================

# =============================================================================
# 関数名: send_to_agent
# 目的: 指定されたエージェントのtmuxペインにメッセージを送信する
# 引数:
#   $1 - エージェント名（例: "leader", "strategist", "ignitian-1"）
#   $2 - 送信するメッセージ文字列
# 戻り値: 0=成功, 1=失敗
# 注意:
#   - TMUX_SESSION 環境変数が設定されている必要がある
#   - ペインインデックスはIGNITEの固定レイアウトに基づく
# =============================================================================
send_to_agent() {
    local agent="$1"
    local message="$2"
    local pane_index

    if [[ -z "$TMUX_SESSION" ]]; then
        log_error "TMUX_SESSION が設定されていません"
        return 1
    fi

    # =========================================================================
    # ペインインデックス計算ロジック
    # =========================================================================
    # IGNITEのtmuxレイアウト:
    #   ペイン 0: Leader
    #   ペイン 1-5: Sub-Leaders (strategist, architect, evaluator, coordinator, innovator)
    #   ペイン 6+: IGNITIANs (ワーカー)
    #
    # IGNITIANのペイン番号計算（IDは1始まり）:
    #   ignitian-1 → ペイン 6 (1 + 5)
    #   ignitian-2 → ペイン 7 (2 + 5)
    #   ignitian-N → ペイン N+5
    # =========================================================================
    case "$agent" in
        leader) pane_index=0 ;;
        strategist) pane_index=1 ;;
        architect) pane_index=2 ;;
        evaluator) pane_index=3 ;;
        coordinator) pane_index=4 ;;
        innovator) pane_index=5 ;;
        *)
            # IGNITIAN の場合は名前からインデックスを推測
            # ignitian-N または ignitian_N 形式に対応
            if [[ "$agent" =~ ^ignitian[-_]([0-9]+)$ ]]; then
                local num=${BASH_REMATCH[1]}
                pane_index=$((num + 5))  # Sub-Leaders(0-5) + IGNITIAN番号(1始まり) = 5 + num
            else
                log_warn "未知のエージェント: $agent"
                return 1
            fi
            ;;
    esac

    # tmux でメッセージを送信（ペイン指定）
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        # ペインにメッセージを送信
        # 形式: session:window.pane (window は省略すると現在のウィンドウ)
        local target="${TMUX_SESSION}:${TMUX_WINDOW_NAME}.${pane_index}"

        # メッセージを送信してからEnter（C-m）を送信
        # 少し間を置いてから送信することで確実に入力される
        if tmux send-keys -t "$target" "$message" 2>/dev/null; then
            sleep 0.3
            tmux send-keys -t "$target" C-m 2>/dev/null
            log_success "エージェント $agent (pane $pane_index) にメッセージを送信しました"
            return 0
        else
            log_warn "ペイン $pane_index への送信に失敗しました（ペインが存在しない可能性）"
            return 1
        fi
    else
        log_error "tmux セッションが見つかりません: $TMUX_SESSION"
        return 1
    fi
}

# =============================================================================
# 日次レポート連携
# =============================================================================

_get_report_cache_dir() {
    if [[ -n "${WORKSPACE_DIR:-}" ]]; then
        echo "$WORKSPACE_DIR/state"
    else
        echo "/tmp/ignite-token-cache"
    fi
}

_trigger_daily_report() {
    local repo="$1"
    local issue_num="${2:-}"
    local trigger="${3:-}"

    local daily_report_script="${SCRIPT_DIR}/daily_report.sh"
    if [[ ! -x "$daily_report_script" ]]; then
        return 0
    fi

    # Issue を確保（なければ作成）
    local report_issue
    report_issue=$(WORKSPACE_DIR="$WORKSPACE_DIR" "$daily_report_script" ensure --repo "$repo" 2>/dev/null) || {
        log_warn "日次レポート Issue の確保に失敗しました ($repo)"
        return 0
    }

    if [[ -z "$report_issue" ]]; then
        return 0
    fi

    # 作業開始コメントを追加
    local comment_body
    comment_body="### Task Started

- **Issue/PR:** #${issue_num}
- **Trigger:** ${trigger}
- **Time:** $(date '+%Y-%m-%d %H:%M:%S %Z')"

    WORKSPACE_DIR="$WORKSPACE_DIR" "$daily_report_script" comment \
        --repo "$repo" \
        --issue "$report_issue" \
        --body "$comment_body" 2>/dev/null || {
        log_warn "日次レポートへのコメント追加に失敗しました ($repo)"
    }
}

_report_progress() {
    local file="$1"

    local daily_report_script="${SCRIPT_DIR}/daily_report.sh"
    if [[ ! -x "$daily_report_script" ]]; then
        return 0
    fi

    # progress_update から情報を抽出
    local summary
    summary=$(grep -E '^\s+summary:' "$file" | head -1 | sed 's/^.*summary: *//; s/^"//; s/"$//')
    local tasks_completed
    tasks_completed=$(grep -E '^\s+tasks_completed:' "$file" | head -1 | awk '{print $2}')
    local tasks_total
    tasks_total=$(grep -E '^\s+tasks_total:' "$file" | head -1 | awk '{print $2}')
    local issue_id
    issue_id=$(grep -E '^\s+issue_id:' "$file" | head -1 | awk '{print $2}' | tr -d '"')
    # repository フィールドを抽出（あれば per-repo フィルタ）
    local msg_repo
    msg_repo=$(grep -E '^\s+repository:' "$file" | head -1 | awk '{print $2}' | tr -d '"')

    local cache_dir
    cache_dir=$(_get_report_cache_dir)
    local cache_file="$cache_dir/report_issues.json"
    [[ -f "$cache_file" ]] || return 0

    local today
    today=$(date +%Y-%m-%d)

    # repository 必須: なければ投稿スキップ
    if [[ -z "$msg_repo" ]]; then
        return 0
    fi
    local repos="$msg_repo"

    local comment_body
    comment_body="### Progress Update

- **Issue:** ${issue_id}
- **Tasks:** ${tasks_completed:-?}/${tasks_total:-?} completed
- **Summary:** ${summary:-N/A}
- **Time:** $(date '+%Y-%m-%d %H:%M:%S %Z')"

    while IFS= read -r repo; do
        [[ -z "$repo" ]] && continue
        local report_issue
        report_issue=$(jq -r --arg repo "$repo" --arg date "$today" '.[$repo][$date] // empty' "$cache_file" 2>/dev/null)
        [[ -n "$report_issue" ]] || continue

        WORKSPACE_DIR="$WORKSPACE_DIR" "$daily_report_script" comment \
            --repo "$repo" \
            --issue "$report_issue" \
            --body "$comment_body" 2>/dev/null || true
    done <<< "$repos"
}

_report_evaluation() {
    local file="$1"

    local daily_report_script="${SCRIPT_DIR}/daily_report.sh"
    if [[ ! -x "$daily_report_script" ]]; then
        return 0
    fi

    local issue_number
    issue_number=$(grep -E '^\s+issue_number:' "$file" | head -1 | awk '{print $2}' | tr -d '"')
    local verdict
    verdict=$(grep -E '^\s+verdict:' "$file" | head -1 | awk '{print $2}' | tr -d '"')
    local score
    score=$(grep -E '^\s+score:' "$file" | head -1 | awk '{print $2}' | tr -d '"')
    local title
    title=$(grep -E '^\s+title:' "$file" | head -1 | sed 's/^.*title: *//; s/^"//; s/"$//')
    # repository フィールドを抽出（あれば per-repo フィルタ）
    local msg_repo
    msg_repo=$(grep -E '^\s+repository:' "$file" | head -1 | awk '{print $2}' | tr -d '"')

    local cache_dir
    cache_dir=$(_get_report_cache_dir)
    local cache_file="$cache_dir/report_issues.json"
    [[ -f "$cache_file" ]] || return 0

    local today
    today=$(date +%Y-%m-%d)

    # repository 必須: なければ投稿スキップ
    if [[ -z "$msg_repo" ]]; then
        return 0
    fi
    local repos="$msg_repo"

    local verdict_emoji
    case "$verdict" in
        approve) verdict_emoji="✅" ;;
        reject|needs_revision) verdict_emoji="❌" ;;
        *) verdict_emoji="📋" ;;
    esac

    local comment_body
    comment_body="### Evaluation Result

- **Issue:** #${issue_number:-?}
- **Title:** ${title:-N/A}
- **Verdict:** ${verdict_emoji} ${verdict:-N/A}
- **Score:** ${score:-N/A}
- **Time:** $(date '+%Y-%m-%d %H:%M:%S %Z')"

    while IFS= read -r repo; do
        [[ -z "$repo" ]] && continue
        local report_issue
        report_issue=$(jq -r --arg repo "$repo" --arg date "$today" '.[$repo][$date] // empty' "$cache_file" 2>/dev/null)
        [[ -n "$report_issue" ]] || continue

        WORKSPACE_DIR="$WORKSPACE_DIR" "$daily_report_script" comment \
            --repo "$repo" \
            --issue "$report_issue" \
            --body "$comment_body" 2>/dev/null || true
    done <<< "$repos"
}

# =============================================================================
# ダッシュボード → 日次レポート同期
# =============================================================================

_generate_repo_report() {
    local repo="$1"
    local today="$2"
    local timestamp="$3"
    local db="$WORKSPACE_DIR/state/memory.db"
    local dashboard="$WORKSPACE_DIR/dashboard.md"

    # Layer 1: 入力バリデーション（Defense in Depth）
    if [[ ! "$repo" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
        log_warn "Invalid repository format: $repo"
        return 0
    fi

    local task_lines=""
    local sqlite_available=false

    # メインパス: SQLite tasksテーブルから直接取得
    if command -v sqlite3 &>/dev/null && [[ -f "$db" ]]; then
        sqlite_available=true
        # Layer 2: SQLエスケープ（シングルクォート二重化）
        local safe_repo="${repo//\'/\'\'}"
        local raw
        raw=$(sqlite3 "$db" \
            "PRAGMA busy_timeout=5000; SELECT task_id, title, status FROM tasks WHERE repository COLLATE NOCASE = '${safe_repo}' AND status != 'completed' ORDER BY task_id;" 2>/dev/null \
            | grep '|') || raw=""
        if [[ -n "$raw" ]]; then
            task_lines="| Task ID | Title | Status |"$'\n'
            task_lines+="|---------|-------|--------|"$'\n'
            # NOTE: sqlite3のデフォルト区切り文字は|のため、
            # タイトルに|が含まれるとIFSで誤分割される。
            # 現実的にtask titleに|が含まれる可能性は極めて低いため許容。
            while IFS='|' read -r tid ttitle tstatus; do
                local safe_title="${ttitle//|/-}"
                safe_title="${safe_title//$'\n'/ }"
                task_lines+="| ${tid} | ${safe_title} | ${tstatus} |"$'\n'
            done <<< "$raw"
        fi
    fi

    # フォールバック: SQLite利用不可の場合のみ、dashboard.mdから全タスクを抽出
    # NOTE: SQLite利用可能時はタスク0件でもfallbackしない（他リポのタスク混入防止）
    # NOTE: awkパスではリポジトリフィルタリング不可（名前形式の不一致: 短縮名 vs 完全名）
    if [[ -z "$task_lines" ]] && [[ "$sqlite_available" != true ]] && [[ -f "$dashboard" ]]; then
        task_lines=$(awk '
            /^## 現在のタスク/ { in_section=1; next }
            /^## /             { in_section=0 }
            in_section         { print }
        ' "$dashboard")
    fi

    # body 組み立て
    cat <<EOF
# IGNITE Daily Report

**Repository:** \`$repo\`
**Date:** $today
**Last Synced:** $timestamp

---

## Current Tasks

${task_lines:-_No tasks currently in progress._}

---
*Auto-synced from IGNITE Dashboard*
*Generated by [IGNITE](https://github.com/myfinder/ignite) AI Team*
EOF
}

_sync_dashboard_to_reports() {
    local dashboard="$WORKSPACE_DIR/dashboard.md"
    [[ -f "$dashboard" ]] || return 0

    local daily_report_script="${SCRIPT_DIR}/daily_report.sh"
    [[ -x "$daily_report_script" ]] || return 0

    local cache_dir
    cache_dir=$(_get_report_cache_dir)
    local cache_file="$cache_dir/report_issues.json"
    [[ -f "$cache_file" ]] || return 0

    local today
    today=$(date +%Y-%m-%d)
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')

    local repos
    repos=$(jq -r --arg date "$today" \
        'to_entries[] | select(.value[$date] != null) | .key' \
        "$cache_file" 2>/dev/null)
    [[ -n "$repos" ]] || return 0

    while IFS= read -r repo; do
        [[ -z "$repo" ]] && continue
        local report_issue
        report_issue=$(jq -r --arg repo "$repo" --arg date "$today" \
            '.[$repo][$date] // empty' "$cache_file" 2>/dev/null)
        [[ -n "$report_issue" ]] || continue

        local body
        body=$(_generate_repo_report "$repo" "$today" "$timestamp")
        [[ -n "$body" ]] || continue

        WORKSPACE_DIR="$WORKSPACE_DIR" "$daily_report_script" update \
            --repo "$repo" \
            --issue "$report_issue" \
            --body "$body" 2>/dev/null || true
    done <<< "$repos"

    log_info "日次レポートをダッシュボードから同期しました"
}

# =============================================================================
# メッセージ処理
# =============================================================================

process_message() {
    local file="$1"
    local queue_name="$2"

    # ファイル名から情報を取得
    local filename
    filename=$(basename "$file")

    # MIMEヘッダーからタイプを読み取り
    local msg_type
    msg_type=$(mime_get "$file" "type")

    log_info "新規メッセージ検知: $filename (type: $msg_type)"

    # メッセージタイプに応じた処理指示を生成
    local instruction=""
    case "$msg_type" in
        github_task)
            local trigger repo issue_num
            trigger=$(mime_body_get "$file" "trigger")
            repo=$(mime_get "$file" "repository")
            issue_num=$(mime_get "$file" "issue")
            instruction="新しいGitHubタスクが来ました。$file を読んで処理してください。リポジトリ: $repo, Issue/PR: #$issue_num, トリガー: $trigger"
            # 日次レポートに作業開始を記録（バックグラウンド）
            if [[ -n "$repo" ]]; then
                _trigger_daily_report "$repo" "$issue_num" "$trigger" &
            fi
            ;;
        github_event)
            local event_type
            event_type=$(mime_body_get "$file" "event_type")
            instruction="新しいGitHubイベントが来ました。$file を読んで必要に応じて対応してください。イベントタイプ: $event_type"
            ;;
        progress_update)
            instruction="進捗報告が来ました。$file を読んで確認してください。"
            # 日次レポートに進捗を記録（バックグラウンド）
            _report_progress "$file" &
            ;;
        evaluation_result)
            local eval_verdict
            eval_verdict=$(mime_body_get "$file" "verdict")
            instruction="評価結果が来ました。$file を読んで確認してください。判定: $eval_verdict"
            # 日次レポートに評価結果を記録（バックグラウンド）
            _report_evaluation "$file" &
            ;;
        task)
            instruction="新しいタスクが来ました。$file を読んで処理してください。"
            ;;
        *)
            instruction="新しいメッセージが来ました。$file を読んで処理してください。"
            ;;
    esac

    # シャットダウン要求時は新規送信を開始しない
    if [[ "$_SHUTDOWN_REQUESTED" == true ]]; then
        log_warn "シャットダウン要求中のため送信をスキップ: $file"
        return 0
    fi

    # エージェントに送信（開始後は完了まで中断しない）
    if send_to_agent "$queue_name" "$instruction"; then
        # 配信成功: status=delivered に更新
        mime_update_status "$file" "delivered"
    fi
    # 失敗時は status=processing のまま（リトライ対象）
}

# =============================================================================
# キュー監視
# =============================================================================

# ファイル名を {type}_{timestamp}.mime パターンに正規化
# 正規化が不要な場合はそのままのパスを返す
normalize_filename() {
    local file="$1"
    local filename
    filename=$(basename "$file")
    local dir
    dir=$(dirname "$file")

    # {任意の文字列}_{数字16桁}.mime パターンに一致すれば正規化不要
    if [[ "$filename" =~ ^.+_[0-9]{16}\.mime$ ]]; then
        echo "$file"
        return
    fi

    # MIMEヘッダーから type と timestamp を読み取り
    local msg_type
    msg_type=$(mime_get "$file" "type")
    if [[ -z "$msg_type" ]]; then
        # type フィールドがない場合はファイル名からベスト・エフォートで推測
        msg_type="${filename%.mime}"
    fi

    # Date ヘッダーからエポックマイクロ秒を算出（元の時系列順を保持）
    local yaml_ts
    yaml_ts=$(mime_get "$file" "date")
    local epoch_usec=""
    if [[ -n "$yaml_ts" ]]; then
        local epoch_sec
        epoch_sec=$(date -d "$yaml_ts" +%s 2>/dev/null)
        if [[ -n "$epoch_sec" ]]; then
            # マイクロ秒部分はファイルのハッシュから生成（ユニーク性確保）
            local micro
            micro=$(echo "${file}${yaml_ts}" | md5sum | tr -dc '0-9' | head -c 6)
            epoch_usec="${epoch_sec}${micro}"
        fi
    fi
    # フォールバック: 現在時刻ベース
    if [[ -z "$epoch_usec" ]]; then
        epoch_usec=$(date +%s%6N)
    fi

    # 衝突回避: 同名ファイルが存在する場合は連番サフィックス
    local new_path="${dir}/${msg_type}_${epoch_usec}.mime"
    if [[ -f "$new_path" ]]; then
        local suffix=1
        while [[ -f "${dir}/${msg_type}_${epoch_usec}_${suffix}.mime" ]]; do
            ((suffix++))
        done
        new_path="${dir}/${msg_type}_${epoch_usec}_${suffix}.mime"
    fi

    local from
    from=$(mime_get "$file" "from")
    local to
    to=$(mime_get "$file" 'to[0]')
    log_warn "ファイル名を正規化: ${filename} → $(basename "$new_path") (from: ${from:-unknown}, to: ${to:-unknown})"

    mv "$file" "$new_path" 2>/dev/null || { echo "$file"; return; }
    echo "$new_path"
}

# レガシー YAML → MIME 自動変換
# v0.4.0 移行期間中、エージェントが .yaml で生成したメッセージを
# MIME 形式に変換して queue_monitor で処理可能にする
_convert_yaml_to_mime() {
    local yaml_file="$1"
    local dir
    dir=$(dirname "$yaml_file")
    local basename_noext
    basename_noext=$(basename "$yaml_file" .yaml)

    # YAML トップレベルフィールドを抽出
    local msg_type from_agent to_agent priority repo issue
    msg_type=$(grep -m1 '^type:' "$yaml_file" 2>/dev/null | sed 's/^type:[[:space:]]*//' | tr -d '"' | tr -d "'")
    from_agent=$(grep -m1 '^from:' "$yaml_file" 2>/dev/null | sed 's/^from:[[:space:]]*//' | tr -d '"' | tr -d "'")
    to_agent=$(grep -m1 '^to:' "$yaml_file" 2>/dev/null | sed 's/^to:[[:space:]]*//' | tr -d '"' | tr -d "'")
    priority=$(grep -m1 '^priority:' "$yaml_file" 2>/dev/null | sed 's/^priority:[[:space:]]*//' | tr -d '"' | tr -d "'")
    repo=$(grep -m1 '^\s*repository:' "$yaml_file" 2>/dev/null | head -1 | sed 's/^.*repository:[[:space:]]*//' | tr -d '"' | tr -d "'")
    issue=$(grep -m1 '^\s*issue_number:' "$yaml_file" 2>/dev/null | head -1 | sed 's/^.*issue_number:[[:space:]]*//' | tr -d '"' | tr -d "'")

    # 最低限の情報がなければフォールバック
    [[ -z "$msg_type" ]] && msg_type="unknown"
    [[ -z "$from_agent" ]] && from_agent="unknown"
    [[ -z "$to_agent" ]] && to_agent="unknown"

    # ignite_mime.py build でMIMEメッセージを構築
    local mime_args=(--from "$from_agent" --to "$to_agent" --type "$msg_type")
    [[ -n "$priority" && "$priority" != "normal" ]] && mime_args+=(--priority "$priority")
    [[ -n "$repo" ]] && mime_args+=(--repo "$repo")
    [[ -n "$issue" ]] && mime_args+=(--issue "$issue")

    local mime_file="${dir}/${basename_noext}.mime"
    if python3 "$IGNITE_MIME" build "${mime_args[@]}" --body-file "$yaml_file" -o "$mime_file" 2>/dev/null; then
        log_success "YAML→MIME変換完了: $(basename "$yaml_file") → $(basename "$mime_file")"
        return 0
    else
        log_error "YAML→MIME変換失敗: $(basename "$yaml_file")"
        return 1
    fi
}

scan_queue() {
    local queue_dir="$1"
    local queue_name="$2"

    [[ -d "$queue_dir" ]] || return

    # processed/ ディレクトリを確保（処理済みファイルの移動先）
    mkdir -p "$queue_dir/processed"

    # レガシー .yaml ファイル検出 → MIME形式に自動変換
    for yaml_file in "$queue_dir"/*.yaml; do
        [[ -f "$yaml_file" ]] || continue
        log_warn "レガシーYAMLメッセージ検出: $(basename "$yaml_file") → MIME変換します"
        if _convert_yaml_to_mime "$yaml_file"; then
            rm -f "$yaml_file"
        fi
    done

    # キューディレクトリ直下の .mime ファイル = 未処理メッセージ
    for file in "$queue_dir"/*.mime; do
        [[ -f "$file" ]] || continue

        # ファイル名が {type}_{timestamp}.mime パターンに一致しない場合は正規化
        file=$(normalize_filename "$file")
        [[ -f "$file" ]] || continue

        local filename
        filename=$(basename "$file")
        local dest="$queue_dir/processed/$filename"

        # at-least-once 配信: 先に processed/ へ移動し、成功した場合のみ処理
        mv "$file" "$dest" 2>/dev/null || continue

        # status=processing + processed_at を追記（タイムアウト検知の基点）
        mime_update_status "$dest" "processing" "$(date -Iseconds)"

        # 処理（processed/ 内のパスを渡す）
        process_message "$dest" "$queue_name"
    done
}

# =============================================================================
# タイムアウト検査
# =============================================================================

scan_for_timeouts() {
    local queue_dir="$1"
    local queue_name="$2"

    local processed_dir="$queue_dir/processed"
    [[ -d "$processed_dir" ]] || return

    local timeout_sec
    timeout_sec=$(_resolve_task_timeout)
    local max_retries="${DLQ_MAX_RETRIES:-3}"

    # mtime が timeout_sec 秒以上前のファイルを候補取得
    while IFS= read -r -d '' file; do
        [[ -f "$file" ]] || continue

        # 前セッションのファイルはスキップ（再起動時のリトライ暴走防止）
        local file_mtime
        file_mtime=$(stat -c %Y "$file" 2>/dev/null) || file_mtime=$(stat -f %m "$file" 2>/dev/null) || true
        if [[ -n "$file_mtime" ]] && [[ -n "${_MONITOR_START_EPOCH:-}" ]] && [[ "$file_mtime" -lt "$_MONITOR_START_EPOCH" ]]; then
            continue
        fi

        # status フィールドを取得（MIMEヘッダーから）
        local status
        status=$(mime_get "$file" "status")

        # delivered/completed はスキップ
        case "$status" in
            delivered|completed) continue ;;
            retrying)
                # next_retry_after を確認（バックオフ待機中はスキップ）
                local next_retry
                next_retry=$(mime_body_get "$file" "next_retry_after")
                if [[ -n "$next_retry" ]]; then
                    local next_epoch now_epoch
                    next_epoch=$(date -d "$next_retry" +%s 2>/dev/null) || true
                    now_epoch=$(date +%s)
                    if [[ -n "$next_epoch" ]] && [[ "$now_epoch" -lt "$next_epoch" ]]; then
                        continue  # バックオフ待機中
                    fi
                fi
                ;;
            processing|"")
                # processing または statusなし → タイムアウト検査対象
                ;;
            *)
                continue  # 未知のステータスはスキップ
                ;;
        esac

        # retry_count を取得（MIMEボディから）
        local retry_count
        retry_count=$(mime_body_get "$file" "retry_count")
        retry_count="${retry_count:-0}"

        if [[ "$retry_count" -ge "$max_retries" ]]; then
            # DLQ 移動 + エスカレーション
            log_warn "リトライ上限到達: $(basename "$file") (${retry_count}/${max_retries})"
            move_to_dlq "$file" "$retry_count" "timeout after ${max_retries} retries" >/dev/null
            escalate_to_leader "$file" "$retry_count" "timeout after ${max_retries} retries" "manual_review" >/dev/null
        else
            # リトライ処理
            log_info "タイムアウトリトライ: $(basename "$file") (試行: $((retry_count + 1)))"
            process_retry "$file"
            # status を retrying に設定
            mime_update_status "$file" "retrying"

            # queue/ に戻す（再処理対象にする）
            local filename
            filename=$(basename "$file")
            mv "$file" "$queue_dir/$filename" 2>/dev/null || true
        fi
    done < <(find "$processed_dir" -name "*.mime" -not -newermt "${timeout_sec} seconds ago" -print0 2>/dev/null)
}

monitor_queues() {
    log_info "キュー監視を開始します（間隔: ${POLL_INTERVAL}秒）"

    # モニター起動時刻を記録（scan_for_timeouts で前セッションのファイルを除外するため）
    _MONITOR_START_EPOCH=$(date +%s)

    # DLQ ディレクトリ事前作成
    mkdir -p "$WORKSPACE_DIR/queue/dead_letter"

    local poll_count=0
    local SYNC_INTERVAL=30    # 30 × 10秒 = ~5分

    while [[ "$_SHUTDOWN_REQUESTED" != true ]]; do
        # tmuxセッション生存チェック
        if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
            log_warn "tmux セッション '$TMUX_SESSION' が消滅しました。監視を終了します"
            _SHUTDOWN_REQUESTED=true
            break
        fi

        # Leader キュー
        scan_queue "$WORKSPACE_DIR/queue/leader" "leader"

        # Sub-Leaders キュー
        scan_queue "$WORKSPACE_DIR/queue/strategist" "strategist"
        scan_queue "$WORKSPACE_DIR/queue/architect" "architect"
        scan_queue "$WORKSPACE_DIR/queue/evaluator" "evaluator"
        scan_queue "$WORKSPACE_DIR/queue/coordinator" "coordinator"
        scan_queue "$WORKSPACE_DIR/queue/innovator" "innovator"

        # IGNITIAN キュー（個別ディレクトリ方式 - Sub-Leadersと同じパターン）
        for ignitian_dir in "$WORKSPACE_DIR/queue"/ignitian[_-]*; do
            [[ -d "$ignitian_dir" ]] || continue
            local dirname
            dirname=$(basename "$ignitian_dir")
            scan_queue "$ignitian_dir" "$dirname"
        done

        # タイムアウト検査（全キューの processed/ を走査）
        scan_for_timeouts "$WORKSPACE_DIR/queue/leader" "leader"
        scan_for_timeouts "$WORKSPACE_DIR/queue/strategist" "strategist"
        scan_for_timeouts "$WORKSPACE_DIR/queue/architect" "architect"
        scan_for_timeouts "$WORKSPACE_DIR/queue/evaluator" "evaluator"
        scan_for_timeouts "$WORKSPACE_DIR/queue/coordinator" "coordinator"
        scan_for_timeouts "$WORKSPACE_DIR/queue/innovator" "innovator"
        for ignitian_dir in "$WORKSPACE_DIR/queue"/ignitian[_-]*; do
            [[ -d "$ignitian_dir" ]] || continue
            local dirname
            dirname=$(basename "$ignitian_dir")
            scan_for_timeouts "$ignitian_dir" "$dirname"
        done

        # 定期的にダッシュボードから日次レポートに同期（~5分ごと）
        poll_count=$((poll_count + 1))
        if [[ $((poll_count % SYNC_INTERVAL)) -eq 0 ]]; then
            _sync_dashboard_to_reports &
            _refresh_bot_token_cache &
        fi

        # SIGHUP による設定リロード（フラグベース遅延実行）
        if [[ "$_RELOAD_REQUESTED" == true ]]; then
            _RELOAD_REQUESTED=false
            log_info "設定リロード実行中..."
            load_config || log_warn "設定リロード失敗"
            log_info "設定リロード完了"
        fi

        # sleep分割: SIGTERM応答性改善（最大1秒以内に停止可能）
        local i=0
        while [[ $i -lt $POLL_INTERVAL ]] && [[ "$_SHUTDOWN_REQUESTED" != true ]]; do
            sleep 1
            i=$((i + 1))
        done
    done

    exit "${_EXIT_CODE:-0}"
}

# =============================================================================
# ヘルプ
# =============================================================================

show_help() {
    cat << 'EOF'
キュー監視スクリプト

使用方法:
  ./scripts/utils/queue_monitor.sh [オプション]

オプション:
  -s, --session <name>  tmux セッション名（必須）
  -i, --interval <sec>  ポーリング間隔（デフォルト: 10秒）
  -h, --help            このヘルプを表示

環境変数:
  IGNITE_TMUX_SESSION   tmux セッション名
  QUEUE_POLL_INTERVAL   ポーリング間隔（秒）
  WORKSPACE_DIR         ワークスペースディレクトリ

例:
  # tmux セッション指定で起動
  ./scripts/utils/queue_monitor.sh -s ignite-1234
EOF
}

# =============================================================================
# メイン
# =============================================================================

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -s|--session)
                TMUX_SESSION="$2"
                shift 2
                ;;
            -i|--interval)
                POLL_INTERVAL="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "不明なオプション: $1"
                show_help
                exit 1
                ;;
        esac
    done

    if [[ -z "$TMUX_SESSION" ]]; then
        log_error "tmux セッション名が指定されていません"
        echo "  -s または --session オプションで指定してください"
        echo "  または IGNITE_TMUX_SESSION 環境変数を設定してください"
        exit 1
    fi

    # tmux セッションの存在確認
    if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        log_error "tmux セッションが見つかりません: $TMUX_SESSION"
        exit 1
    fi

    # SIGHUP ハンドラ（フラグベース遅延リロード）
    # trap内で直接load_config()を呼ぶと、scan_queue()実行中に
    # 設定変更の競合が発生するリスクがあるため、
    # フラグを立てるだけにしてメインループ内で安全にリロードする
    _handle_sighup() {
        log_info "SIGHUP受信: リロード予約"
        _RELOAD_REQUESTED=true
    }

    # グレースフル停止: フラグベース（trap内でexit()を呼ばない）
    # scan_queue()/send_to_agent()完了を待ってから安全に停止する
    graceful_shutdown() {
        _SHUTDOWN_SIGNAL="$1"
        _SHUTDOWN_REQUESTED=true
        _EXIT_CODE=$((128 + $1))
        log_info "シグナル受信 (${1}): 安全に停止します"
    }
    trap 'graceful_shutdown 15' SIGTERM
    trap 'graceful_shutdown 2' SIGINT
    trap '_handle_sighup' SIGHUP

    # EXIT trap: 終了理由をログに記録 + orphanプロセス防止
    cleanup_and_log() {
        local exit_code=$?
        [[ $exit_code -eq 0 ]] && exit_code=${_EXIT_CODE:-0}
        # バックグラウンドプロセスのクリーンアップ
        kill "$(jobs -p)" 2>/dev/null
        wait 2>/dev/null
        if [[ -n "$_SHUTDOWN_SIGNAL" ]]; then
            log_info "キュー監視 終了: シグナル${_SHUTDOWN_SIGNAL}による停止"
        elif [[ $exit_code -eq 0 ]]; then
            log_info "キュー監視 終了: 正常終了"
        elif [[ $exit_code -gt 128 ]]; then
            local sig=$((exit_code - 128))
            log_warn "キュー監視 終了: 未捕捉シグナル$(kill -l "$sig" 2>/dev/null || echo UNKNOWN)"
        else
            log_error "キュー監視 終了: 異常終了 (exit_code=$exit_code)"
        fi
    }
    trap cleanup_and_log EXIT

    log_info "tmux セッション: $TMUX_SESSION"

    monitor_queues
}

main "$@"

#!/bin/bash
# =============================================================================
# DLQ (Dead Letter Queue) ハンドラー
# リトライ上限に到達したタスクの処理とエスカレーション機構
# =============================================================================

# 二重読み込み防止ガード
if [[ -n "${__DLQ_HANDLER_LOADED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
__DLQ_HANDLER_LOADED=1

# =============================================================================
# 設定
# =============================================================================

DLQ_MAX_RETRIES="${DLQ_MAX_RETRIES:-3}"

# カラー定義（sourced 元で未定義の場合のフォールバック）
_DLQ_GREEN="${GREEN:-\033[0;32m}"
_DLQ_YELLOW="${YELLOW:-\033[1;33m}"
_DLQ_RED="${RED:-\033[0;31m}"
_DLQ_BLUE="${BLUE:-\033[0;34m}"
_DLQ_NC="${NC:-\033[0m}"

# ログ関数（sourced 元で未定義の場合のフォールバック）
if ! declare -f log_info &>/dev/null; then
    log_info()    { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${_DLQ_BLUE}[DLQ]${_DLQ_NC} $1" >&2; }
    log_success() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${_DLQ_GREEN}[DLQ]${_DLQ_NC} $1" >&2; }
    log_warn()    { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${_DLQ_YELLOW}[DLQ]${_DLQ_NC} $1" >&2; }
    log_error()   { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${_DLQ_RED}[DLQ]${_DLQ_NC} $1" >&2; }
fi

# =============================================================================
# 関数名: move_to_dlq
# 目的: リトライ上限に到達したタスクを dead_letter ディレクトリに移動する
# 引数:
#   $1 - タスクファイルのパス
#   $2 - リトライ回数
#   $3 - エラー理由（オプション、デフォルト: "unknown"）
# 戻り値: 0=成功, 1=失敗
# 出力: DLQファイルのパス（標準出力）
# =============================================================================
move_to_dlq() {
    local task_file="$1"
    local retry_count="$2"
    local error_reason="${3:-unknown}"

    if [[ ! -f "$task_file" ]]; then
        log_error "[DLQ] タスクファイルが見つかりません: ${task_file}"
        return 1
    fi

    local workspace_dir="${WORKSPACE_DIR:-workspace}"
    local dlq_dir="${workspace_dir}/queue/dead_letter"

    local filename
    filename=$(basename "$task_file")

    local timestamp
    timestamp=$(date -Iseconds)

    local dlq_file
    dlq_file="${dlq_dir}/${filename%.yaml}_dlq_$(date +%s).yaml"

    # dead_letter ディレクトリ作成
    mkdir -p "$dlq_dir"

    # 元のメッセージ内容を読み取り（インデント付きで保持）
    local original_content
    original_content=$(sed 's/^/    /' < "$task_file")

    # DLQ エントリ作成（失敗履歴 + 元メッセージ保持）
    cat > "$dlq_file" <<EOF
type: dead_letter
timestamp: "${timestamp}"
original_file: "${filename}"
failure_info:
  retry_count: ${retry_count}
  max_retries: ${DLQ_MAX_RETRIES}
  last_error: "${error_reason}"
  moved_at: "${timestamp}"
original_message: |
${original_content}
EOF

    # 元ファイル削除
    rm -f "$task_file"

    log_info "[DLQ] ${filename} を dead_letter に移動しました (retry: ${retry_count}/${DLQ_MAX_RETRIES})"

    echo "$dlq_file"
}

# =============================================================================
# 関数名: should_escalate
# 目的: タスクをLeaderにエスカレーションすべきか判断する
# 引数:
#   $1 - タスクファイルのパス
#   $2 - リトライ回数
# 戻り値: 0=エスカレーションすべき, 1=不要
# =============================================================================
should_escalate() {
    local task_file="$1"
    local retry_count="$2"

    # 条件1: リトライ上限に到達
    if [[ "$retry_count" -ge "$DLQ_MAX_RETRIES" ]]; then
        return 0
    fi

    # 条件2: critical priority のタスク失敗
    if [[ -f "$task_file" ]]; then
        local priority
        priority=$(grep -E '^priority:' "$task_file" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')
        if [[ "$priority" == "critical" ]]; then
            return 0
        fi
    fi

    return 1
}

# =============================================================================
# 関数名: escalate_to_leader
# 目的: Leaderへのエスカレーション通知を直接YAML書き込みで作成する
# 引数:
#   $1 - タスクファイルのパス
#   $2 - リトライ回数
#   $3 - エラー理由（オプション、デフォルト: "unknown"）
#   $4 - 推奨アクション（オプション、デフォルト: "manual_review"）
# 戻り値: 0=成功, 1=失敗
# 出力: エスカレーションファイルのパス（標準出力）
# =============================================================================
escalate_to_leader() {
    local task_file="$1"
    local retry_count="$2"
    local error_reason="${3:-unknown}"
    local recommended_action="${4:-manual_review}"

    local workspace_dir="${WORKSPACE_DIR:-workspace}"
    local leader_queue_dir="${workspace_dir}/queue/leader"

    local timestamp
    timestamp=$(date -Iseconds)

    # タスク情報の抽出
    local task_id="unknown"
    local title="unknown"
    local original_assignee="unknown"

    if [[ -f "$task_file" ]]; then
        local extracted

        extracted=$(grep -E '^\s*task_id:' "$task_file" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')
        [[ -n "$extracted" ]] && task_id="$extracted"

        extracted=$(grep -E '^\s*title:' "$task_file" 2>/dev/null | head -1 | sed 's/.*title:[[:space:]]*//' | tr -d '"')
        [[ -n "$extracted" ]] && title="$extracted"

        extracted=$(grep -E '^to:' "$task_file" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')
        [[ -n "$extracted" ]] && original_assignee="$extracted"
    fi

    # Leader キューディレクトリ作成
    mkdir -p "$leader_queue_dir"

    local escalation_file
    escalation_file="${leader_queue_dir}/escalation_$(date +%s).yaml"

    # エスカレーション通知YAML作成
    cat > "$escalation_file" <<EOF
type: escalation
from: queue_monitor
to: leader
timestamp: "${timestamp}"
priority: critical
payload:
  task_id: "${task_id}"
  title: "${title}"
  original_assignee: "${original_assignee}"
  failure_reason: "${error_reason}"
  retry_count: ${retry_count}
  max_retries: ${DLQ_MAX_RETRIES}
  recommended_action: "${recommended_action}"
  dlq_path: "${workspace_dir}/queue/dead_letter/"
  notes: "リトライ上限に到達したためエスカレーションします"
status: queued
EOF

    log_warn "[DLQ] Leaderへエスカレーション通知を送信しました: ${escalation_file}"

    echo "$escalation_file"
}

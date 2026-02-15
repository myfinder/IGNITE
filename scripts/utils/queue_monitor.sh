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
source "${SCRIPT_DIR}/../lib/core.sh"
source "${SCRIPT_DIR}/../lib/cli_provider.sh"
source "${SCRIPT_DIR}/../lib/health_check.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${WORKSPACE_DIR:-}" ]] && setup_workspace_config "$WORKSPACE_DIR"

# グレースフル停止用フラグ（trap内ではフラグを立てるだけ、exit()を呼ばない）
_SHUTDOWN_REQUESTED=false
_SHUTDOWN_SIGNAL=""
_EXIT_CODE=0

# SIGHUP設定リロード用フラグ（trap内では直接設定変更を行わない）
_RELOAD_REQUESTED=false

# リトライ/DLQ ハンドラーの読み込み（SCRIPT_DIR/WORKSPACE_DIR保護）
_QM_SCRIPT_DIR="$SCRIPT_DIR"
_QM_WORKSPACE_DIR="${WORKSPACE_DIR:-}"
_QM_RUNTIME_DIR="${IGNITE_RUNTIME_DIR:-}"
source "${SCRIPT_DIR}/../lib/retry_handler.sh"
source "${SCRIPT_DIR}/../lib/dlq_handler.sh"
SCRIPT_DIR="$_QM_SCRIPT_DIR"
WORKSPACE_DIR="${_QM_WORKSPACE_DIR}"
IGNITE_RUNTIME_DIR="${_QM_RUNTIME_DIR}"

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
    local config_dir="$IGNITE_CONFIG_DIR"
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
IGNITE_RUNTIME_DIR="${IGNITE_RUNTIME_DIR:-$WORKSPACE_DIR}"
POLL_INTERVAL="${QUEUE_POLL_INTERVAL:-10}"
TMUX_SESSION="${IGNITE_TMUX_SESSION:-}"

# 再開フロー/誤検知対策
HEARTBEAT_INTERVAL="${QUEUE_HEARTBEAT_INTERVAL:-10}"
PROGRESS_LOG_INTERVAL="${QUEUE_PROGRESS_INTERVAL:-30}"
MISSING_SESSION_GRACE="${QUEUE_MISSING_SESSION_GRACE:-60}"
MISSING_SESSION_THRESHOLD="${QUEUE_MISSING_SESSION_THRESHOLD:-3}"
MONITOR_LOCK_FILE="${IGNITE_RUNTIME_DIR}/state/queue_monitor.lock"
MONITOR_STATE_FILE="${IGNITE_RUNTIME_DIR}/state/queue_monitor_state.json"
MONITOR_HEARTBEAT_FILE="${IGNITE_RUNTIME_DIR}/state/queue_monitor_heartbeat.json"
MONITOR_PROGRESS_FILE="${IGNITE_RUNTIME_DIR}/state/queue_monitor_progress.log"

# CLI プロバイダー設定を読み込み（submit keys 判定に必要）
cli_load_config 2>/dev/null || true

# tmux window名を system.yaml から取得
TMUX_WINDOW_NAME=$(sed -n '/^tmux:/,/^[^ ]/p' "$IGNITE_CONFIG_DIR/system.yaml" 2>/dev/null \
    | awk -F': ' '/^  window_name:/{print $2; exit}' | tr -d '"' | tr -d "'")
TMUX_WINDOW_NAME="${TMUX_WINDOW_NAME:-ignite}"

# task_timeout を system.yaml から動的取得（デフォルト: 300秒）
_TASK_TIMEOUT=""
_resolve_task_timeout() {
    if [[ -n "$_TASK_TIMEOUT" ]]; then
        echo "$_TASK_TIMEOUT"
        return
    fi
    local config_dir="$IGNITE_CONFIG_DIR"
    local sys_yaml="${config_dir}/system.yaml"
    if declare -f yaml_get &>/dev/null && [[ -f "$sys_yaml" ]]; then
        _TASK_TIMEOUT=$(yaml_get "$sys_yaml" "task_timeout" "300")
    else
        _TASK_TIMEOUT="${RETRY_TIMEOUT:-300}"
    fi
    echo "$_TASK_TIMEOUT"
}

# task_health.json の永続化
_write_task_health_snapshot() {
    local state_dir="$IGNITE_RUNTIME_DIR/state"
    local output_file="$state_dir/task_health.json"
    mkdir -p "$state_dir"

    local timestamp
    timestamp=$(date -Iseconds)

    local agents_json="[]"
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        agents_json=$(get_agents_health_json "$TMUX_SESSION:$TMUX_WINDOW_NAME" 2>/dev/null || echo "[]")
    fi

    local queue_lines=""
    for queue_dir in "$IGNITE_RUNTIME_DIR/queue"/*; do
        [[ -d "$queue_dir" ]] || continue
        local queue_name
        queue_name=$(basename "$queue_dir")
        [[ "$queue_name" == "dead_letter" ]] && continue

        local pending_count
        pending_count=$(find "$queue_dir" -maxdepth 1 -name "*.mime" -type f 2>/dev/null | wc -l)

        local processed_dir="$queue_dir/processed"
        local processing_count=0
        local retrying_count=0
        local delivered_count=0
        if [[ -d "$processed_dir" ]]; then
            for file in "$processed_dir"/*.mime; do
                [[ -f "$file" ]] || continue
                local status
                status=$(mime_get "$file" "status")
                case "$status" in
                    processing|"")
                        processing_count=$((processing_count + 1))
                        ;;
                    retrying)
                        retrying_count=$((retrying_count + 1))
                        ;;
                    delivered|completed)
                        delivered_count=$((delivered_count + 1))
                        ;;
                esac
            done
        fi

        queue_lines+="${queue_name}|${pending_count}|${processing_count}|${retrying_count}|${delivered_count}"
        queue_lines+=$'\n'
    done

    TASK_HEALTH_TIMESTAMP="$timestamp" \
    TASK_HEALTH_SESSION="$TMUX_SESSION" \
    TASK_HEALTH_WORKSPACE="$WORKSPACE_DIR" \
    TASK_HEALTH_AGENTS_JSON="$agents_json" \
    TASK_HEALTH_QUEUE_LINES="$queue_lines" \
    python3 - <<'PY' > "$output_file"
import json
import os

timestamp = os.environ.get("TASK_HEALTH_TIMESTAMP", "")
session = os.environ.get("TASK_HEALTH_SESSION", "")
workspace = os.environ.get("TASK_HEALTH_WORKSPACE", "")
agents_json = os.environ.get("TASK_HEALTH_AGENTS_JSON", "[]")
queue_lines = os.environ.get("TASK_HEALTH_QUEUE_LINES", "")

try:
    agents = json.loads(agents_json)
except json.JSONDecodeError:
    agents = []

queues = []
for raw in queue_lines.splitlines():
    line = raw.strip()
    if not line:
        continue
    parts = line.split("|", 4)
    if len(parts) != 5:
        continue
    name, pending, processing, retrying, delivered = parts
    queues.append({
        "name": name,
        "pending": int(pending),
        "processing": int(processing),
        "retrying": int(retrying),
        "delivered": int(delivered),
    })

payload = {
    "generated_at": timestamp,
    "session": session,
    "workspace_dir": workspace,
    "agents": agents,
    "queues": queues,
}
print(json.dumps(payload, ensure_ascii=False))
PY
}


# =============================================================================
# 再開フロー基盤（resume_token/ロック/バックオフ）
# =============================================================================

_ensure_state_dir() {
    mkdir -p "${IGNITE_RUNTIME_DIR}/state"
}

_load_monitor_state() {
    _ensure_state_dir
    if [[ ! -f "$MONITOR_STATE_FILE" ]]; then
        return 0
    fi

    local state_json
    state_json=$(cat "$MONITOR_STATE_FILE" 2>/dev/null || true)
    if [[ -z "$state_json" ]]; then
        return 0
    fi

    MONITOR_RESUME_TOKEN=$(STATE_JSON="$state_json" python3 - <<'PY'
import json,os
state=os.environ.get("STATE_JSON","{}")
data=json.loads(state)
print(data.get("resume_token",""))
PY
)
    MONITOR_FAILURE_COUNT=$(STATE_JSON="$state_json" python3 - <<'PY'
import json,os
state=os.environ.get("STATE_JSON","{}")
data=json.loads(state)
print(data.get("failure_count",0))
PY
)
    MONITOR_LAST_EXIT=$(STATE_JSON="$state_json" python3 - <<'PY'
import json,os
state=os.environ.get("STATE_JSON","{}")
data=json.loads(state)
print(data.get("last_exit_code",0))
PY
)
    MONITOR_LAST_FAILURE_AT=$(STATE_JSON="$state_json" python3 - <<'PY'
import json,os
state=os.environ.get("STATE_JSON","{}")
data=json.loads(state)
print(data.get("last_failure_at",""))
PY
)
}

_save_monitor_state() {
    _ensure_state_dir
    local timestamp
    timestamp=$(date -Iseconds)
    MONITOR_STATE_TIMESTAMP="$timestamp" \
    MONITOR_STATE_TOKEN="${MONITOR_RESUME_TOKEN:-}" \
    MONITOR_STATE_FAILURE_COUNT="${MONITOR_FAILURE_COUNT:-0}" \
    MONITOR_STATE_LAST_EXIT="${MONITOR_LAST_EXIT:-0}" \
    MONITOR_STATE_LAST_FAILURE_AT="${MONITOR_LAST_FAILURE_AT:-}" \
    python3 - <<'PY' > "$MONITOR_STATE_FILE"
import json,os
data={
  "resume_token": os.environ.get("MONITOR_STATE_TOKEN",""),
  "failure_count": int(os.environ.get("MONITOR_STATE_FAILURE_COUNT","0")),
  "last_exit_code": int(os.environ.get("MONITOR_STATE_LAST_EXIT","0")),
  "last_failure_at": os.environ.get("MONITOR_STATE_LAST_FAILURE_AT", ""),
  "updated_at": os.environ.get("MONITOR_STATE_TIMESTAMP", "")
}
print(json.dumps(data, ensure_ascii=False))
PY
}

_init_resume_token() {
    if [[ -z "${MONITOR_RESUME_TOKEN:-}" ]]; then
        MONITOR_RESUME_TOKEN="$(date +%s%6N)-$RANDOM"
    fi
}

_apply_resume_backoff() {
    if [[ "${MONITOR_LAST_EXIT:-0}" -ne 0 ]]; then
        MONITOR_FAILURE_COUNT=$((MONITOR_FAILURE_COUNT + 1))
        MONITOR_LAST_FAILURE_AT="$(date -Iseconds)"
        local backoff
        backoff=$(calculate_backoff "$MONITOR_FAILURE_COUNT")
        log_warn "再開バックオフ: ${backoff}秒（失敗回数: ${MONITOR_FAILURE_COUNT}）"
        sleep "$backoff"
    else
        MONITOR_FAILURE_COUNT=0
    fi
    _save_monitor_state
}

_write_heartbeat() {
    _ensure_state_dir
    local timestamp
    timestamp=$(date -Iseconds)
    MONITOR_HEARTBEAT_TIMESTAMP="$timestamp" \
    MONITOR_HEARTBEAT_TOKEN="${MONITOR_RESUME_TOKEN:-}" \
    MONITOR_HEARTBEAT_SESSION="$TMUX_SESSION" \
    python3 - <<'PY' > "$MONITOR_HEARTBEAT_FILE"
import json,os
data={
  "timestamp": os.environ.get("MONITOR_HEARTBEAT_TIMESTAMP",""),
  "resume_token": os.environ.get("MONITOR_HEARTBEAT_TOKEN",""),
  "tmux_session": os.environ.get("MONITOR_HEARTBEAT_SESSION","")
}
print(json.dumps(data, ensure_ascii=False))
PY
}

_log_progress() {
    _ensure_state_dir
    local timestamp
    timestamp=$(date -Iseconds)

    local pending_total=0
    local processing_total=0
    local retrying_total=0
    local delivered_total=0

    for queue_dir in "$IGNITE_RUNTIME_DIR/queue"/*; do
        [[ -d "$queue_dir" ]] || continue
        local queue_name
        queue_name=$(basename "$queue_dir")
        [[ "$queue_name" == "dead_letter" ]] && continue

        local pending
        pending=$(find "$queue_dir" -maxdepth 1 -name "*.mime" -type f 2>/dev/null | wc -l)

        local processed_dir="$queue_dir/processed"
        local processing=0
        local retrying=0
        local delivered=0
        if [[ -d "$processed_dir" ]]; then
            for file in "$processed_dir"/*.mime; do
                [[ -f "$file" ]] || continue
                local status
                status=$(mime_get "$file" "status")
                case "$status" in
                    processing|"") processing=$((processing + 1)) ;;
                    retrying) retrying=$((retrying + 1)) ;;
                    delivered|completed) delivered=$((delivered + 1)) ;;
                esac
            done
        fi

        pending_total=$((pending_total + pending))
        processing_total=$((processing_total + processing))
        retrying_total=$((retrying_total + retrying))
        delivered_total=$((delivered_total + delivered))
    done

    printf '%s resume=%s pending=%s processing=%s retrying=%s delivered=%s\n' \
        "$timestamp" "${MONITOR_RESUME_TOKEN:-}" \
        "$pending_total" "$processing_total" "$retrying_total" "$delivered_total" \
        >> "$MONITOR_PROGRESS_FILE"
}

_on_monitor_exit() {
    local exit_code=$?
    MONITOR_LAST_EXIT=$exit_code
    if [[ $exit_code -ne 0 ]]; then
        MONITOR_LAST_FAILURE_AT="$(date -Iseconds)"
    fi
    _save_monitor_state
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

        # メッセージを送信してから確定キーを送信
        # -l (literal mode) でシェルメタキャラクタのエスケープを防止
        if tmux send-keys -l -t "$target" "$message" 2>/dev/null; then
            sleep 0.3
            local _submit_keys
            _submit_keys=$(cli_get_submit_keys 2>/dev/null || echo "C-m")
            eval "tmux send-keys -t '$target' $_submit_keys" 2>/dev/null
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
    if [[ -n "${IGNITE_RUNTIME_DIR:-}" ]]; then
        echo "$IGNITE_RUNTIME_DIR/state"
    else
        log_error "IGNITE_RUNTIME_DIR が未設定です。レポートキャッシュディレクトリを決定できません。"
        return 1
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
    report_issue=$(WORKSPACE_DIR="$WORKSPACE_DIR" IGNITE_RUNTIME_DIR="$IGNITE_RUNTIME_DIR" "$daily_report_script" ensure --repo "$repo" 2>/dev/null) || {
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

    WORKSPACE_DIR="$WORKSPACE_DIR" IGNITE_RUNTIME_DIR="$IGNITE_RUNTIME_DIR" "$daily_report_script" comment \
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

        WORKSPACE_DIR="$WORKSPACE_DIR" IGNITE_RUNTIME_DIR="$IGNITE_RUNTIME_DIR" "$daily_report_script" comment \
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

        WORKSPACE_DIR="$WORKSPACE_DIR" IGNITE_RUNTIME_DIR="$IGNITE_RUNTIME_DIR" "$daily_report_script" comment \
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
    local db="$IGNITE_RUNTIME_DIR/state/memory.db"
    local dashboard="$IGNITE_RUNTIME_DIR/dashboard.md"

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
    local dashboard="$IGNITE_RUNTIME_DIR/dashboard.md"
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

        WORKSPACE_DIR="$WORKSPACE_DIR" IGNITE_RUNTIME_DIR="$IGNITE_RUNTIME_DIR" "$daily_report_script" update \
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
    # セキュリティ: 抽出値（trigger, event_type等）を指示文に埋め込まない（参照型パターン）
    # エージェントはMIMEファイルを読んで詳細を取得する
    local instruction="新しいメッセージが来ました。$file を読んで処理してください。"
    case "$msg_type" in
        github_task)
            local repo issue_num
            repo=$(mime_get "$file" "repository")
            issue_num=$(mime_get "$file" "issue")
            # 日次レポートに作業開始を記録（バックグラウンド）
            if [[ -n "$repo" ]]; then
                local trigger
                trigger=$(mime_body_get "$file" "trigger")
                _trigger_daily_report "$repo" "$issue_num" "$trigger" &
            fi
            ;;
        progress_update)
            # 日次レポートに進捗を記録（バックグラウンド）
            _report_progress "$file" &
            ;;
        evaluation_result)
            # 日次レポートに評価結果を記録（バックグラウンド）
            _report_evaluation "$file" &
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
# v0.4.1 移行期間中、エージェントが .yaml で生成したメッセージを
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
    mkdir -p "$IGNITE_RUNTIME_DIR/queue/dead_letter"

    local poll_count=0
    local SYNC_INTERVAL=30    # 30 × 10秒 = ~5分
    local missing_session_count=0
    local missing_session_first_at=0
    local last_heartbeat_epoch=0
    local last_progress_epoch=0

    while [[ "$_SHUTDOWN_REQUESTED" != true ]]; do
        # tmuxセッション生存チェック（誤検知対策）
        if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
            local now_epoch
            now_epoch=$(date +%s)
            if [[ $missing_session_count -eq 0 ]]; then
                missing_session_first_at=$now_epoch
            fi
            missing_session_count=$((missing_session_count + 1))
            local elapsed=$((now_epoch - missing_session_first_at))
            log_warn "tmux セッション未検出: ${missing_session_count}/${MISSING_SESSION_THRESHOLD} (経過 ${elapsed}s)"
            if [[ $elapsed -ge $MISSING_SESSION_GRACE ]] && [[ $missing_session_count -ge $MISSING_SESSION_THRESHOLD ]]; then
                log_error "tmux セッション未検出が継続（猶予 ${MISSING_SESSION_GRACE}s 超過）"
                _EXIT_CODE=1
                _SHUTDOWN_REQUESTED=true
                break
            fi
            sleep 1
            continue
        fi
        missing_session_count=0
        missing_session_first_at=0

        # Leader キュー
        scan_queue "$IGNITE_RUNTIME_DIR/queue/leader" "leader"

        # Sub-Leaders キュー
        scan_queue "$IGNITE_RUNTIME_DIR/queue/strategist" "strategist"
        scan_queue "$IGNITE_RUNTIME_DIR/queue/architect" "architect"
        scan_queue "$IGNITE_RUNTIME_DIR/queue/evaluator" "evaluator"
        scan_queue "$IGNITE_RUNTIME_DIR/queue/coordinator" "coordinator"
        scan_queue "$IGNITE_RUNTIME_DIR/queue/innovator" "innovator"

        # IGNITIAN キュー（個別ディレクトリ方式 - Sub-Leadersと同じパターン）
        for ignitian_dir in "$IGNITE_RUNTIME_DIR/queue"/ignitian[_-]*; do
            [[ -d "$ignitian_dir" ]] || continue
            local dirname
            dirname=$(basename "$ignitian_dir")
            scan_queue "$ignitian_dir" "$dirname"
        done

        # タイムアウト検査（全キューの processed/ を走査）
        scan_for_timeouts "$IGNITE_RUNTIME_DIR/queue/leader" "leader"
        scan_for_timeouts "$IGNITE_RUNTIME_DIR/queue/strategist" "strategist"
        scan_for_timeouts "$IGNITE_RUNTIME_DIR/queue/architect" "architect"
        scan_for_timeouts "$IGNITE_RUNTIME_DIR/queue/evaluator" "evaluator"
        scan_for_timeouts "$IGNITE_RUNTIME_DIR/queue/coordinator" "coordinator"
        scan_for_timeouts "$IGNITE_RUNTIME_DIR/queue/innovator" "innovator"
        for ignitian_dir in "$IGNITE_RUNTIME_DIR/queue"/ignitian[_-]*; do
            [[ -d "$ignitian_dir" ]] || continue
            local dirname
            dirname=$(basename "$ignitian_dir")
            scan_for_timeouts "$ignitian_dir" "$dirname"
        done

        _write_task_health_snapshot || true

        # heartbeat / progress
        local now_epoch
        now_epoch=$(date +%s)
        if [[ $((now_epoch - last_heartbeat_epoch)) -ge $HEARTBEAT_INTERVAL ]]; then
            _write_heartbeat || true
            last_heartbeat_epoch=$now_epoch
        fi
        if [[ $((now_epoch - last_progress_epoch)) -ge $PROGRESS_LOG_INTERVAL ]]; then
            _log_progress || true
            last_progress_epoch=$now_epoch
        fi

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

    # 二重起動防止ロック
    _ensure_state_dir
    exec 9>"$MONITOR_LOCK_FILE"
    if ! flock -n 9; then
        log_error "queue_monitor は既に起動しています: $MONITOR_LOCK_FILE"
        exit 1
    fi

    # 再開フロー初期化
    _load_monitor_state
    _init_resume_token
    _apply_resume_backoff
    _write_heartbeat

    # 終了時の状態保存
    trap _on_monitor_exit EXIT

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

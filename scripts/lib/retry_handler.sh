#!/bin/bash
# =============================================================================
# retry_handler.sh - リトライ機構のコア関数
# =============================================================================
# キューのタスクに対するタイムアウト検知・リトライ処理を提供する。
#
# 提供関数:
#   check_timeout    - processingタイムアウト検知
#   mark_as_error    - エラーステータスへの変更
#   process_retry    - リトライ処理（ステータスをqueuedに戻す）
#   calculate_backoff - Exponential Backoff with Full Jitter 計算
#
# 使用方法:
#   source scripts/lib/retry_handler.sh
# =============================================================================

# 二重読み込み防止ガード
if [[ -n "${__RETRY_HANDLER_LOADED:-}" ]]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || exit 0
fi
__RETRY_HANDLER_LOADED=1

# =============================================================================
# 設定（環境変数で上書き可能）
# =============================================================================

RETRY_TIMEOUT="${RETRY_TIMEOUT:-300}"           # processingタイムアウト（秒）
RETRY_BASE_DELAY="${RETRY_BASE_DELAY:-5}"       # バックオフの基本遅延（秒）
RETRY_MAX_DELAY="${RETRY_MAX_DELAY:-300}"        # バックオフの最大遅延（秒）

# カラー定義
_RH_GREEN='\033[0;32m'
_RH_BLUE='\033[0;34m'
_RH_YELLOW='\033[1;33m'
_RH_RED='\033[0;31m'
_RH_NC='\033[0m'

# ログ出力（すべて標準エラー出力に出力して、コマンド置換で混入しないようにする）
_rh_log_info()    { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${_RH_BLUE}[RETRY]${_RH_NC} $1" >&2; }
_rh_log_success() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${_RH_GREEN}[RETRY]${_RH_NC} $1" >&2; }
_rh_log_warn()    { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${_RH_YELLOW}[RETRY]${_RH_NC} $1" >&2; }
_rh_log_error()   { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${_RH_RED}[RETRY]${_RH_NC} $1" >&2; }

# =============================================================================
# 関数名: check_timeout
# 目的: processingステータスのタスクがタイムアウトしていないか検知する
# 引数:
#   $1 - タスクファイルのパス
# 戻り値: 0=タイムアウト, 1=タイムアウトしていない
# =============================================================================
check_timeout() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        _rh_log_error "ファイルが見つかりません: $file"
        return 1
    fi

    # ステータス確認（processingでなければ対象外）
    local status
    status=$(grep -E '^status:' "$file" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')
    if [[ "$status" != "processing" ]]; then
        return 1
    fi

    # タイムスタンプ取得
    local timestamp
    timestamp=$(grep -E '^\s*timestamp:' "$file" 2>/dev/null | head -1 | sed 's/.*timestamp:[[:space:]]*//' | tr -d '"' | tr -d ' ')
    if [[ -z "$timestamp" ]]; then
        _rh_log_warn "タイムスタンプが見つかりません: $file"
        return 1
    fi

    # タイムスタンプをエポック秒に変換
    local file_epoch
    file_epoch=$(date -d "$timestamp" +%s 2>/dev/null) || true
    if [[ -z "$file_epoch" ]]; then
        _rh_log_warn "タイムスタンプの変換に失敗: $timestamp"
        return 1
    fi

    local now_epoch
    now_epoch=$(date +%s)
    local elapsed=$((now_epoch - file_epoch))

    if [[ $elapsed -ge $RETRY_TIMEOUT ]]; then
        _rh_log_warn "タイムアウト検知: $file (経過: ${elapsed}秒, 閾値: ${RETRY_TIMEOUT}秒)"
        return 0
    fi

    return 1
}

# =============================================================================
# 関数名: mark_as_error
# 目的: タスクのステータスをerrorに変更し、エラー理由をYAMLに記録する
# 引数:
#   $1 - タスクファイルのパス
#   $2 - エラー理由（省略時: "unknown error"）
# 戻り値: 0=成功, 1=失敗
# =============================================================================
mark_as_error() {
    local file="$1"
    local reason="${2:-unknown error}"

    if [[ ! -f "$file" ]]; then
        _rh_log_error "ファイルが見つかりません: $file"
        return 1
    fi

    # ステータスをerrorに変更
    if ! sed -i 's/^status:.*/status: error/' "$file" 2>/dev/null; then
        _rh_log_error "ステータスの更新に失敗: $file"
        return 1
    fi

    # エラー理由を記録（既存行を削除してから追記で安全にする）
    sed -i '/^error_reason:/d' "$file" 2>/dev/null
    printf 'error_reason: "%s"\n' "$reason" >> "$file"

    # エラー発生時刻を記録
    local error_time
    error_time=$(date -Iseconds)
    sed -i '/^error_at:/d' "$file" 2>/dev/null
    printf 'error_at: "%s"\n' "$error_time" >> "$file"

    _rh_log_error "エラーステータスに変更: $file (理由: ${reason})"
    return 0
}

# =============================================================================
# 関数名: calculate_backoff
# 目的: Exponential Backoff with Full Jitter によるバックオフ時間を計算する
# 引数:
#   $1 - リトライ回数（0始まり）
# 出力: 計算されたバックオフ時間（秒）を標準出力に出力
# 参考: AWS Architecture Blog - Exponential Backoff And Jitter
#        Full Jitter: sleep = random(0, min(cap, base * 2^attempt))
# =============================================================================
calculate_backoff() {
    local retry_count="${1:-0}"

    # base_delay * 2^retry_count を計算
    local exponential_delay
    exponential_delay=$((RETRY_BASE_DELAY * (1 << retry_count)))

    # 最大遅延でキャップ
    if [[ $exponential_delay -gt $RETRY_MAX_DELAY ]]; then
        exponential_delay=$RETRY_MAX_DELAY
    fi

    # Full Jitter: random(0, exponential_delay)
    local jitter=0
    if [[ $exponential_delay -gt 0 ]]; then
        jitter=$((RANDOM % (exponential_delay + 1)))
    fi

    echo "$jitter"
}

# =============================================================================
# 関数名: process_retry
# 目的: リトライ処理を実行する
#        - retry_count をインクリメント
#        - バックオフ時間を計算・記録
#        - ステータスを queued に戻す
#        - リトライのみ担当（DLQ/エスカレーション判断は呼び出し側で行う）
# 引数:
#   $1 - タスクファイルのパス
# 戻り値: 0=成功, 1=失敗
# =============================================================================
process_retry() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        _rh_log_error "ファイルが見つかりません: $file"
        return 1
    fi

    # 現在のretry_countを取得
    local current_count
    current_count=$(grep -E '^retry_count:' "$file" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')
    current_count="${current_count:-0}"

    local new_count=$((current_count + 1))

    # バックオフ時間を計算
    local backoff
    backoff=$(calculate_backoff "$current_count")

    _rh_log_info "リトライ処理: $file (試行: ${new_count}, バックオフ: ${backoff}秒)"

    # retry_countを更新（既存行を削除してから追記）
    sed -i '/^retry_count:/d' "$file" 2>/dev/null
    printf 'retry_count: %d\n' "$new_count" >> "$file"

    # last_retry_at を記録
    local retry_time
    retry_time=$(date -Iseconds)
    sed -i '/^last_retry_at:/d' "$file" 2>/dev/null
    printf 'last_retry_at: "%s"\n' "$retry_time" >> "$file"

    # next_retry_after を記録（バックオフ後の時刻）
    local next_retry
    next_retry=$(date -Iseconds -d "+${backoff} seconds" 2>/dev/null) || true
    if [[ -n "$next_retry" ]]; then
        sed -i '/^next_retry_after:/d' "$file" 2>/dev/null
        printf 'next_retry_after: "%s"\n' "$next_retry" >> "$file"
    fi

    # エラー関連フィールドをクリア
    sed -i '/^error_reason:/d' "$file" 2>/dev/null
    sed -i '/^error_at:/d' "$file" 2>/dev/null

    # ステータスをqueuedに戻す
    sed -i 's/^status:.*/status: queued/' "$file" 2>/dev/null

    _rh_log_success "リトライ完了: $file (試行: ${new_count}, 次回リトライ: ${next_retry:-不明})"
    return 0
}

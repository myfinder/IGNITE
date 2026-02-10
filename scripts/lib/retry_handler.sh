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

# core.sh の共通関数を利用
source "${BASH_SOURCE[0]%/*}/core.sh"

# MIMEメッセージ操作ツール
_RETRY_IGNITE_MIME="${BASH_SOURCE[0]%/*}/ignite_mime.py"

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
    status=$(grep -m1 "^X-IGNITE-Status:" "$file" 2>/dev/null | sed 's/^X-IGNITE-Status:[[:space:]]*//')
    if [[ "$status" != "processing" ]]; then
        return 1
    fi

    # mtime ベースのタイムアウト検知
    local file_mtime now_epoch elapsed
    file_mtime=$(stat -c %Y "$file" 2>/dev/null) || file_mtime=$(stat -f %m "$file" 2>/dev/null) || true
    if [[ -z "$file_mtime" ]]; then
        _rh_log_warn "mtime の取得に失敗: $file"
        return 1
    fi

    now_epoch=$(date +%s)
    elapsed=$((now_epoch - file_mtime))

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

    # ステータスをerrorに変更し、エラー情報をヘッダーに記録
    local error_time
    error_time=$(date -Iseconds)
    if ! python3 "$_RETRY_IGNITE_MIME" update-status "$file" error \
        --extra "X-IGNITE-Error-Reason=${reason}" "X-IGNITE-Error-At=${error_time}" 2>/dev/null; then
        _rh_log_error "ステータスの更新に失敗: $file"
        return 1
    fi

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

    # 現在のretry_countを取得（MIMEヘッダーから）
    local current_count
    current_count=$(grep -m1 "^X-IGNITE-Retry-Count:" "$file" 2>/dev/null | sed 's/^X-IGNITE-Retry-Count:[[:space:]]*//')
    current_count="${current_count:-0}"

    local new_count=$((current_count + 1))

    # バックオフ時間を計算
    local backoff
    backoff=$(calculate_backoff "$current_count")

    _rh_log_info "リトライ処理: $file (試行: ${new_count}, バックオフ: ${backoff}秒)"

    # リトライ情報をMIMEヘッダーに記録
    local retry_time
    retry_time=$(date -Iseconds)
    local next_retry
    next_retry=$(date -Iseconds -d "+${backoff} seconds" 2>/dev/null) || true

    # エラー関連ヘッダーを削除
    python3 "$_RETRY_IGNITE_MIME" remove-header "$file" "X-IGNITE-Error-Reason" 2>/dev/null
    python3 "$_RETRY_IGNITE_MIME" remove-header "$file" "X-IGNITE-Error-At" 2>/dev/null

    # ステータスをretryingに設定し、リトライ情報を更新
    local extra_args=("X-IGNITE-Retry-Count=${new_count}" "X-IGNITE-Last-Retry-At=${retry_time}")
    if [[ -n "$next_retry" ]]; then
        extra_args+=("X-IGNITE-Next-Retry-After=${next_retry}")
    fi
    python3 "$_RETRY_IGNITE_MIME" update-status "$file" retrying --extra "${extra_args[@]}" 2>/dev/null

    _rh_log_success "リトライ完了: $file (試行: ${new_count}, 次回リトライ: ${next_retry:-不明})"
    return 0
}

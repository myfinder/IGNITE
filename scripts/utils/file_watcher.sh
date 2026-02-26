#!/bin/bash
# file_watcher.sh — ファイル変更監視カスタムウォッチャー
#
# 指定ディレクトリ配下のファイル変更（作成・更新・削除）を検知し、
# Leader にイベントとして通知する。
#
# 設定ファイル: config/file-watcher.yaml
#   interval: ポーリング間隔（秒）
#   watch_dir: 監視対象ディレクトリ（IGNITE_RUNTIME_DIR からの相対パス）
#   patterns: 監視対象のファイルパターン（glob）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# core.sh が WORKSPACE_DIR / IGNITE_RUNTIME_DIR / IGNITE_CONFIG_DIR を
# PROJECT_ROOT ベースに上書きするため、呼び出し元の設定を退避・復元する
_FW_SAVED_WORKSPACE="${WORKSPACE_DIR:-}"
_FW_SAVED_RUNTIME="${IGNITE_RUNTIME_DIR:-}"
_FW_SAVED_CONFIG="${IGNITE_CONFIG_DIR:-}"

# watcher_common.sh を読み込み（core.sh も含む）
source "${SCRIPT_DIR}/../lib/watcher_common.sh"

# 退避した環境変数を復元
[[ -n "$_FW_SAVED_WORKSPACE" ]] && export WORKSPACE_DIR="$_FW_SAVED_WORKSPACE"
[[ -n "$_FW_SAVED_RUNTIME" ]] && export IGNITE_RUNTIME_DIR="$_FW_SAVED_RUNTIME"
[[ -n "$_FW_SAVED_CONFIG" ]] && export IGNITE_CONFIG_DIR="$_FW_SAVED_CONFIG"

# ─── Watcher 固有設定 ───
_FW_WATCH_DIR=""
_FW_PATTERNS="*"
_FW_SNAPSHOT_FILE=""

# _load_file_watcher_config — 固有設定を読み込む
_load_file_watcher_config() {
    local config_file="$1"
    [[ ! -f "$config_file" ]] && return 0

    # watch_dir: 監視ディレクトリ（デフォルト: repos）
    _FW_WATCH_DIR=$(yq -r '.watch_dir // "repos"' "$config_file" 2>/dev/null || echo "repos")

    # 絶対パスに解決
    if [[ "$_FW_WATCH_DIR" != /* ]]; then
        _FW_WATCH_DIR="${IGNITE_RUNTIME_DIR}/${_FW_WATCH_DIR}"
    fi

    # patterns: ファイルパターン（デフォルト: *）
    _FW_PATTERNS=$(yq -r '.patterns // "*"' "$config_file" 2>/dev/null || echo "*")

    # スナップショットファイル
    _FW_SNAPSHOT_FILE="${IGNITE_RUNTIME_DIR}/state/file_watcher_snapshot.txt"

    log_info "[${_WATCHER_NAME}] 監視ディレクトリ: ${_FW_WATCH_DIR}"
    log_info "[${_WATCHER_NAME}] ファイルパターン: ${_FW_PATTERNS}"
}

# _take_snapshot — ファイルのスナップショット（パス + タイムスタンプ）を取得
_take_snapshot() {
    local watch_dir="$1"
    local patterns="$2"

    if [[ ! -d "$watch_dir" ]]; then
        echo ""
        return 0
    fi

    # find + stat でファイル一覧を取得（パス:mtime 形式）
    find "$watch_dir" -maxdepth 3 -name "$patterns" -type f -printf '%p:%T@\n' 2>/dev/null | sort
}

# _diff_snapshots — 2つのスナップショットを比較して差分を返す
_diff_snapshots() {
    local old_snap="$1"
    local new_snap="$2"

    # 新規ファイル（new にあって old にない）
    local new_files
    new_files=$(comm -23 <(echo "$new_snap" | cut -d: -f1 | sort) \
                         <(echo "$old_snap" | cut -d: -f1 | sort) 2>/dev/null || true)

    # 削除ファイル（old にあって new にない）
    local deleted_files
    deleted_files=$(comm -13 <(echo "$new_snap" | cut -d: -f1 | sort) \
                              <(echo "$old_snap" | cut -d: -f1 | sort) 2>/dev/null || true)

    # 変更ファイル（両方にあるがタイムスタンプが異なる）
    local modified_files=""
    while IFS=: read -r path mtime; do
        [[ -z "$path" ]] && continue
        local old_mtime
        old_mtime=$(echo "$old_snap" | grep "^${path}:" | cut -d: -f2)
        if [[ -n "$old_mtime" && "$old_mtime" != "$mtime" ]]; then
            modified_files="${modified_files}${path}\n"
        fi
    done <<< "$new_snap"

    # 結果を出力
    if [[ -n "$new_files" ]]; then
        while IFS= read -r f; do
            [[ -n "$f" ]] && echo "created:$f"
        done <<< "$new_files"
    fi
    if [[ -n "$deleted_files" ]]; then
        while IFS= read -r f; do
            [[ -n "$f" ]] && echo "deleted:$f"
        done <<< "$deleted_files"
    fi
    if [[ -n "$modified_files" ]]; then
        echo -e "$modified_files" | while IFS= read -r f; do
            [[ -n "$f" ]] && echo "modified:$f"
        done
    fi
}

# ─── watcher_poll() のオーバーライド ───
watcher_poll() {
    # 監視ディレクトリが存在しなければスキップ
    if [[ ! -d "$_FW_WATCH_DIR" ]]; then
        log_info "[${_WATCHER_NAME}] 監視ディレクトリが存在しません: ${_FW_WATCH_DIR}"
        return 0
    fi

    # 現在のスナップショットを取得
    local new_snapshot
    new_snapshot=$(_take_snapshot "$_FW_WATCH_DIR" "$_FW_PATTERNS")

    # 前回のスナップショットを読み込み
    local old_snapshot=""
    if [[ -f "$_FW_SNAPSHOT_FILE" ]]; then
        old_snapshot=$(cat "$_FW_SNAPSHOT_FILE")
    fi

    # 初回は保存のみ
    if [[ -z "$old_snapshot" ]]; then
        echo "$new_snapshot" > "$_FW_SNAPSHOT_FILE"
        log_info "[${_WATCHER_NAME}] 初回スナップショット保存完了 ($(echo "$new_snapshot" | grep -c . || echo 0) ファイル)"
        return 0
    fi

    # 差分を検出
    local changes
    changes=$(_diff_snapshots "$old_snapshot" "$new_snapshot")

    if [[ -z "$changes" ]]; then
        log_info "[${_WATCHER_NAME}] 変更なし"
        echo "$new_snapshot" > "$_FW_SNAPSHOT_FILE"
        watcher_update_last_check "file_changes"
        return 0
    fi

    # 変更をイベントとして処理
    local change_count=0
    while IFS=: read -r change_type file_path; do
        [[ -z "$change_type" ]] && continue

        local event_id
        event_id="${change_type}_$(echo "$file_path" | md5sum | cut -c1-12)_$(date +%s)"

        # 重複チェック
        if watcher_is_event_processed "file_change" "$event_id"; then
            continue
        fi

        # サニタイズ
        local safe_path
        safe_path=$(_watcher_sanitize_input "$file_path" 512)

        # MIME メッセージ構築
        local relative_path="${safe_path#${IGNITE_RUNTIME_DIR}/}"
        local body_yaml
        body_yaml="event_type: \"file_change\"
change_type: \"${change_type}\"
file_path: \"${relative_path}\"
timestamp: \"$(date -Iseconds)\"
source: \"file_watcher\""

        watcher_send_mime "$_WATCHER_NAME" "leader" "file_change" "$body_yaml"
        watcher_mark_event_processed "file_change" "$event_id"

        change_count=$((change_count + 1))
        log_info "[${_WATCHER_NAME}] ファイル変更検知: ${change_type} ${relative_path}"
    done <<< "$changes"

    if [[ $change_count -gt 0 ]]; then
        log_info "[${_WATCHER_NAME}] ${change_count} 件の変更を通知しました"
    fi

    # スナップショットを更新
    echo "$new_snapshot" > "$_FW_SNAPSHOT_FILE"
    watcher_update_last_check "file_changes"
}

# ─── メイン ───

# 固有設定を読み込み
# watcher_init が _WATCHER_CONFIG_FILE を設定するので、先に init を呼ぶ
watcher_init "file_watcher" "${1:-}"

# 固有設定を読み込み
_load_file_watcher_config "$_WATCHER_CONFIG_FILE"

# デーモン起動
watcher_run_daemon

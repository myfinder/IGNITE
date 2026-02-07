# shellcheck shell=bash
# lib/session.sh - セッションID生成・ワークスペース管理
[[ -n "${__LIB_SESSION_LOADED:-}" ]] && return; __LIB_SESSION_LOADED=1

# =============================================================================
# 関数名: generate_session_id
# 目的: ユニークなtmuxセッションIDを自動生成する
# 引数: なし
# 戻り値: "ignite-XXXX" 形式のセッションID（XXXXは4文字のハッシュ）
# 生成ロジック:
#   1. PROJECT_ROOT（プロジェクトパス）と現在のUnixタイムスタンプを連結
#   2. md5sumでハッシュ化
#   3. 先頭4文字を抽出
#   4. "ignite-" プレフィックスを付与
# 例: /home/user/project + 1704067200 → ignite-a1b2
# 注意:
#   - 同じプロジェクトでも時刻が異なれば別IDが生成される
#   - セッションの重複を避けつつ、識別しやすいIDを提供
# =============================================================================
generate_session_id() {
    # プロジェクトパス + タイムスタンプから短いIDを生成
    echo "ignite-$(echo "${PROJECT_ROOT}-$(date +%s)" | md5sum | cut -c1-4)"
}

# デフォルトのワークスペースパス
get_default_workspace() {
    echo "$DEFAULT_WORKSPACE_DIR"
}

# セッションIDの設定（指定がなければ自動生成）
setup_session_name() {
    if [[ -z "$SESSION_NAME" ]]; then
        # 既存セッションを検索
        local existing_session
        existing_session=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^ignite-" | head -1 || true)

        if [[ -n "$existing_session" ]]; then
            SESSION_NAME="$existing_session"
        else
            SESSION_NAME=$(generate_session_id)
        fi
    fi
}

# ワークスペースの設定（指定がなければデフォルト）
setup_workspace() {
    if [[ -z "$WORKSPACE_DIR" ]]; then
        WORKSPACE_DIR=$(get_default_workspace)
    fi
}

# 実行中の全IGNITEセッションを一覧表示
list_sessions() {
    local sessions
    sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^ignite-" || true)

    if [[ -z "$sessions" ]]; then
        print_warning "実行中のIGNITEセッションはありません"
        return 1
    fi

    echo "$sessions"
}

# セッションが存在するかチェック
session_exists() {
    tmux has-session -t "$SESSION_NAME" 2>/dev/null
}

# 設定ファイルからワーカー数を取得
get_worker_count() {
    local config_file="$IGNITE_CONFIG_DIR/ignitians.yaml"
    if [[ -f "$config_file" ]]; then
        local count
        count=$(yaml_get "$config_file" 'default')
        if [[ -n "$count" ]] && [[ "$count" =~ ^[0-9]+$ ]]; then
            echo "$count"
            return
        fi
    fi
    echo "$DEFAULT_WORKER_COUNT"
}

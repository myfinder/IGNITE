# shellcheck shell=bash
# lib/session.sh - セッションID生成・ワークスペース管理
[[ -n "${__LIB_SESSION_LOADED:-}" ]] && return; __LIB_SESSION_LOADED=1

# =============================================================================
# 関数名: generate_session_id
# 目的: ユニークなセッションIDを自動生成する
# 引数: なし
# 戻り値: "ignite-XXXX" 形式のセッションID（XXXXは4文字のハッシュ）
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
# 解決順: 1) runtime.yaml → 2) 新規生成
setup_session_name() {
    [[ -n "$SESSION_NAME" ]] && return

    # 1. ワークスペースの runtime.yaml からセッション名を取得
    local ws="${WORKSPACE_DIR:-}"
    if [[ -z "$ws" ]] && [[ -n "${IGNITE_WORKSPACE:-}" ]]; then
        ws="$IGNITE_WORKSPACE"
    fi
    if [[ -z "$ws" ]] && [[ -d "$(pwd)/.ignite" ]]; then
        ws="$(pwd)"
    fi
    if [[ -n "$ws" ]] && [[ -f "$ws/.ignite/runtime.yaml" ]]; then
        local name
        name=$(yaml_get "$ws/.ignite/runtime.yaml" "session_name")
        if [[ -n "$name" ]]; then
            # Leader PID が生存していれば有効
            local leader_pid
            leader_pid=$(cat "$ws/.ignite/state/.agent_pid_0" 2>/dev/null || true)
            if [[ -n "$leader_pid" ]] && kill -0 "$leader_pid" 2>/dev/null; then
                SESSION_NAME="$name"
                WORKSPACE_DIR="$ws"
                return
            fi
        fi
    fi

    # 2. セッションなし → 新規生成
    SESSION_NAME=$(generate_session_id)
}

# ワークスペースの設定（指定がなければ 環境変数 → .ignite/ 自動検出 → デフォルト）
setup_workspace() {
    if [[ -z "$WORKSPACE_DIR" ]]; then
        # 環境変数 IGNITE_WORKSPACE が設定されていれば使用（systemd 連携用）
        if [[ -n "${IGNITE_WORKSPACE:-}" ]]; then
            WORKSPACE_DIR="$IGNITE_WORKSPACE"
            log_info "ワークスペース設定（環境変数）: $WORKSPACE_DIR"
        # CWD に .ignite/ があれば自動検出（Git方式）
        elif [[ -d "$(pwd)/.ignite" ]]; then
            WORKSPACE_DIR="$(pwd)"
            log_info "ワークスペース検出: $WORKSPACE_DIR"
        else
            WORKSPACE_DIR=$(get_default_workspace)
            log_info "デフォルトワークスペース: $WORKSPACE_DIR"
        fi
    fi
}

# ワークスペースディレクトリの存在チェック（start以外のコマンド用）
require_workspace() {
    if [[ ! -d "$WORKSPACE_DIR" ]]; then
        print_error "ワークスペースディレクトリが見つかりません: $WORKSPACE_DIR"
        print_info "先に 'ignite start' でワークスペースを作成してください"
        exit 1
    fi
}

# 実行中の全IGNITEセッションを一覧表示
list_sessions() {
    # runtime.yaml ベースで一覧
    local ws="${WORKSPACE_DIR:-}"
    if [[ -n "$ws" ]] && [[ -f "$ws/.ignite/runtime.yaml" ]]; then
        local name
        name=$(yaml_get "$ws/.ignite/runtime.yaml" "session_name" 2>/dev/null || true)
        if [[ -n "$name" ]]; then
            local leader_pid
            leader_pid=$(cat "$ws/.ignite/state/.agent_pid_0" 2>/dev/null || true)
            if [[ -n "$leader_pid" ]] && kill -0 "$leader_pid" 2>/dev/null; then
                echo "$name"
                return 0
            fi
        fi
    fi
    print_warning "実行中のIGNITEセッションはありません"
    return 1
}

# セッションが存在するかチェック
session_exists() {
    local state_dir="$IGNITE_RUNTIME_DIR/state"
    ls "$state_dir"/.agent_pid_* &>/dev/null || return 1
    local leader_pid
    leader_pid=$(cat "$state_dir/.agent_pid_0" 2>/dev/null || true)
    [[ -n "$leader_pid" ]] && kill -0 "$leader_pid" 2>/dev/null
}

# 設定ファイルからワーカー数を取得（resolve_config でワークスペース優先）
get_worker_count() {
    local config_file
    config_file=$(resolve_config "system.yaml" 2>/dev/null) || config_file="$IGNITE_CONFIG_DIR/system.yaml"
    if [[ -f "$config_file" ]]; then
        local count
        count=$(yaml_get "$config_file" 'worker_count')
        if [[ -n "$count" ]] && [[ "$count" =~ ^[0-9]+$ ]]; then
            echo "$count"
            return
        fi
    fi
    echo "$DEFAULT_WORKER_COUNT"
}

#!/usr/bin/env bats
# test_session.bats - セッション管理・ワークスペースチェック テスト

load test_helper

setup() {
    setup_temp_dir
    # require_workspace / setup_session_name が使うスタブ
    print_error() { echo "[ERROR] $*"; }
    print_info() { echo "[INFO] $*"; }
    print_warning() { echo "[WARN] $*"; }
    log_info() { :; }
    export -f print_error print_info print_warning log_info
    # yaml_utils.sh を読み込み（yaml_get が必要）
    unset __LIB_YAML_UTILS_LOADED
    source "$SCRIPTS_DIR/lib/yaml_utils.sh"
    # session.sh を読み込み（ガード変数をクリア）
    unset __LIB_SESSION_LOADED
    source "$SCRIPTS_DIR/lib/session.sh"
}

teardown() {
    cleanup_temp_dir
}

# --- require_workspace ---

@test "require_workspace: 存在するディレクトリならエラーなし" {
    WORKSPACE_DIR="$TEST_TEMP_DIR"
    run require_workspace
    [ "$status" -eq 0 ]
}

@test "require_workspace: 存在しないディレクトリでexit 1" {
    WORKSPACE_DIR="$TEST_TEMP_DIR/nonexistent"
    run require_workspace
    [ "$status" -eq 1 ]
    [[ "$output" == *"ワークスペースディレクトリが見つかりません"* ]]
}

@test "require_workspace: エラーメッセージにパスが含まれる" {
    WORKSPACE_DIR="$TEST_TEMP_DIR/no_such_dir"
    run require_workspace
    [ "$status" -eq 1 ]
    [[ "$output" == *"$WORKSPACE_DIR"* ]]
}

@test "require_workspace: ignite start の案内メッセージが含まれる" {
    WORKSPACE_DIR="$TEST_TEMP_DIR/missing"
    run require_workspace
    [ "$status" -eq 1 ]
    [[ "$output" == *"ignite start"* ]]
}

# --- setup_session_name ---

# tmux モック作成ヘルパー
# TMUX_MOCK_HAS_SESSION: "success" | "fail" (has-session の戻り値)
# TMUX_MOCK_LIST_SESSIONS: 改行区切りのセッション名リスト
_create_tmux_mock() {
    local mock_dir="$TEST_TEMP_DIR/bin"
    mkdir -p "$mock_dir"
    cat > "$mock_dir/tmux" << 'MOCK'
#!/bin/bash
case "$1" in
    has-session)
        if [[ "${TMUX_MOCK_HAS_SESSION:-fail}" == "success" ]]; then
            exit 0
        else
            exit 1
        fi
        ;;
    list-sessions)
        if [[ -n "${TMUX_MOCK_LIST_SESSIONS:-}" ]]; then
            echo "$TMUX_MOCK_LIST_SESSIONS"
        fi
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
MOCK
    chmod +x "$mock_dir/tmux"
    export PATH="$mock_dir:$PATH"
}

@test "setup_session_name: runtime.yaml からセッション名を取得" {
    # ワークスペースに runtime.yaml を作成
    local ws="$TEST_TEMP_DIR/workspace"
    mkdir -p "$ws/.ignite"
    cat > "$ws/.ignite/runtime.yaml" << EOF
session_name: ignite-test1234
dry_run: false
EOF

    # tmux モック: has-session 成功
    export TMUX_MOCK_HAS_SESSION="success"
    _create_tmux_mock

    SESSION_NAME=""
    WORKSPACE_DIR="$ws"

    setup_session_name

    [ "$SESSION_NAME" = "ignite-test1234" ]
    [ "$WORKSPACE_DIR" = "$ws" ]
}

@test "setup_session_name: セッション1つならそのセッションを使用" {
    # tmux モック: has-session 失敗（runtime.yaml パスをスキップ）、list-sessions は1つ
    export TMUX_MOCK_HAS_SESSION="fail"
    export TMUX_MOCK_LIST_SESSIONS="ignite-abcd"
    _create_tmux_mock

    SESSION_NAME=""
    WORKSPACE_DIR=""

    setup_session_name

    [ "$SESSION_NAME" = "ignite-abcd" ]
}

@test "setup_session_name: 複数セッションでエラー終了" {
    # tmux モック: list-sessions が複数返す
    export TMUX_MOCK_HAS_SESSION="fail"
    export TMUX_MOCK_LIST_SESSIONS=$'ignite-aaaa\nignite-bbbb'
    _create_tmux_mock

    SESSION_NAME=""
    WORKSPACE_DIR=""

    run setup_session_name

    [ "$status" -eq 1 ]
    [[ "$output" == *"複数の IGNITE セッション"* ]]
}

@test "setup_session_name: runtime.yaml のセッションが存在しない場合フォールバック" {
    # ワークスペースに runtime.yaml を作成
    local ws="$TEST_TEMP_DIR/workspace"
    mkdir -p "$ws/.ignite"
    cat > "$ws/.ignite/runtime.yaml" << EOF
session_name: ignite-dead
dry_run: false
EOF

    # tmux モック: has-session 失敗、list-sessions は1つ
    export TMUX_MOCK_HAS_SESSION="fail"
    export TMUX_MOCK_LIST_SESSIONS="ignite-live"
    _create_tmux_mock

    SESSION_NAME=""
    WORKSPACE_DIR="$ws"

    setup_session_name

    # runtime.yaml のセッションは存在しないのでフォールバックして list-sessions の結果を使う
    [ "$SESSION_NAME" = "ignite-live" ]
}

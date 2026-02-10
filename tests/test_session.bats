#!/usr/bin/env bats
# test_session.bats - セッション管理・ワークスペースチェック テスト

load test_helper

setup() {
    setup_temp_dir
    # require_workspace が使う print_error / print_info のスタブ
    print_error() { echo "[ERROR] $*"; }
    print_info() { echo "[INFO] $*"; }
    export -f print_error print_info
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

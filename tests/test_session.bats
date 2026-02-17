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

@test "setup_session_name: runtime.yaml + Leader PID 生存でセッション名を取得" {
    # ワークスペースに runtime.yaml を作成
    local ws="$TEST_TEMP_DIR/workspace"
    mkdir -p "$ws/.ignite/state"
    cat > "$ws/.ignite/runtime.yaml" << EOF
session_name: ignite-test1234
dry_run: false
EOF
    # 自プロセスの PID を Leader PID として設定（必ず生存している）
    echo "$$" > "$ws/.ignite/state/.agent_pid_0"

    SESSION_NAME=""
    WORKSPACE_DIR="$ws"

    setup_session_name

    [ "$SESSION_NAME" = "ignite-test1234" ]
    [ "$WORKSPACE_DIR" = "$ws" ]
}

@test "setup_session_name: runtime.yaml あるが Leader PID 死亡 → 新規生成" {
    # ワークスペースに runtime.yaml を作成
    local ws="$TEST_TEMP_DIR/workspace"
    mkdir -p "$ws/.ignite/state"
    cat > "$ws/.ignite/runtime.yaml" << EOF
session_name: ignite-dead
dry_run: false
EOF
    # 存在しない PID を設定
    echo "99999999" > "$ws/.ignite/state/.agent_pid_0"

    SESSION_NAME=""
    WORKSPACE_DIR="$ws"

    setup_session_name

    # Leader PID が死亡しているので新規生成される
    [[ "$SESSION_NAME" == ignite-* ]]
    [ "$SESSION_NAME" != "ignite-dead" ]
}

@test "setup_session_name: runtime.yaml なし → 新規生成" {
    SESSION_NAME=""
    WORKSPACE_DIR=""

    setup_session_name

    [[ "$SESSION_NAME" == ignite-* ]]
}

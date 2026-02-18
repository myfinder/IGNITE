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

# --- list_all_sessions ---

@test "list_all_sessions: sessions/*.yaml から正常セッションを取得" {
    local ws="$TEST_TEMP_DIR/workspace"
    mkdir -p "$ws/.ignite/sessions" "$ws/.ignite/state"
    cat > "$ws/.ignite/sessions/test-session.yaml" << EOF
session_name: ignite-test1
workspace_dir: $ws
mode: headless
agents_total: 8
agents_actual: 8
EOF
    # PID なし → stopped
    WORKSPACE_DIR="$ws"
    run list_all_sessions
    [ "$status" -eq 0 ]
    [[ "$output" == *"ignite-test1"* ]]
    [[ "$output" == *"stopped"* ]]
}

@test "list_all_sessions: 空YAMLファイルをスキップ+stderrに警告" {
    local ws="$TEST_TEMP_DIR/workspace"
    mkdir -p "$ws/.ignite/sessions"
    touch "$ws/.ignite/sessions/empty.yaml"

    WORKSPACE_DIR="$ws"
    run list_all_sessions
    # 空ファイルのみなのでセッションなし → return 1
    [ "$status" -eq 1 ]
    [[ "$output" == *"空のセッションファイルをスキップ"* ]]
}

@test "list_all_sessions: session_name 欠損YAMLをスキップ+stderrに警告" {
    local ws="$TEST_TEMP_DIR/workspace"
    mkdir -p "$ws/.ignite/sessions"
    cat > "$ws/.ignite/sessions/bad.yaml" << EOF
workspace_dir: $ws
mode: headless
EOF

    WORKSPACE_DIR="$ws"
    run list_all_sessions
    [ "$status" -eq 1 ]
    [[ "$output" == *"session_name が欠損"* ]]
}

@test "list_all_sessions: workspace_dir 欠損YAMLをスキップ+stderrに警告" {
    local ws="$TEST_TEMP_DIR/workspace"
    mkdir -p "$ws/.ignite/sessions"
    cat > "$ws/.ignite/sessions/bad2.yaml" << EOF
session_name: ignite-bad
mode: headless
EOF

    WORKSPACE_DIR="$ws"
    run list_all_sessions
    [ "$status" -eq 1 ]
    [[ "$output" == *"workspace_dir が欠損"* ]]
}

@test "list_all_sessions: staleセッション（PID無効）をスキップ+stderrに警告" {
    local ws="$TEST_TEMP_DIR/workspace"
    mkdir -p "$ws/.ignite/sessions" "$ws/.ignite/state"
    cat > "$ws/.ignite/sessions/stale.yaml" << EOF
session_name: ignite-stale
workspace_dir: $ws
EOF
    # 存在しないPIDを設定
    echo "99999999" > "$ws/.ignite/state/.agent_pid_0"

    WORKSPACE_DIR="$ws"
    run list_all_sessions
    [ "$status" -eq 1 ]
    [[ "$output" == *"staleセッション検出"* ]]
}

@test "list_all_sessions: running セッション（PID生存）を正しく判定" {
    local ws="$TEST_TEMP_DIR/workspace"
    mkdir -p "$ws/.ignite/sessions" "$ws/.ignite/state"
    cat > "$ws/.ignite/sessions/active.yaml" << EOF
session_name: ignite-active
workspace_dir: $ws
EOF
    # 自プロセスのPIDを設定（必ず生存）
    echo "$$" > "$ws/.ignite/state/.agent_pid_0"

    WORKSPACE_DIR="$ws"
    run list_all_sessions
    [ "$status" -eq 0 ]
    [[ "$output" == *"ignite-active"* ]]
    [[ "$output" == *"running"* ]]
}

@test "list_all_sessions: sessionsディレクトリなし → runtime.yaml フォールバック" {
    local ws="$TEST_TEMP_DIR/workspace"
    mkdir -p "$ws/.ignite/state"
    cat > "$ws/.ignite/runtime.yaml" << EOF
session_name: ignite-rt
EOF
    # PIDなし → stopped
    WORKSPACE_DIR="$ws"
    run list_all_sessions
    [ "$status" -eq 0 ]
    [[ "$output" == *"ignite-rt"* ]]
    [[ "$output" == *"stopped"* ]]
}

@test "list_all_sessions: --all で IGNITE_WORKSPACES_DIR 環境変数を使用" {
    local parent="$TEST_TEMP_DIR/workspaces"
    local ws1="$parent/ws1"
    local ws2="$parent/ws2"
    mkdir -p "$ws1/.ignite/sessions" "$ws1/.ignite/state"
    mkdir -p "$ws2/.ignite/sessions" "$ws2/.ignite/state"
    cat > "$ws1/.ignite/sessions/s1.yaml" << EOF
session_name: ignite-s1
workspace_dir: $ws1
EOF
    cat > "$ws2/.ignite/sessions/s2.yaml" << EOF
session_name: ignite-s2
workspace_dir: $ws2
EOF

    WORKSPACE_DIR="$ws1"
    IGNITE_WORKSPACES_DIR="$parent"
    run list_all_sessions --all
    [ "$status" -eq 0 ]
    [[ "$output" == *"ignite-s1"* ]]
    [[ "$output" == *"ignite-s2"* ]]
}

@test "list_all_sessions: --all なしは現ワークスペースのみ" {
    local parent="$TEST_TEMP_DIR/workspaces"
    local ws1="$parent/ws1"
    local ws2="$parent/ws2"
    mkdir -p "$ws1/.ignite/sessions" "$ws1/.ignite/state"
    mkdir -p "$ws2/.ignite/sessions" "$ws2/.ignite/state"
    cat > "$ws1/.ignite/sessions/s1.yaml" << EOF
session_name: ignite-s1
workspace_dir: $ws1
EOF
    cat > "$ws2/.ignite/sessions/s2.yaml" << EOF
session_name: ignite-s2
workspace_dir: $ws2
EOF

    WORKSPACE_DIR="$ws1"
    IGNITE_WORKSPACES_DIR="$parent"
    run list_all_sessions
    [ "$status" -eq 0 ]
    [[ "$output" == *"ignite-s1"* ]]
    [[ "$output" != *"ignite-s2"* ]]
}

@test "list_all_sessions: セッションなし → return 1" {
    local ws="$TEST_TEMP_DIR/workspace"
    mkdir -p "$ws/.ignite"

    WORKSPACE_DIR="$ws"
    run list_all_sessions
    [ "$status" -eq 1 ]
}

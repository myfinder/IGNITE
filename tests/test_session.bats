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
    # テスト用に XDG_DATA_HOME を一時ディレクトリに設定
    export XDG_DATA_HOME="$TEST_TEMP_DIR/xdg_data"
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

# --- get_workspaces_list_path ---

@test "get_workspaces_list_path: XDG_DATA_HOME 設定時のパス" {
    export XDG_DATA_HOME="$TEST_TEMP_DIR/custom_xdg"
    run get_workspaces_list_path
    [ "$status" -eq 0 ]
    [ "$output" = "$TEST_TEMP_DIR/custom_xdg/ignite/workspaces.list" ]
}

@test "get_workspaces_list_path: XDG_DATA_HOME 未設定時のデフォルトパス" {
    unset XDG_DATA_HOME
    run get_workspaces_list_path
    [ "$status" -eq 0 ]
    [ "$output" = "$HOME/.local/share/ignite/workspaces.list" ]
}

# --- register_workspace ---

@test "register_workspace: 新規登録で workspaces.list にパスが追加される" {
    local ws="$TEST_TEMP_DIR/ws1"
    mkdir -p "$ws/.ignite"

    register_workspace "$ws"

    local list_file
    list_file="$(get_workspaces_list_path)"
    [ -f "$list_file" ]
    grep -qxF "$(realpath "$ws")" "$list_file"
}

@test "register_workspace: 重複登録で行が増えない" {
    local ws="$TEST_TEMP_DIR/ws1"
    mkdir -p "$ws/.ignite"

    register_workspace "$ws"
    register_workspace "$ws"
    register_workspace "$ws"

    local list_file
    list_file="$(get_workspaces_list_path)"
    local count
    count=$(grep -cxF "$(realpath "$ws")" "$list_file")
    [ "$count" -eq 1 ]
}

@test "register_workspace: 複数ワークスペースを登録" {
    local ws1="$TEST_TEMP_DIR/ws1"
    local ws2="$TEST_TEMP_DIR/ws2"
    mkdir -p "$ws1/.ignite" "$ws2/.ignite"

    register_workspace "$ws1"
    register_workspace "$ws2"

    local list_file
    list_file="$(get_workspaces_list_path)"
    grep -qxF "$(realpath "$ws1")" "$list_file"
    grep -qxF "$(realpath "$ws2")" "$list_file"
}

@test "register_workspace: WORKSPACE_DIR フォールバック" {
    local ws="$TEST_TEMP_DIR/ws_fallback"
    mkdir -p "$ws/.ignite"
    WORKSPACE_DIR="$ws"

    register_workspace

    local list_file
    list_file="$(get_workspaces_list_path)"
    grep -qxF "$(realpath "$ws")" "$list_file"
}

@test "register_workspace: ディレクトリ自動作成" {
    local list_file
    list_file="$(get_workspaces_list_path)"
    # ディレクトリが存在しないことを確認
    [ ! -d "$(dirname "$list_file")" ]

    local ws="$TEST_TEMP_DIR/ws_autodir"
    mkdir -p "$ws/.ignite"
    register_workspace "$ws"

    [ -f "$list_file" ]
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

@test "list_all_sessions: staleセッション（PID無効）をSTATUS=stoppedとして出力" {
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
    # staleセッションはスキップされず stopped として出力される
    [ "$status" -eq 0 ]
    [[ "$output" == *"ignite-stale"* ]]
    [[ "$output" == *"stopped"* ]]
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

@test "list_all_sessions: --all で workspaces.list を使用して横断表示" {
    local ws1="$TEST_TEMP_DIR/ws1"
    local ws2="$TEST_TEMP_DIR/ws2"
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

    # workspaces.list に2つのワークスペースを登録
    register_workspace "$ws1"
    register_workspace "$ws2"

    WORKSPACE_DIR="$ws1"
    run list_all_sessions --all
    [ "$status" -eq 0 ]
    [[ "$output" == *"ignite-s1"* ]]
    [[ "$output" == *"ignite-s2"* ]]
}

@test "list_all_sessions: --all なしは現ワークスペースのみ" {
    local ws1="$TEST_TEMP_DIR/ws1"
    local ws2="$TEST_TEMP_DIR/ws2"
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

    # workspaces.list に2つのワークスペースを登録
    register_workspace "$ws1"
    register_workspace "$ws2"

    WORKSPACE_DIR="$ws1"
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

@test "list_all_sessions: --all で workspaces.list 非存在時は現WSのみフォールバック" {
    local ws="$TEST_TEMP_DIR/ws_only"
    mkdir -p "$ws/.ignite/sessions" "$ws/.ignite/state"
    cat > "$ws/.ignite/sessions/s1.yaml" << EOF
session_name: ignite-fallback
workspace_dir: $ws
EOF

    # workspaces.list を作成しない
    WORKSPACE_DIR="$ws"
    run list_all_sessions --all
    [ "$status" -eq 0 ]
    [[ "$output" == *"ignite-fallback"* ]]
}

@test "list_all_sessions: --all で workspaces.list 内の無効パスをスキップ+警告" {
    local ws1="$TEST_TEMP_DIR/ws_valid"
    local ws_invalid="$TEST_TEMP_DIR/ws_nonexistent"
    mkdir -p "$ws1/.ignite/sessions" "$ws1/.ignite/state"
    cat > "$ws1/.ignite/sessions/s1.yaml" << EOF
session_name: ignite-valid
workspace_dir: $ws1
EOF

    # workspaces.list に有効パスと無効パスを登録
    register_workspace "$ws1"
    local list_file
    list_file="$(get_workspaces_list_path)"
    echo "$ws_invalid" >> "$list_file"

    WORKSPACE_DIR="$ws1"
    run list_all_sessions --all
    [ "$status" -eq 0 ]
    [[ "$output" == *"ignite-valid"* ]]
    [[ "$output" == *"無効なワークスペースパスをスキップ"* ]]
}

@test "list_all_sessions: --all で IGNITE_WORKSPACES_DIR セカンダリフォールバック" {
    local parent="$TEST_TEMP_DIR/workspaces"
    local ws1="$parent/ws1"
    local ws2="$parent/ws2"
    mkdir -p "$ws1/.ignite/sessions" "$ws1/.ignite/state"
    mkdir -p "$ws2/.ignite/sessions" "$ws2/.ignite/state"
    cat > "$ws1/.ignite/sessions/s1.yaml" << EOF
session_name: ignite-env1
workspace_dir: $ws1
EOF
    cat > "$ws2/.ignite/sessions/s2.yaml" << EOF
session_name: ignite-env2
workspace_dir: $ws2
EOF

    # workspaces.list は作成しない → IGNITE_WORKSPACES_DIR にフォールバック
    WORKSPACE_DIR="$ws1"
    IGNITE_WORKSPACES_DIR="$parent"
    run list_all_sessions --all
    [ "$status" -eq 0 ]
    [[ "$output" == *"ignite-env1"* ]]
    [[ "$output" == *"ignite-env2"* ]]
}

@test "list_all_sessions: 出力がTSV形式（SESSION, STATUS, WORKSPACE）" {
    local ws="$TEST_TEMP_DIR/workspace"
    mkdir -p "$ws/.ignite/sessions" "$ws/.ignite/state"
    cat > "$ws/.ignite/sessions/test.yaml" << EOF
session_name: ignite-tsv
workspace_dir: $ws
EOF

    WORKSPACE_DIR="$ws"
    run list_all_sessions
    [ "$status" -eq 0 ]
    # TAB区切りで4カラムであることを検証（session_name, status, agents, workspace_dir）
    local line="$output"
    local col_count
    col_count=$(echo "$line" | awk -F'\t' '{print NF}')
    [ "$col_count" -eq 4 ]
}

@test "list_all_sessions: ワークスペースパスがフルパスで出力される" {
    local ws="$TEST_TEMP_DIR/workspace"
    mkdir -p "$ws/.ignite/sessions" "$ws/.ignite/state"
    cat > "$ws/.ignite/sessions/test.yaml" << EOF
session_name: ignite-fullpath
workspace_dir: $ws
EOF

    WORKSPACE_DIR="$ws"
    run list_all_sessions
    [ "$status" -eq 0 ]
    # フルパスが出力に含まれる（basenameではない）
    local ws_normalized
    ws_normalized="$(realpath "$ws")"
    [[ "$output" == *"$ws_normalized"* ]]
}

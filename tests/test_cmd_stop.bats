#!/usr/bin/env bats
# =============================================================================
# cmd_stop.sh テスト
# テスト対象: scripts/lib/cmd_stop.sh
# _kill_process_tree, _stop_systemd_service, _sweep_orphan_processes,
# _check_remaining_processes, _is_workspace_process
# =============================================================================

load 'test_helper'

setup() {
    setup_temp_dir

    export IGNITE_CONFIG_DIR="$TEST_TEMP_DIR/config_dir"
    mkdir -p "$IGNITE_CONFIG_DIR"

    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
defaults:
  message_priority: normal
EOF

    # core.sh を source（cmd_stop.sh の依存関係を解決）
    source "$SCRIPTS_DIR/lib/core.sh"

    # cmd_stop.sh を source（テスト対象の関数を読み込み）
    source "$SCRIPTS_DIR/lib/cmd_stop.sh"

    # テスト用ワークスペース
    export WORKSPACE_DIR="$TEST_TEMP_DIR/workspace"
    export IGNITE_RUNTIME_DIR="$WORKSPACE_DIR/.ignite"
    mkdir -p "$IGNITE_RUNTIME_DIR/state"
    mkdir -p "$IGNITE_RUNTIME_DIR/logs"
}

teardown() {
    cleanup_temp_dir
}

# =============================================================================
# _validate_pid テスト
# =============================================================================

@test "_validate_pid: 空PIDでエラー" {
    run _validate_pid "" "opencode"
    [ "$status" -ne 0 ]
}

@test "_validate_pid: 存在しないPIDでエラー" {
    run _validate_pid "9999999" "opencode"
    [ "$status" -ne 0 ]
}

@test "_validate_pid: 自プロセスPIDで正常（パターン一致時）" {
    run _validate_pid "$$" "bash"
    [ "$status" -eq 0 ]
}

# =============================================================================
# _kill_process_tree テスト
# =============================================================================

@test "_kill_process_tree: 存在しないPIDで正常終了（エラーにならない）" {
    # PGIDファイルなし、PID存在しない → 全ステップがスキップされるだけ
    run _kill_process_tree "9999999" "99" "$IGNITE_RUNTIME_DIR"
    [ "$status" -eq 0 ]
}

@test "_kill_process_tree: PGIDファイルなしでも正常動作" {
    # PGIDファイルを作成しない状態で呼び出し
    run _kill_process_tree "9999999" "0" "$IGNITE_RUNTIME_DIR"
    [ "$status" -eq 0 ]
}

# =============================================================================
# _is_workspace_process テスト
# =============================================================================

@test "_is_workspace_process: 存在しないPIDでfalse" {
    run _is_workspace_process "9999999"
    [ "$status" -ne 0 ]
}

# =============================================================================
# _sweep_orphan_processes テスト
# =============================================================================

@test "_sweep_orphan_processes: 孤立プロセス0件でエラーにならない" {
    # pgrep が何も返さない場合
    pgrep() { return 1; }
    export -f pgrep

    run _sweep_orphan_processes
    [ "$status" -eq 0 ]
}

# =============================================================================
# _check_remaining_processes テスト
# =============================================================================

@test "_check_remaining_processes: 残存0件でエラーにならない" {
    pgrep() { return 1; }
    export -f pgrep

    run _check_remaining_processes
    [ "$status" -eq 0 ]
}

# =============================================================================
# _stop_systemd_service テスト
# =============================================================================

@test "_stop_systemd_service: systemctlなし環境でスキップ" {
    # systemctl を PATH から除外
    command() {
        if [[ "$2" == "systemctl" ]]; then
            return 1
        fi
        builtin command "$@"
    }
    export -f command

    export SESSION_NAME="ignite-test"
    run _stop_systemd_service
    [ "$status" -eq 0 ]
}

@test "_stop_systemd_service: INVOCATION_ID設定時にスキップ（再帰防止）" {
    systemctl() { return 0; }
    export -f systemctl

    export SESSION_NAME="ignite-test"
    export INVOCATION_ID="test-invocation-id-12345"
    run _stop_systemd_service
    [ "$status" -eq 0 ]
    [[ "$output" == *"systemd 経由"* ]] || [[ "$output" == *"スキップ"* ]]
    unset INVOCATION_ID
}

@test "_stop_systemd_service: 直接実行でactive時にstop呼び出し" {
    local stop_called=false
    systemctl() {
        if [[ "$*" == *"is-active"* ]]; then
            echo "active"
            return 0
        fi
        if [[ "$*" == *"stop"* ]]; then
            return 0
        fi
        return 0
    }
    export -f systemctl

    export SESSION_NAME="ignite-test"
    unset INVOCATION_ID
    run _stop_systemd_service
    [ "$status" -eq 0 ]
    [[ "$output" == *"停止"* ]]
}

@test "_stop_systemd_service: inactive時にスキップ" {
    systemctl() {
        if [[ "$*" == *"is-active"* ]]; then
            echo "inactive"
            return 0
        fi
        return 0
    }
    export -f systemctl

    export SESSION_NAME="ignite-test"
    unset INVOCATION_ID
    run _stop_systemd_service
    [ "$status" -eq 0 ]
}

# =============================================================================
# _stop_daemon_process テスト
# =============================================================================

@test "_stop_daemon_process: PIDファイルなしで即リターン" {
    run _stop_daemon_process "$TEST_TEMP_DIR/nonexistent.pid" "TestDaemon"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "_stop_daemon_process: PIDファイルはあるがプロセス不在で正常終了＋PIDファイル削除" {
    local pid_file="$TEST_TEMP_DIR/test_daemon.pid"
    echo "9999999" > "$pid_file"

    run _stop_daemon_process "$pid_file" "TestDaemon"
    [ "$status" -eq 0 ]
    # PIDファイルが削除されていること
    [ ! -f "$pid_file" ]
}

@test "_stop_daemon_process: 実プロセスを起動して停止できる" {
    local pid_file="$TEST_TEMP_DIR/test_daemon.pid"
    # バックグラウンドで sleep プロセスを起動
    sleep 300 &
    local daemon_pid=$!
    echo "$daemon_pid" > "$pid_file"

    # テスト失敗時のリーク防止
    trap 'kill "$daemon_pid" 2>/dev/null || true' RETURN

    run _stop_daemon_process "$pid_file" "TestDaemon"
    [ "$status" -eq 0 ]
    # プロセスが停止していること
    ! kill -0 "$daemon_pid" 2>/dev/null
    # PIDファイルが削除されていること
    [ ! -f "$pid_file" ]
}

# =============================================================================
# _get_pgid テスト
# =============================================================================

@test "_get_pgid: 自プロセスのPGIDを取得できる" {
    source "$SCRIPTS_DIR/lib/cli_provider.sh"
    run _get_pgid "$$"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    # PGID は数値であること
    [[ "$output" =~ ^[0-9]+$ ]]
}

# =============================================================================
# setsid / PGID アーキテクチャ検証
# =============================================================================

@test "cli_provider.sh: PGIDファイル（agent_pgid）への参照が存在しない" {
    local content
    content=$(cat "$SCRIPTS_DIR/lib/cli_provider.sh")
    [[ "$content" != *"agent_pgid"* ]]
}

# =============================================================================
# DRY化テスト: agent.sh が _kill_process_tree を使用
# =============================================================================

@test "agent.sh: _kill_agent_process が _kill_process_tree を呼び出している" {
    local func_body
    func_body=$(sed -n '/_kill_agent_process()/,/^}/p' "$SCRIPTS_DIR/lib/agent.sh")
    [[ "$func_body" == *"_kill_process_tree"* ]]
}

@test "agent.sh: _kill_agent_process 内に直接 pkill -P が存在しない" {
    local func_body
    func_body=$(sed -n '/_kill_agent_process()/,/^}/p' "$SCRIPTS_DIR/lib/agent.sh")
    [[ "$func_body" != *"pkill -P"* ]]
}

# =============================================================================
# cmd_stop DRY化テスト: watcher/monitor が _stop_daemon_process を使用
# =============================================================================

@test "cmd_stop: watcher/monitor停止が _stop_daemon_process を使用している" {
    local func_body
    func_body=$(sed -n '/^cmd_stop()/,/^}/p' "$SCRIPTS_DIR/lib/cmd_stop.sh")
    [[ "$func_body" == *"_stop_daemon_process"* ]]
}

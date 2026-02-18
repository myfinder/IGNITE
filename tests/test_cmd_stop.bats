#!/usr/bin/env bats
# =============================================================================
# cmd_stop.sh テスト
# テスト対象: scripts/lib/cmd_stop.sh
# _kill_process_tree, _stop_systemd_service, _sweep_orphan_processes,
# _check_remaining_processes, _is_workspace_process, _stop_pid_process
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

@test "_kill_process_tree: stale PGIDファイルで誤killしない" {
    # 存在しないPIDのPGIDファイルを作成 → _validate_pid で弾かれる
    echo "9999999" > "$IGNITE_RUNTIME_DIR/state/.agent_pgid_0"
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
# _stop_pid_process テスト
# =============================================================================

@test "_stop_pid_process: PIDファイルなしで正常終了" {
    run _stop_pid_process "$IGNITE_RUNTIME_DIR/nonexistent.pid" "テスト"
    [ "$status" -eq 0 ]
}

@test "_stop_pid_process: 存在しないPIDで正常終了" {
    echo "9999999" > "$IGNITE_RUNTIME_DIR/test.pid"
    run _stop_pid_process "$IGNITE_RUNTIME_DIR/test.pid" "テスト"
    [ "$status" -eq 0 ]
    # PIDファイルが削除されている
    [ ! -f "$IGNITE_RUNTIME_DIR/test.pid" ]
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
# DRY化テスト: agent.sh が _kill_process_tree を使用
# =============================================================================

@test "agent.sh: _kill_agent_process が _kill_process_tree を呼び出している" {
    local func_body
    func_body=$(sed -n '/_kill_agent_process()/,/^}/p' "$SCRIPTS_DIR/lib/agent.sh")
    [[ "$func_body" == *"_kill_process_tree"* ]]
    [[ "$func_body" != *"pkill -P"* ]]
}

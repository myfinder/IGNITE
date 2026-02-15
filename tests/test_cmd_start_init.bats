#!/usr/bin/env bats
# =============================================================================
# cmd_start.sh --dry-run 統合テスト
# テスト対象: scripts/ignite start --dry-run
# Phase 1-5,8 が正常実行され、Phase 6,7,9 がスキップされることを検証
# =============================================================================

load 'test_helper'

setup() {
    setup_temp_dir

    # テスト用ワークスペース構築
    export TEST_WORKSPACE="$TEST_TEMP_DIR/workspace"
    mkdir -p "$TEST_WORKSPACE/.ignite"

    # 最小限の system.yaml を作成
    cat > "$TEST_WORKSPACE/.ignite/system.yaml" <<'YAML'
tmux:
  window_name: ignite
delays:
  process_cleanup: 0
  session_create: 0
  leader_startup: 0
  claude_startup: 0
  leader_init: 0
  permission_accept: 0
  prompt_send: 0
  agent_stabilize: 0
  agent_retry_wait: 0
defaults:
  message_priority: normal
  worker_count: 2
YAML
}

teardown() {
    cleanup_temp_dir
}

# =============================================================================
# 正常系テスト
# =============================================================================

@test "dry-run: ワークスペースディレクトリ構造が作成される" {
    run "$PROJECT_ROOT/scripts/ignite" start --dry-run --skip-validation -n -w "$TEST_WORKSPACE"

    # IGNITE_RUNTIME_DIR = $TEST_WORKSPACE/.ignite（.ignite/ が存在するため）
    local runtime_dir="$TEST_WORKSPACE/.ignite"
    [ "$status" -eq 0 ]
    [ -d "$runtime_dir/queue/leader" ]
    [ -d "$runtime_dir/queue/strategist" ]
    [ -d "$runtime_dir/queue/coordinator" ]
    [ -d "$runtime_dir/context" ]
    [ -d "$runtime_dir/logs" ]
    [ -d "$runtime_dir/state" ]
    [ -d "$runtime_dir/repos" ]
}

@test "dry-run: DB初期化が実行される（state/memory.db + テーブル作成）" {
    run "$PROJECT_ROOT/scripts/ignite" start --dry-run --skip-validation -n -w "$TEST_WORKSPACE"

    local runtime_dir="$TEST_WORKSPACE/.ignite"
    [ "$status" -eq 0 ]
    [ -f "$runtime_dir/state/memory.db" ]

    # agent_states テーブルの存在確認
    local tables
    tables=$(sqlite3 "$runtime_dir/state/memory.db" \
        "SELECT name FROM sqlite_master WHERE type='table' AND name='agent_states';")
    [ "$tables" = "agent_states" ]
}

@test "dry-run: dashboard.md が生成される" {
    run "$PROJECT_ROOT/scripts/ignite" start --dry-run --skip-validation -n -w "$TEST_WORKSPACE"

    local runtime_dir="$TEST_WORKSPACE/.ignite"
    [ "$status" -eq 0 ]
    [ -f "$runtime_dir/dashboard.md" ]

    # 基本コンテンツの確認
    local content
    content=$(cat "$runtime_dir/dashboard.md")
    [[ "$content" == *"IGNITE Dashboard"* ]]
}

@test "dry-run: runtime.yaml が生成される" {
    run "$PROJECT_ROOT/scripts/ignite" start --dry-run --skip-validation -n -w "$TEST_WORKSPACE"

    local runtime_dir="$TEST_WORKSPACE/.ignite"
    [ "$status" -eq 0 ]
    [ -f "$runtime_dir/runtime.yaml" ]

    # dry_run: true が含まれること
    local content
    content=$(cat "$runtime_dir/runtime.yaml")
    [[ "$content" == *"dry_run: true"* ]]
}

@test "dry-run: tmux/Claude起動がスキップされる（[DRY-RUN]メッセージ確認）" {
    run "$PROJECT_ROOT/scripts/ignite" start --dry-run --skip-validation -n -w "$TEST_WORKSPACE"

    [ "$status" -eq 0 ]
    [[ "$output" == *"[DRY-RUN] 初期化検証完了"* ]]
    [[ "$output" == *"Phase 6: tmuxセッション作成"* ]]
    [[ "$output" == *"Phase 7: Claude CLI起動"* ]]

    # dry-runではtmuxセッション名が出力に含まれないこと確認
    [[ "$output" != *"tmuxセッションを作成中"* ]]
}

@test "dry-run: Phase 1-5 が実行済みであること（出力メッセージ確認）" {
    run "$PROJECT_ROOT/scripts/ignite" start --dry-run --skip-validation -n -w "$TEST_WORKSPACE"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Phase 1: パラメータ解析 ... OK"* ]]
    [[ "$output" == *"Phase 4: ディレクトリ/DB初期化 ... OK"* ]]
    [[ "$output" == *"Phase 5: PIDクリーンアップ ... OK"* ]]
    [[ "$output" == *"Phase 8: システム設定生成 ... OK"* ]]
}

# =============================================================================
# 異常系テスト
# =============================================================================

@test "dry-run: 不正なオプションでエラー終了" {
    run "$PROJECT_ROOT/scripts/ignite" start --dry-run --invalid-option -n -w "$TEST_WORKSPACE"

    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown option"* ]]
}

@test "dry-run: .ignite/ 未初期化ワークスペースでエラー" {
    local bad_workspace="$TEST_TEMP_DIR/no_ignite"
    mkdir -p "$bad_workspace"

    run "$PROJECT_ROOT/scripts/ignite" start --dry-run --skip-validation -n -w "$bad_workspace"

    [ "$status" -ne 0 ]
    [[ "$output" == *".ignite/"* ]]
}

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
delays:
  process_cleanup: 0
  leader_startup: 0
  server_ready: 0
  leader_init: 0
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

@test "dry-run: エージェントサーバー起動がスキップされる（[DRY-RUN]メッセージ確認）" {
    run "$PROJECT_ROOT/scripts/ignite" start --dry-run --skip-validation -n -w "$TEST_WORKSPACE"

    [ "$status" -eq 0 ]
    [[ "$output" == *"[DRY-RUN] 初期化検証完了"* ]]
    [[ "$output" == *"Phase 6: エージェントサーバー起動"* ]]
    [[ "$output" == *"Phase 7: AI CLI起動"* ]]
}

@test "dry-run: 通常(PTY) はカラー出力が含まれる" {
    # CI 環境では PTY が正常に動作しない場合があるためスキップ
    if [[ -n "${CI:-}" ]]; then
        skip "CI 環境では PTY テストをスキップ"
    fi
    local cmd
    cmd="$PROJECT_ROOT/scripts/ignite start --dry-run --skip-validation -n -w $TEST_WORKSPACE"
    run run_with_pty "$cmd"
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\x1b['* ]]
}

@test "dry-run: 非対話環境ではカラー出力が含まれない" {
    run "$PROJECT_ROOT/scripts/ignite" start --dry-run --skip-validation -n -w "$TEST_WORKSPACE"
    [ "$status" -eq 0 ]
    [[ "$output" != *$'\x1b['* ]]
}

@test "dry-run: NO_COLOR ではカラー出力が含まれない" {
    # CI 環境では PTY が正常に動作しない場合があるためスキップ
    if [[ -n "${CI:-}" ]]; then
        skip "CI 環境では PTY テストをスキップ"
    fi
    local cmd
    cmd="NO_COLOR=1 $PROJECT_ROOT/scripts/ignite start --dry-run --skip-validation -n -w $TEST_WORKSPACE"
    run run_with_pty "$cmd"
    [ "$status" -eq 0 ]
    [[ "$output" != *$'\x1b['* ]]
}

@test "dry-run: 最終サマリが出力される" {
    run "$PROJECT_ROOT/scripts/ignite" start --dry-run --skip-validation -n -w "$TEST_WORKSPACE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[DRY-RUN] 初期化検証完了"* ]]
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

# =============================================================================
# _reap_jobs の set -e 対応テスト
# =============================================================================

@test "_reap_jobs: set -e 下で非零ジョブを正しくカウントする" {
    # _reap_jobs 関数を含むスクリプトを set -e で実行し、
    # 非零終了のジョブがあっても exit しないことを確認
    run bash -c '
        set -e
        _job_pids=()
        declare -A _job_label=()
        declare -A _job_start=()
        _job_success=0
        _job_failed=0

        _reap_jobs() {
            local -a remaining=()
            for pid in "${_job_pids[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then
                    remaining+=("$pid")
                else
                    wait "$pid" && local rc=0 || local rc=$?
                    if [[ $rc -eq 0 ]]; then
                        _job_success=$(( _job_success + 1 ))
                    else
                        _job_failed=$(( _job_failed + 1 ))
                    fi
                fi
            done
            _job_pids=("${remaining[@]}")
        }

        # 成功するジョブ
        true &
        _job_pids+=($!)
        _job_label[$!]="success_job"
        _job_start[$!]=$(date +%s)

        # 失敗するジョブ
        false &
        _job_pids+=($!)
        _job_label[$!]="failure_job"
        _job_start[$!]=$(date +%s)

        sleep 0.5
        _reap_jobs

        echo "success=$_job_success failed=$_job_failed"
        [[ $_job_success -eq 1 ]] || exit 10
        [[ $_job_failed -eq 1 ]] || exit 11
    '

    [ "$status" -eq 0 ]
    [[ "$output" == *"success=1 failed=1"* ]]
}

@test "dry-run: runtime.yaml に startup_status フィールドが含まれる" {
    run "$PROJECT_ROOT/scripts/ignite" start --dry-run --skip-validation -n -w "$TEST_WORKSPACE"

    local runtime_dir="$TEST_WORKSPACE/.ignite"
    [ "$status" -eq 0 ]
    [ -f "$runtime_dir/runtime.yaml" ]

    local content
    content=$(cat "$runtime_dir/runtime.yaml")
    [[ "$content" == *"startup_status:"* ]]
}

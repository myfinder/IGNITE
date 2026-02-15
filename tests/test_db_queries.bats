#!/usr/bin/env bats
# =============================================================================
# SQLクエリ・フォールバックテスト
# テスト対象: scripts/utils/queue_monitor.sh の _generate_repo_report()
# =============================================================================

load 'test_helper'

setup() {
    setup_temp_dir
    export DB_PATH="$TEST_TEMP_DIR/state/memory.db"
    export WORKSPACE_DIR="$TEST_TEMP_DIR"
    export IGNITE_RUNTIME_DIR="$WORKSPACE_DIR"
    mkdir -p "$TEST_TEMP_DIR/state"

    # _generate_repo_report 関数を抽出して読み込み
    eval "$(sed -n '/^_generate_repo_report()/,/^}/p' "$UTILS_DIR/queue_monitor.sh")"

    # sqlite3 を隠した PATH（フォールバックテスト用）
    PATH_WITHOUT_SQLITE3=$(get_path_without_sqlite3)
}

teardown() {
    cleanup_temp_dir
}

# =============================================================================
# 正常系テスト
# =============================================================================

@test "_generate_repo_report: SQLite からタスクを取得して Markdown テーブル出力" {
    init_db_production_sequence "$DB_PATH"

    sqlite3 "$DB_PATH" "INSERT INTO tasks (task_id, assigned_to, status, title, repository) VALUES ('issue1_task_1', 'ignitian_1', 'in_progress', 'Fix bug', 'owner/repo');"
    sqlite3 "$DB_PATH" "INSERT INTO tasks (task_id, assigned_to, status, title, repository) VALUES ('issue1_task_2', 'ignitian_2', 'queued', 'Add feature', 'owner/repo');"
    sqlite3 "$DB_PATH" "INSERT INTO tasks (task_id, assigned_to, status, title, repository) VALUES ('issue2_task_1', 'ignitian_3', 'completed', 'Done task', 'owner/repo');"

    local result
    result=$(_generate_repo_report "owner/repo" "2025-01-01" "2025-01-01 12:00:00 JST")

    # in_progress タスクが含まれる
    [[ "$result" == *"issue1_task_1"* ]]
    [[ "$result" == *"Fix bug"* ]]

    # queued タスクも含まれる（status != 'completed' でフィルタ）
    [[ "$result" == *"issue1_task_2"* ]]

    # completed タスクは除外される
    [[ "$result" != *"Done task"* ]]
}

@test "_generate_repo_report: 他リポジトリのタスクは含まれない" {
    init_db_production_sequence "$DB_PATH"

    sqlite3 "$DB_PATH" "INSERT INTO tasks (task_id, assigned_to, status, title, repository) VALUES ('task_1', 'ignitian_1', 'in_progress', 'My task', 'owner/repo');"
    sqlite3 "$DB_PATH" "INSERT INTO tasks (task_id, assigned_to, status, title, repository) VALUES ('task_2', 'ignitian_2', 'in_progress', 'Other task', 'other/repo');"

    local result
    result=$(_generate_repo_report "owner/repo" "2025-01-01" "2025-01-01 12:00:00 JST")

    [[ "$result" == *"My task"* ]]
    [[ "$result" != *"Other task"* ]]
}

# =============================================================================
# 空結果テスト
# =============================================================================

@test "_generate_repo_report: 該当タスクなし → フォールバックメッセージ" {
    init_db_production_sequence "$DB_PATH"

    local result
    result=$(_generate_repo_report "owner/repo" "2025-01-01" "2025-01-01 12:00:00 JST")

    [[ "$result" == *"No tasks currently in progress"* ]]
}

# =============================================================================
# フォールバックテスト
# =============================================================================

@test "_generate_repo_report: sqlite3 不在時に dashboard.md からawk抽出" {
    # dashboard.md を作成
    cat > "$TEST_TEMP_DIR/dashboard.md" << 'DASH'
# Dashboard

## 現在のタスク
| Task | Status |
|------|--------|
| issue1_task_1 | in_progress |

## 完了タスク
DASH

    # sqlite3 だけを PATH から除外してレポート生成
    local result
    result=$(PATH="$PATH_WITHOUT_SQLITE3" _generate_repo_report "owner/repo" "2025-01-01" "2025-01-01 12:00:00 JST")

    [[ "$result" == *"issue1_task_1"* ]]
    [[ "$result" == *"in_progress"* ]]
}

@test "_generate_repo_report: DB なし + dashboard なし → フォールバックメッセージ" {
    # DB ファイルを削除（state ディレクトリは空のまま）
    rm -f "$DB_PATH"

    local result
    result=$(PATH="$PATH_WITHOUT_SQLITE3" _generate_repo_report "owner/repo" "2025-01-01" "2025-01-01 12:00:00 JST")

    [[ "$result" == *"No tasks currently in progress"* ]]
}

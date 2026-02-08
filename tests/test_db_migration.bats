#!/usr/bin/env bats
# =============================================================================
# v1→v2 マイグレーションのインテグレーションテスト
# テスト対象: scripts/schema_migrate.sh
# PR #178 のバグ（schema.sql が user_version=2 を先に設定しマイグレーションがスキップされる）
# を直接検知するテスト群
# =============================================================================

load 'test_helper'

setup() {
    setup_temp_dir
    export DB_PATH="$TEST_TEMP_DIR/state/memory.db"
}

teardown() {
    cleanup_temp_dir
}

# =============================================================================
# 本番初期化シーケンスによるアップグレード（最重要テスト）
# =============================================================================

@test "v1 DB → 本番init sequence → repository カラムが存在する" {
    # v1 DB を作成
    create_v1_db "$DB_PATH"

    # 本番と同じ初期化シーケンスを実行（schema.sql → WAL → schema_migrate.sh）
    # schema.sql の PRAGMA user_version=2 が先に設定されるため、
    # schema_migrate.sh がスキップされ、v1 DB にカラムが追加されない。
    # さらに CREATE INDEX idx_tasks_repo ON tasks(repository, ...) も失敗する。
    # このテストは PR #178 のバグを検知する：init_db_production_sequence が
    # エラーなしで完了し、かつ repository カラムが存在することを検証。
    run init_db_production_sequence "$DB_PATH"
    [[ "$status" -eq 0 ]]

    # repository カラムが存在することを確認
    local columns
    columns=$(get_columns "$DB_PATH" "tasks")

    [[ "$columns" == *"repository"* ]]
}

@test "v1 DB → 本番init sequence → issue_number カラムが存在する" {
    create_v1_db "$DB_PATH"
    run init_db_production_sequence "$DB_PATH"
    [[ "$status" -eq 0 ]]

    local columns
    columns=$(get_columns "$DB_PATH" "tasks")

    [[ "$columns" == *"issue_number"* ]]
}

@test "v1 DB → 本番init sequence → insight_log テーブルが存在する" {
    create_v1_db "$DB_PATH"
    run init_db_production_sequence "$DB_PATH"
    [[ "$status" -eq 0 ]]

    local count
    count=$(sqlite3 "$DB_PATH" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='insight_log';")
    [[ "$count" -eq 1 ]]
}

# =============================================================================
# schema_migrate.sh 単体テスト
# =============================================================================

@test "v1 DB → migration → 既存タスクに repository が設定される" {
    create_v1_db "$DB_PATH"

    sqlite3 "$DB_PATH" "INSERT INTO tasks (task_id, assigned_to, status) VALUES ('issue42_task_1', 'ignitian_1', 'in_progress');"

    bash "$SCRIPTS_DIR/schema_migrate.sh" "$DB_PATH"

    local repo
    repo=$(sqlite3 "$DB_PATH" "SELECT repository FROM tasks WHERE task_id='issue42_task_1';")
    [[ "$repo" == "myfinder/IGNITE" ]]
}

@test "v1 DB → migration → issue_number 抽出: issue123_task_1 → 123" {
    create_v1_db "$DB_PATH"
    sqlite3 "$DB_PATH" "INSERT INTO tasks (task_id, assigned_to, status) VALUES ('issue123_task_1', 'ignitian_1', 'queued');"

    bash "$SCRIPTS_DIR/schema_migrate.sh" "$DB_PATH"

    local num
    num=$(sqlite3 "$DB_PATH" "SELECT issue_number FROM tasks WHERE task_id='issue123_task_1';")
    [[ "$num" -eq 123 ]]
}

@test "v1 DB → migration → issue_number 抽出: issue5r2_task_1 → 5" {
    create_v1_db "$DB_PATH"
    sqlite3 "$DB_PATH" "INSERT INTO tasks (task_id, assigned_to, status) VALUES ('issue5r2_task_1', 'ignitian_1', 'queued');"

    bash "$SCRIPTS_DIR/schema_migrate.sh" "$DB_PATH"

    local num
    num=$(sqlite3 "$DB_PATH" "SELECT issue_number FROM tasks WHERE task_id='issue5r2_task_1';")
    [[ "$num" -eq 5 ]]
}

@test "v1 DB → migration → issue_number 抽出: task_1_issue100 → 100" {
    create_v1_db "$DB_PATH"
    sqlite3 "$DB_PATH" "INSERT INTO tasks (task_id, assigned_to, status) VALUES ('task_1_issue100', 'ignitian_1', 'queued');"

    bash "$SCRIPTS_DIR/schema_migrate.sh" "$DB_PATH"

    local num
    num=$(sqlite3 "$DB_PATH" "SELECT issue_number FROM tasks WHERE task_id='task_1_issue100';")
    [[ "$num" -eq 100 ]]
}

@test "v1 DB → migration → issue_number 抽出: task_99 → NULL" {
    create_v1_db "$DB_PATH"
    sqlite3 "$DB_PATH" "INSERT INTO tasks (task_id, assigned_to, status) VALUES ('task_99', 'ignitian_1', 'queued');"

    bash "$SCRIPTS_DIR/schema_migrate.sh" "$DB_PATH"

    local num
    num=$(sqlite3 "$DB_PATH" "SELECT issue_number FROM tasks WHERE task_id='task_99';")
    [[ -z "$num" ]]
}

@test "v1 DB → migration → user_version = 3" {
    create_v1_db "$DB_PATH"

    bash "$SCRIPTS_DIR/schema_migrate.sh" "$DB_PATH"

    local version
    version=$(get_user_version "$DB_PATH")
    [[ "$version" -eq 3 ]]
}

# =============================================================================
# 冪等性・復旧テスト
# =============================================================================

@test "マイグレーション冪等性: 2回実行してもエラーなし" {
    create_v1_db "$DB_PATH"

    run bash "$SCRIPTS_DIR/schema_migrate.sh" "$DB_PATH"
    [[ "$status" -eq 0 ]]

    run bash "$SCRIPTS_DIR/schema_migrate.sh" "$DB_PATH"
    [[ "$status" -eq 0 ]]
}

@test "部分マイグレーション復旧: repository だけ追加済み状態から再実行" {
    create_v1_db "$DB_PATH"

    # repository カラムだけ手動追加（部分的マイグレーション状態をシミュレート）
    sqlite3 "$DB_PATH" "ALTER TABLE tasks ADD COLUMN repository TEXT;"

    run bash "$SCRIPTS_DIR/schema_migrate.sh" "$DB_PATH"
    [[ "$status" -eq 0 ]]

    # issue_number カラムも追加されていること
    local columns
    columns=$(get_columns "$DB_PATH" "tasks")
    [[ "$columns" == *"issue_number"* ]]

    # user_version が 3 に更新されていること
    local version
    version=$(get_user_version "$DB_PATH")
    [[ "$version" -eq 3 ]]
}

@test "v2 DB → schema_migrate.sh → skip メッセージ" {
    init_db_production_sequence "$DB_PATH"

    run bash "$SCRIPTS_DIR/schema_migrate.sh" "$DB_PATH"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Already at version"* ]]
}

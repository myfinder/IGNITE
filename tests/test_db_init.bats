#!/usr/bin/env bats
# =============================================================================
# DB初期化シーケンスのインテグレーションテスト
# テスト対象: scripts/schema.sql + scripts/schema_migrate.sh
# 本番の cmd_start.sh と同じ順序で DB 初期化を実行し結果を検証
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
# 新規DB初期化テスト
# =============================================================================

@test "新規DB: テーブル全5個が作成される" {
    init_db_production_sequence "$DB_PATH"

    local tables
    tables=$(sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;")

    [[ "$tables" == *"agent_states"* ]]
    [[ "$tables" == *"insight_log"* ]]
    [[ "$tables" == *"memories"* ]]
    [[ "$tables" == *"strategist_state"* ]]
    [[ "$tables" == *"tasks"* ]]

    local count
    count=$(sqlite3 "$DB_PATH" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';")
    [[ "$count" -eq 5 ]]
}

@test "新規DB: tasks に repository カラムがある" {
    init_db_production_sequence "$DB_PATH"

    local columns
    columns=$(get_columns "$DB_PATH" "tasks")

    [[ "$columns" == *"repository"* ]]
}

@test "新規DB: tasks に issue_number カラムがある" {
    init_db_production_sequence "$DB_PATH"

    local columns
    columns=$(get_columns "$DB_PATH" "tasks")

    [[ "$columns" == *"issue_number"* ]]
}

@test "新規DB: user_version = 3" {
    init_db_production_sequence "$DB_PATH"

    local version
    version=$(get_user_version "$DB_PATH")

    [[ "$version" -eq 3 ]]
}

@test "新規DB: インデックス全7個が作成される" {
    init_db_production_sequence "$DB_PATH"

    local indices
    indices=$(sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%' ORDER BY name;")

    [[ "$indices" == *"idx_insight_log_repo"* ]]
    [[ "$indices" == *"idx_memories_agent_type"* ]]
    [[ "$indices" == *"idx_memories_repo_issue"* ]]
    [[ "$indices" == *"idx_memories_task"* ]]
    [[ "$indices" == *"idx_strategist_status"* ]]
    [[ "$indices" == *"idx_tasks_repo"* ]]
    [[ "$indices" == *"idx_tasks_status"* ]]

    local count
    count=$(sqlite3 "$DB_PATH" "SELECT count(*) FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%';")
    [[ "$count" -eq 7 ]]
}

@test "二重初期化: データが消えない" {
    init_db_production_sequence "$DB_PATH"

    sqlite3 "$DB_PATH" "INSERT INTO tasks (task_id, assigned_to, status, title) VALUES ('test_task_1', 'ignitian_1', 'in_progress', 'Test Task');"
    sqlite3 "$DB_PATH" "INSERT INTO memories (agent, type, content) VALUES ('leader', 'observation', 'test memory');"

    # 再初期化
    init_db_production_sequence "$DB_PATH"

    local task_count
    task_count=$(sqlite3 "$DB_PATH" "SELECT count(*) FROM tasks WHERE task_id='test_task_1';")
    [[ "$task_count" -eq 1 ]]

    local memory_count
    memory_count=$(sqlite3 "$DB_PATH" "SELECT count(*) FROM memories WHERE content='test memory';")
    [[ "$memory_count" -eq 1 ]]
}

@test "sqlite3 不在: schema_migrate.sh が正常終了する" {
    mkdir -p "$(dirname "$DB_PATH")"
    touch "$DB_PATH"

    local masked_path
    masked_path=$(get_path_without_sqlite3)

    run env PATH="$masked_path" bash "$SCRIPTS_DIR/schema_migrate.sh" "$DB_PATH"

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"sqlite3 not found"* ]]
}

-- IGNITE メモリデータベース スキーマ v1
-- アップグレードテスト用 fixture
-- v2 との差分: repository/issue_number カラムなし、insight_log テーブルなし
PRAGMA user_version = 1;

-- メモリテーブル（全エージェント共通）
CREATE TABLE IF NOT EXISTS memories (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    agent TEXT NOT NULL,
    type TEXT NOT NULL,
    content TEXT NOT NULL,
    context TEXT,
    task_id TEXT,
    timestamp DATETIME DEFAULT (datetime('now', '+9 hours'))
);

-- タスク状態テーブル（v1: repository/issue_number なし）
CREATE TABLE IF NOT EXISTS tasks (
    task_id TEXT PRIMARY KEY,
    assigned_to TEXT NOT NULL,
    delegated_by TEXT,
    status TEXT DEFAULT 'queued',
    title TEXT,
    started_at DATETIME,
    completed_at DATETIME
);

-- エージェント状態テーブル
CREATE TABLE IF NOT EXISTS agent_states (
    agent TEXT PRIMARY KEY,
    status TEXT,
    current_task_id TEXT,
    last_active DATETIME,
    summary TEXT
);

-- Strategist 戦略状態テーブル
CREATE TABLE IF NOT EXISTS strategist_state (
    request_id TEXT PRIMARY KEY,
    goal TEXT NOT NULL,
    status TEXT NOT NULL,
    created_at DATETIME,
    draft_strategy TEXT,
    reviews TEXT
);

-- v1 インデックス（idx_tasks_repo と idx_insight_log_repo なし）
CREATE INDEX IF NOT EXISTS idx_memories_agent_type ON memories(agent, type, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_memories_task ON memories(task_id);
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status, assigned_to);
CREATE INDEX IF NOT EXISTS idx_strategist_status ON strategist_state(status);

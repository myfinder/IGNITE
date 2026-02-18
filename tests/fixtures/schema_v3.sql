-- IGNITE メモリデータベース スキーマ v3
-- アップグレードテスト用 fixture
-- v4 との差分: tasks.dependencies カラムなし
PRAGMA user_version = 3;

-- memories テーブル（v3: repository/issue_number あり）
CREATE TABLE IF NOT EXISTS memories (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    agent TEXT NOT NULL,
    type TEXT NOT NULL,
    content TEXT NOT NULL,
    context TEXT,
    task_id TEXT,
    repository TEXT,
    issue_number INTEGER,
    timestamp DATETIME DEFAULT (datetime('now', '+9 hours'))
);

-- tasks テーブル（v3: repository/issue_number あり、dependencies なし）
CREATE TABLE IF NOT EXISTS tasks (
    task_id TEXT PRIMARY KEY,
    assigned_to TEXT NOT NULL,
    delegated_by TEXT,
    status TEXT DEFAULT 'queued',
    title TEXT,
    repository TEXT,
    issue_number INTEGER,
    started_at DATETIME,
    completed_at DATETIME
);

-- agent_states テーブル
CREATE TABLE IF NOT EXISTS agent_states (
    agent TEXT PRIMARY KEY,
    status TEXT,
    current_task_id TEXT,
    last_active DATETIME,
    summary TEXT
);

-- strategist_state テーブル
CREATE TABLE IF NOT EXISTS strategist_state (
    request_id TEXT PRIMARY KEY,
    goal TEXT NOT NULL,
    status TEXT NOT NULL,
    created_at DATETIME,
    draft_strategy TEXT,
    reviews TEXT
);

-- insight_log テーブル（v2+ で追加）
CREATE TABLE IF NOT EXISTS insight_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    memory_ids TEXT NOT NULL,
    repository TEXT NOT NULL,
    issue_number INTEGER,
    action TEXT NOT NULL,
    title TEXT,
    timestamp DATETIME DEFAULT (datetime('now', '+9 hours'))
);

-- インデックス
CREATE INDEX IF NOT EXISTS idx_memories_agent_type ON memories(agent, type, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_memories_task ON memories(task_id);
CREATE INDEX IF NOT EXISTS idx_memories_repo_issue ON memories(repository, issue_number, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status, assigned_to);
CREATE INDEX IF NOT EXISTS idx_tasks_repo ON tasks(repository, status);
CREATE INDEX IF NOT EXISTS idx_strategist_status ON strategist_state(status);
CREATE INDEX IF NOT EXISTS idx_insight_log_repo ON insight_log(repository);

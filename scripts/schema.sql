-- IGNITE メモリデータベース スキーマ
-- タイムスタンプは JST (UTC+9) で記録
-- NOTE: user_version は schema_migrate.sh が管理する（ここでは設定しない）

-- メモリテーブル（全エージェント共通：学習・決定・観察・エラーを記録）
CREATE TABLE IF NOT EXISTS memories (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    agent TEXT NOT NULL,
    type TEXT NOT NULL,         -- 'decision', 'learning', 'observation', 'error', 'message_sent', 'message_received'
    content TEXT NOT NULL,
    context TEXT,
    task_id TEXT,
    timestamp DATETIME DEFAULT (datetime('now', '+9 hours'))
);

-- タスク状態テーブル（進行中タスクの追跡）
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

-- エージェント状態テーブル（再起動復元用）
CREATE TABLE IF NOT EXISTS agent_states (
    agent TEXT PRIMARY KEY,
    status TEXT,
    current_task_id TEXT,
    last_active DATETIME,
    summary TEXT
);

-- Strategist 戦略状態テーブル（strategist_pending.yaml の代替）
CREATE TABLE IF NOT EXISTS strategist_state (
    request_id TEXT PRIMARY KEY,
    goal TEXT NOT NULL,
    status TEXT NOT NULL,       -- 'drafting', 'pending_reviews', 'completed'
    created_at DATETIME,
    draft_strategy TEXT,        -- JSON: 戦略ドラフト
    reviews TEXT                -- JSON: 各Sub-Leaderのレビュー状態
);

-- Insight ログテーブル（Memory Insights → Issue 起票の処理履歴）
CREATE TABLE IF NOT EXISTS insight_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    memory_ids TEXT NOT NULL,        -- JSON配列: 処理対象のmemory IDリスト [1, 5, 12]
    repository TEXT NOT NULL,        -- 起票先リポジトリ (owner/repo)
    issue_number INTEGER,            -- 起票したIssue番号 (NULLならcomment追加)
    action TEXT NOT NULL,            -- 'created' or 'commented'
    title TEXT,                      -- Issueタイトル
    timestamp DATETIME DEFAULT (datetime('now', '+9 hours'))
);

-- インデックス
CREATE INDEX IF NOT EXISTS idx_memories_agent_type ON memories(agent, type, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_memories_task ON memories(task_id);
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status, assigned_to);
-- NOTE: idx_tasks_repo は schema_migrate.sh が作成する（既存DBとの互換性のため）
CREATE INDEX IF NOT EXISTS idx_strategist_status ON strategist_state(status);
CREATE INDEX IF NOT EXISTS idx_insight_log_repo ON insight_log(repository);

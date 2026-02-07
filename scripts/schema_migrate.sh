#!/bin/bash
# schema_migrate.sh - 冪等なスキーママイグレーション
# PRAGMA user_version でバージョンを管理し、必要な場合のみ実行
set -e
set -u

DB_PATH="${1:-${WORKSPACE_DIR:-workspace}/state/memory.db}"

# リポジトリ名の動的取得（3段階フォールバック）
get_repository_name() {
    # 1. 環境変数 IGNITE_REPOSITORY（最優先、CI環境対応）
    if [[ -n "${IGNITE_REPOSITORY:-}" ]]; then
        if [[ ! "$IGNITE_REPOSITORY" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
            echo "[schema_migrate] WARNING: Invalid IGNITE_REPOSITORY format: $IGNITE_REPOSITORY" >&2
            # Tier 2にフォールスルー（環境変数を無視してgit remoteを試行）
        else
            echo "[schema_migrate] Using IGNITE_REPOSITORY env: $IGNITE_REPOSITORY" >&2
            echo "$IGNITE_REPOSITORY"
            return 0
        fi
    fi

    # 2. git remote get-url origin（HTTPS/SSH両対応）
    local url
    if url=$(git remote get-url origin 2>/dev/null); then
        url="${url%.git}"
        if [[ "$url" =~ github\.com[/:]([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)$ ]]; then
            echo "[schema_migrate] Detected repository from git remote: ${BASH_REMATCH[1]}" >&2
            echo "${BASH_REMATCH[1]}"
            return 0
        fi
    fi

    # 3. 最終フォールバック
    echo "[schema_migrate] WARNING: Could not detect repository name, using fallback 'myfinder/IGNITE'" >&2
    echo "myfinder/IGNITE"
}

if [[ ! -f "$DB_PATH" ]]; then
    echo "[schema_migrate] DB not found: $DB_PATH (skip)" >&2
    exit 0
fi

if ! command -v sqlite3 &>/dev/null; then
    echo "[schema_migrate] sqlite3 not found (skip)" >&2
    exit 0
fi

CURRENT_VERSION=$(sqlite3 "$DB_PATH" "PRAGMA user_version;")

if [[ "$CURRENT_VERSION" -ge 2 ]]; then
    echo "[schema_migrate] Already at version $CURRENT_VERSION (skip)" >&2
    exit 0
fi

echo "[schema_migrate] Migrating from version $CURRENT_VERSION to 2..." >&2

REPO_NAME=$(get_repository_name)

# カラム存在チェック（pragma_table_info）で冪等なALTER TABLE
HAS_REPO=$(sqlite3 "$DB_PATH" \
  "SELECT COUNT(*) FROM pragma_table_info('tasks') WHERE name='repository';")
HAS_ISSUE=$(sqlite3 "$DB_PATH" \
  "SELECT COUNT(*) FROM pragma_table_info('tasks') WHERE name='issue_number';")

if [[ "$HAS_REPO" -eq 0 ]]; then
    sqlite3 "$DB_PATH" "PRAGMA busy_timeout=5000; \
      ALTER TABLE tasks ADD COLUMN repository TEXT;"
    echo "[schema_migrate] Added column: repository" >&2
fi
if [[ "$HAS_ISSUE" -eq 0 ]]; then
    sqlite3 "$DB_PATH" "PRAGMA busy_timeout=5000; \
      ALTER TABLE tasks ADD COLUMN issue_number INTEGER;"
    echo "[schema_migrate] Added column: issue_number" >&2
fi

sqlite3 "$DB_PATH" <<SQL
PRAGMA busy_timeout = 5000;

-- 既存全行にデフォルトのリポジトリを設定
UPDATE tasks SET repository = '${REPO_NAME}' WHERE repository IS NULL;

-- パターン1,2: issue{N}_task_{M}, issue{N}_task{M}
-- パターン含む issue{N}p{P}_task_* (CASTが非数字で停止するため自動対応)
UPDATE tasks
  SET issue_number = CAST(substr(task_id, 6, instr(substr(task_id, 6), '_') - 1) AS INTEGER)
  WHERE task_id LIKE 'issue%' AND issue_number IS NULL;

-- パターン3: issue{N}r{R}_task_* (より正確な抽出で上書き)
UPDATE tasks
  SET issue_number = CAST(substr(task_id, 6, instr(substr(task_id, 6), 'r') - 1) AS INTEGER)
  WHERE task_id GLOB 'issue[0-9]*r[0-9]*_task_*';

-- パターン4: task_{M}_issue{N} (末尾からissue番号を抽出)
UPDATE tasks
  SET issue_number = CAST(substr(task_id, instr(task_id, '_issue') + 6) AS INTEGER)
  WHERE task_id LIKE 'task_%_issue%';

-- パターン5: task_{M} (issue番号なし → NULL のまま)
-- 何もしない（デフォルトがNULL）

-- インデックス作成
CREATE INDEX IF NOT EXISTS idx_tasks_repo ON tasks(repository, status);

-- バージョン更新
PRAGMA user_version = 2;
SQL

echo "[schema_migrate] Migration to version 2 completed successfully." >&2

#!/bin/bash
# backfill_memories.sh - 既存memoriesレコードの repository/issue_number バックフィル
# 冪等: WHERE repository IS NULL で未設定レコードのみ対象
# 2段階: (1) tasks JOIN, (2) task_id / context パターンマッチ
set -e
set -u

DB_PATH="${1:-${WORKSPACE_DIR:-workspace}/state/memory.db}"

# sqlite3 クエリ実行（PRAGMA busy_timeout の出力を抑制）
sql_query() {
    sqlite3 "$DB_PATH" ".timeout 5000" "$1"
}

if [[ ! -f "$DB_PATH" ]]; then
    echo "[backfill] DB not found: $DB_PATH (skip)" >&2
    exit 0
fi

if ! command -v sqlite3 &>/dev/null; then
    echo "[backfill] sqlite3 not found (skip)" >&2
    exit 0
fi

# repository カラム存在確認
HAS_COL=$(sql_query \
  "SELECT COUNT(*) FROM pragma_table_info('memories') WHERE name='repository';")
if [[ "$HAS_COL" -eq 0 ]]; then
    echo "[backfill] memories.repository column not found. Run schema_migrate.sh first." >&2
    exit 1
fi

TOTAL_BEFORE=$(sql_query "SELECT COUNT(*) FROM memories;")
NULL_BEFORE=$(sql_query "SELECT COUNT(*) FROM memories WHERE repository IS NULL;")

echo "[backfill] Starting backfill: total=$TOTAL_BEFORE, unfilled=$NULL_BEFORE" >&2

# ============================================================
# 段階1: tasks テーブル JOIN でバックフィル
# ============================================================
sqlite3 "$DB_PATH" <<'SQL'
PRAGMA busy_timeout = 5000;
BEGIN;

UPDATE memories SET
  repository = t.repository,
  issue_number = t.issue_number
FROM tasks t
WHERE memories.task_id = t.task_id
  AND memories.repository IS NULL
  AND t.repository IS NOT NULL;

COMMIT;
SQL

AFTER_STAGE1=$(sql_query "SELECT COUNT(*) FROM memories WHERE repository IS NULL;")
STAGE1_FILLED=$((NULL_BEFORE - AFTER_STAGE1))
echo "[backfill] Stage 1 (tasks JOIN): filled=$STAGE1_FILLED, remaining=$AFTER_STAGE1" >&2

# ============================================================
# 段階2: task_id / context パターンマッチ
# ============================================================
sqlite3 "$DB_PATH" <<'SQL'
PRAGMA busy_timeout = 5000;
BEGIN;

-- 段階2a: orphan task_id からの issue 番号抽出
-- パターン: issue_N... / issueN... → myfinder/IGNITE, issue N
UPDATE memories SET
  repository = 'myfinder/IGNITE',
  issue_number = CAST(
    CASE
      -- issueN... (issue直後が数字: issue174, issue124_fix 等)
      WHEN task_id GLOB 'issue[0-9]*' THEN
        substr(task_id, 6,
          CASE
            WHEN instr(substr(task_id, 6), '_') > 0
              THEN instr(substr(task_id, 6), '_') - 1
            WHEN instr(substr(task_id, 6), 'p') > 0
              THEN instr(substr(task_id, 6), 'p') - 1
            ELSE length(substr(task_id, 6))
          END
        )
      -- issue_N... (アンダースコア区切り: issue_174, issue_89 等)
      WHEN task_id LIKE 'issue\_%' ESCAPE '\' THEN
        substr(task_id, 7,
          CASE
            WHEN instr(substr(task_id, 7), '_') > 0
              THEN instr(substr(task_id, 7), '_') - 1
            ELSE length(substr(task_id, 7))
          END
        )
    END AS INTEGER)
WHERE repository IS NULL
  AND task_id IS NOT NULL
  AND task_id != ''
  AND (task_id LIKE 'issue\_%' ESCAPE '\' OR task_id GLOB 'issue[0-9]*');

-- パターン: readme_update 等 → myfinder/IGNITE, issue_number NULL
UPDATE memories SET
  repository = 'myfinder/IGNITE'
WHERE repository IS NULL
  AND task_id IS NOT NULL
  AND task_id != ''
  AND task_id NOT LIKE 'issue%'
  AND task_id NOT LIKE 'pr%';

-- パターン: prN... → myfinder/IGNITE, issue_number NULL
UPDATE memories SET
  repository = 'myfinder/IGNITE'
WHERE repository IS NULL
  AND task_id IS NOT NULL
  AND task_id != ''
  AND task_id LIKE 'pr%';

-- 段階2b: task_id NULL/空 レコードの context フィールド解析
-- パターン: 'owner/repo Issue #N' or 'owner/repo Issue N'
UPDATE memories SET
  repository = substr(context, 1, instr(context, ' Issue') - 1),
  issue_number = CAST(
    CASE
      WHEN context LIKE '% Issue #%'
        THEN substr(context, instr(context, ' Issue #') + 8,
          CASE
            WHEN instr(substr(context, instr(context, ' Issue #') + 8), ' ') > 0
              THEN instr(substr(context, instr(context, ' Issue #') + 8), ' ') - 1
            ELSE length(substr(context, instr(context, ' Issue #') + 8))
          END
        )
      WHEN context LIKE '% Issue %'
        THEN substr(context, instr(context, ' Issue ') + 7,
          CASE
            WHEN instr(substr(context, instr(context, ' Issue ') + 7), ' ') > 0
              THEN instr(substr(context, instr(context, ' Issue ') + 7), ' ') - 1
            ELSE length(substr(context, instr(context, ' Issue ') + 7))
          END
        )
    END AS INTEGER)
WHERE repository IS NULL
  AND context LIKE '%/%Issue%'
  AND context LIKE '%Issue %';

-- パターン: 'owner/repo PR #N'
UPDATE memories SET
  repository = substr(context, 1, instr(context, ' PR') - 1)
WHERE repository IS NULL
  AND context LIKE '%/% PR #%';

-- パターン: 'strategy_issueN_...' or 'strategy_YYYYMMDD_issueN...'
UPDATE memories SET
  repository = 'myfinder/IGNITE',
  issue_number = CAST(
    CASE
      WHEN context LIKE 'strategy_issue%'
        THEN substr(context, 15,
          CASE
            WHEN instr(substr(context, 15), '_') > 0
              THEN instr(substr(context, 15), '_') - 1
            ELSE length(substr(context, 15))
          END
        )
      WHEN context GLOB 'strategy_[0-9]*_issue*'
        THEN substr(context, instr(context, '_issue') + 6,
          CASE
            WHEN instr(substr(context, instr(context, '_issue') + 6), '_') > 0
              THEN instr(substr(context, instr(context, '_issue') + 6), '_') - 1
            ELSE length(substr(context, instr(context, '_issue') + 6))
          END
        )
    END AS INTEGER)
WHERE repository IS NULL
  AND context LIKE 'strategy_%issue%';

-- パターン: 'strategy_YYYYMMDDHHMMSS' (issue番号なし)
UPDATE memories SET
  repository = 'myfinder/IGNITE'
WHERE repository IS NULL
  AND context GLOB 'strategy_[0-9]*'
  AND context NOT LIKE '%issue%';

-- 段階2c: task_id が空文字列のレコード（contextにもパターンなし）
-- → myfinder/IGNITE をデフォルト設定
UPDATE memories SET
  repository = 'myfinder/IGNITE'
WHERE repository IS NULL
  AND (task_id = '' OR task_id IS NULL);

COMMIT;
SQL

AFTER_STAGE2=$(sql_query "SELECT COUNT(*) FROM memories WHERE repository IS NULL;")
STAGE2_FILLED=$((AFTER_STAGE1 - AFTER_STAGE2))
echo "[backfill] Stage 2 (pattern match): filled=$STAGE2_FILLED, remaining=$AFTER_STAGE2" >&2

# ============================================================
# 結果サマリー
# ============================================================
TOTAL_AFTER=$(sql_query "SELECT COUNT(*) FROM memories;")
TOTAL_FILLED=$((NULL_BEFORE - AFTER_STAGE2))

echo "[backfill] Summary: total_filled=$TOTAL_FILLED (stage1=$STAGE1_FILLED, stage2=$STAGE2_FILLED), skipped=$AFTER_STAGE2" >&2
echo "[backfill] Record count: before=$TOTAL_BEFORE, after=$TOTAL_AFTER (should be equal)" >&2

if [[ "$TOTAL_BEFORE" -ne "$TOTAL_AFTER" ]]; then
    echo "[backfill] ERROR: Record count mismatch! Data may be corrupted." >&2
    exit 1
fi

echo "[backfill] Backfill completed successfully." >&2

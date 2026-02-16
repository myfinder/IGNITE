#!/usr/bin/env bash
# =============================================================================
# テストヘルパー
# batsテスト用の共通セットアップとユーティリティ
# =============================================================================

# テスト用の一時ディレクトリを作成
setup_temp_dir() {
    export TEST_TEMP_DIR=$(mktemp -d)
    export XDG_CONFIG_HOME="$TEST_TEMP_DIR/config"
    export XDG_DATA_HOME="$TEST_TEMP_DIR/data"
    mkdir -p "$XDG_CONFIG_HOME"
    mkdir -p "$XDG_DATA_HOME"
}

# 一時ディレクトリをクリーンアップ
cleanup_temp_dir() {
    if [[ -n "${TEST_TEMP_DIR:-}" && -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

# プロジェクトルートを取得
get_project_root() {
    cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

# スクリプトのパスを取得
PROJECT_ROOT="$(get_project_root)"
SCRIPTS_DIR="$PROJECT_ROOT/scripts"
UTILS_DIR="$SCRIPTS_DIR/utils"

# =============================================================================
# DB テスト用ヘルパー
# =============================================================================

# cmd_start.sh L176-179 の初期化シーケンスを再現
init_db_production_sequence() {
    local db_path="${1:-$TEST_TEMP_DIR/state/memory.db}"
    mkdir -p "$(dirname "$db_path")"
    sqlite3 "$db_path" < "$SCRIPTS_DIR/schema.sql"
    sqlite3 "$db_path" "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;"
    bash "$SCRIPTS_DIR/schema_migrate.sh" "$db_path"
}

# v1 DB 作成（アップグレードテスト用）
create_v1_db() {
    local db_path="${1:-$TEST_TEMP_DIR/state/memory.db}"
    mkdir -p "$(dirname "$db_path")"
    sqlite3 "$db_path" < "$PROJECT_ROOT/tests/fixtures/schema_v1.sql"
}

# テーブルカラム名一覧を取得
get_columns() {
    sqlite3 "$1" "PRAGMA table_info($2);" | cut -d'|' -f2 | sort
}

# user_version 取得
get_user_version() {
    sqlite3 "$1" "PRAGMA user_version;"
}

# sqlite3 を隠した PATH を返す（他のコマンドは使える）
# sqlite3 と同じディレクトリの他コマンドへのシンボリックリンクを一時ディレクトリに作成
get_path_without_sqlite3() {
    local mask_dir="$TEST_TEMP_DIR/mask_sqlite3"
    mkdir -p "$mask_dir"

    # sqlite3 が含まれるディレクトリを特定
    local sqlite3_dirs=()
    local p
    while IFS= read -r -d: p || [[ -n "$p" ]]; do
        [[ -x "$p/sqlite3" ]] && sqlite3_dirs+=("$p")
    done <<< "$PATH"

    # sqlite3 があるディレクトリの他コマンドをシンボリックリンク
    for dir in "${sqlite3_dirs[@]}"; do
        for bin in "$dir"/*; do
            local name
            name=$(basename "$bin")
            [[ "$name" == "sqlite3" ]] && continue
            [[ -x "$bin" ]] || continue
            [[ -e "$mask_dir/$name" ]] || ln -s "$bin" "$mask_dir/$name"
        done
    done

    # PATH から sqlite3 を含むディレクトリを除外し、mask_dir を先頭に追加
    local new_path="$mask_dir"
    while IFS= read -r -d: p || [[ -n "$p" ]]; do
        local skip=false
        for dir in "${sqlite3_dirs[@]}"; do
            [[ "$p" == "$dir" ]] && skip=true && break
        done
        $skip || new_path="$new_path:$p"
    done <<< "$PATH"

    echo "$new_path"
}

# =============================================================================
# PTY ヘルパー（TTY 環境のシミュレーション）
# =============================================================================

# run_with_pty <command>
# PTY 経由でコマンドを実行し、TTY 接続時の挙動をテストする
run_with_pty() {
    local cmd="$1"
    python3 - "$cmd" <<'PY'
import os, pty, subprocess, sys
cmd = sys.argv[1]
env = os.environ.copy()
master, slave = pty.openpty()
proc = subprocess.Popen(cmd, shell=True, stdout=slave, stderr=slave, env=env)
os.close(slave)
chunks = []
try:
    while True:
        data = os.read(master, 4096)
        if not data:
            break
        chunks.append(data)
except OSError:
    pass
os.close(master)
proc.wait()
sys.stdout.buffer.write(b"".join(chunks))
sys.exit(proc.returncode)
PY
}

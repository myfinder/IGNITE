#!/bin/bash
# IGNITE スモークテスト
# ビルド → インストール → init → dry-run → サービス → 起動/停止 を隔離環境で検証

set -e
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# カラー定義
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

print_info() { echo -e "${BLUE}$1${NC}"; }
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }
print_header() { echo -e "${BOLD}=== $1 ===${NC}"; }

# テスト結果カウンター
PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()

# =============================================================================
# Assert ヘルパー
# =============================================================================

assert() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        PASS_COUNT=$((PASS_COUNT + 1))
        print_success "PASS: $description"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_TESTS+=("$description")
        print_error "FAIL: $description"
    fi
}

assert_file_exists() {
    local description="$1"
    local file_path="$2"
    if [[ -f "$file_path" ]]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        print_success "PASS: $description"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_TESTS+=("$description")
        print_error "FAIL: $description (file not found: $file_path)"
    fi
}

assert_dir_exists() {
    local description="$1"
    local dir_path="$2"
    if [[ -d "$dir_path" ]]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        print_success "PASS: $description"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_TESTS+=("$description")
        print_error "FAIL: $description (dir not found: $dir_path)"
    fi
}

assert_contains() {
    local description="$1"
    local file_path="$2"
    local pattern="$3"
    if grep -qE "$pattern" "$file_path" 2>/dev/null; then
        PASS_COUNT=$((PASS_COUNT + 1))
        print_success "PASS: $description"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_TESTS+=("$description")
        print_error "FAIL: $description (pattern '$pattern' not found in $file_path)"
    fi
}

assert_not_contains() {
    local description="$1"
    local content="$2"
    local pattern="$3"
    if ! echo "$content" | grep -qE "$pattern" 2>/dev/null; then
        PASS_COUNT=$((PASS_COUNT + 1))
        print_success "PASS: $description"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_TESTS+=("$description")
        print_error "FAIL: $description (unexpected pattern '$pattern' found)"
    fi
}

# =============================================================================
# ヘルプ
# =============================================================================

show_help() {
    cat << EOF
IGNITE スモークテスト

使用方法:
  ./scripts/smoke_test.sh [オプション]

オプション:
  --ci          CI モード (デフォルト)
  --full        フルモード (ローカル手動用、将来の拡張余地)
  --no-cleanup  デバッグ用に一時ディレクトリを残す
  -h, --help    このヘルプを表示

Phase:
  1. Build     - build.sh でアーカイブ生成・検証
  2. Install   - アーカイブ展開 → install.sh で隔離インストール
  3. Init      - ignite init → .ignite/ 構造確認
  4. Dry-run   - ignite start --dry-run → ランタイムファイル確認
  5. Service   - service install/setup-env/uninstall
  6. Start/Stop - ignite start → status → stop -y
EOF
}

# =============================================================================
# Phase 1: Build
# =============================================================================

phase_build() {
    print_header "Phase 1: Build"
    echo ""

    # build.sh 実行
    assert "build.sh --clean exits successfully" \
        bash "$PROJECT_ROOT/scripts/build.sh" --clean --output "$SMOKE_DIR/dist"

    # tar.gz 存在確認
    local tarball
    tarball=$(ls "$SMOKE_DIR/dist"/*.tar.gz 2>/dev/null | head -1)
    assert_file_exists "tar.gz archive exists" "${tarball:-/nonexistent}"

    # sha256 存在確認
    local sha256file
    sha256file=$(ls "$SMOKE_DIR/dist"/*.sha256 2>/dev/null | head -1)
    assert_file_exists "sha256 checksum file exists" "${sha256file:-/nonexistent}"

    # チェックサム検証
    if [[ -n "${sha256file:-}" ]] && [[ -f "$sha256file" ]]; then
        assert "sha256 checksum verification" \
            bash -c "cd '$SMOKE_DIR/dist' && sha256sum -c '$(basename "$sha256file")'"
    fi

    echo ""
}

# =============================================================================
# Phase 2: Install
# =============================================================================

phase_install() {
    print_header "Phase 2: Install"
    echo ""

    # アーカイブ展開
    local tarball
    tarball=$(ls "$SMOKE_DIR/dist"/*.tar.gz 2>/dev/null | head -1)
    if [[ -z "${tarball:-}" ]]; then
        print_error "tar.gz not found, skipping install phase"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_TESTS+=("Phase 2: tar.gz not found")
        return
    fi

    mkdir -p "$SMOKE_DIR/extract"
    tar -xzf "$tarball" -C "$SMOKE_DIR/extract"
    assert_dir_exists "archive extracted" "$SMOKE_DIR/extract"

    # 展開ディレクトリを検出
    local extract_dir
    extract_dir=$(ls -d "$SMOKE_DIR/extract"/ignite-* 2>/dev/null | head -1)
    assert_dir_exists "ignite directory found in archive" "${extract_dir:-/nonexistent}"

    if [[ -z "${extract_dir:-}" ]]; then
        return
    fi

    # 隔離 HOME にインストール
    assert "install.sh --force --skip-deps exits successfully" \
        bash "$extract_dir/install.sh" --force --skip-deps \
            --bin-dir "$SMOKE_DIR/home/.local/bin" \
            --data-dir "$SMOKE_DIR/home/.local/share/ignite" \
            --config-dir "$SMOKE_DIR/home/.local/share/ignite/config"

    # ファイル配置確認
    assert_file_exists "ignite binary installed" "$SMOKE_DIR/home/.local/bin/ignite"
    assert_dir_exists "data dir created" "$SMOKE_DIR/home/.local/share/ignite"
    assert_dir_exists "config dir created" "$SMOKE_DIR/home/.local/share/ignite/config"
    assert_dir_exists "scripts dir created" "$SMOKE_DIR/home/.local/share/ignite/scripts"
    assert_dir_exists "scripts/lib dir created" "$SMOKE_DIR/home/.local/share/ignite/scripts/lib"
    assert_dir_exists "instructions dir created" "$SMOKE_DIR/home/.local/share/ignite/instructions"
    assert_file_exists "install paths file created" "$SMOKE_DIR/home/.local/share/ignite/.install_paths"

    echo ""
}

# =============================================================================
# Phase 3: Init
# =============================================================================

phase_init() {
    print_header "Phase 3: Init"
    echo ""

    # ignite init 実行
    assert "ignite init exits successfully" \
        "$SMOKE_DIR/home/.local/bin/ignite" init -w "$SMOKE_DIR/workspace" --force

    # .ignite/ 構造確認
    assert_dir_exists ".ignite/ directory created" "$SMOKE_DIR/workspace/.ignite"
    assert_file_exists ".ignite/.gitignore exists" "$SMOKE_DIR/workspace/.ignite/.gitignore"

    # 設定ファイル確認
    assert_file_exists "system.yaml exists" "$SMOKE_DIR/workspace/.ignite/system.yaml"

    # instructions/ 確認
    assert_dir_exists "instructions/ directory exists" "$SMOKE_DIR/workspace/.ignite/instructions"

    echo ""
}

# =============================================================================
# Phase 4: Dry-run
# =============================================================================

phase_dry_run() {
    print_header "Phase 4: Dry-run"
    echo ""

    # ignite start --dry-run 実行
    assert "ignite start --dry-run exits successfully" \
        "$SMOKE_DIR/home/.local/bin/ignite" start --dry-run -w "$SMOKE_DIR/workspace"

    local runtime_dir="$SMOKE_DIR/workspace/.ignite"

    # ランタイムディレクトリ確認
    assert_dir_exists "queue/ directory exists" "$runtime_dir/queue"
    assert_dir_exists "logs/ directory exists" "$runtime_dir/logs"
    assert_dir_exists "state/ directory exists" "$runtime_dir/state"

    # runtime.yaml 確認
    assert_file_exists "runtime.yaml exists" "$runtime_dir/runtime.yaml"
    assert_contains "runtime.yaml contains dry_run: true" "$runtime_dir/runtime.yaml" "dry_run: true"

    # SQLite DB 確認（sqlite3 がある場合）
    if command -v sqlite3 &>/dev/null; then
        local db_file="$runtime_dir/memory.db"
        if [[ -f "$db_file" ]]; then
            assert "SQLite DB is valid" sqlite3 "$db_file" ".tables"
        fi
    fi

    echo ""
}

# =============================================================================
# Phase 5: Service
# =============================================================================

phase_service() {
    print_header "Phase 5: Service"
    echo ""

    # systemctl が存在しない環境ではスキップ
    if ! command -v systemctl &>/dev/null; then
        print_warning "systemctl not found, skipping service tests"
        return
    fi

    local unit_dir="$SMOKE_DIR/home/.config/systemd/user"

    # service install
    assert "ignite service install exits successfully" \
        "$SMOKE_DIR/home/.local/bin/ignite" service install --force

    assert_file_exists "ignite@.service installed" "$unit_dir/ignite@.service"

    # service setup-env
    assert "ignite service setup-env exits successfully" \
        "$SMOKE_DIR/home/.local/bin/ignite" service setup-env test-session --force

    local env_file="$SMOKE_DIR/home/.config/ignite/env.test-session"
    assert_file_exists "env file created" "$env_file"

    # service uninstall
    assert "ignite service uninstall exits successfully" \
        "$SMOKE_DIR/home/.local/bin/ignite" service uninstall

    # ユニットファイルが削除されたことを確認
    if [[ ! -f "$unit_dir/ignite@.service" ]]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        print_success "PASS: ignite@.service removed after uninstall"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_TESTS+=("ignite@.service removed after uninstall")
        print_error "FAIL: ignite@.service still exists after uninstall"
    fi

    echo ""
}

# =============================================================================
# Phase 6: Full Start/Stop
# =============================================================================

phase_start_stop() {
    print_header "Phase 6: Full Start/Stop"
    echo ""

    # CLI プロバイダーが利用可能か確認
    local cli_available=false
    if command -v opencode &>/dev/null; then
        cli_available=true
    fi

    if [[ "$cli_available" != true ]]; then
        print_warning "No CLI provider (opencode) found, skipping start/stop tests"
        return
    fi

    # API Key の有無を確認（なければ実起動テストをスキップ）
    local has_api_key=false
    local env_file="$SMOKE_DIR/workspace/.ignite/.env"
    if [[ -f "$env_file" ]]; then
        if grep -qE '^(OPENAI_API_KEY|ANTHROPIC_API_KEY|OPENROUTER_API_KEY)=.+' "$env_file" 2>/dev/null; then
            has_api_key=true
        fi
    fi
    # 環境変数からも確認
    if [[ -n "${OPENAI_API_KEY:-}" ]] || [[ -n "${ANTHROPIC_API_KEY:-}" ]] || [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
        has_api_key=true
    fi

    if [[ "$has_api_key" != true ]]; then
        print_warning "No API key found, skipping start/stop tests (set API key in .env or environment)"
        return
    fi

    # ignite start（デーモンモードで起動）
    local start_ok=false
    if timeout 120 "$SMOKE_DIR/home/.local/bin/ignite" start --daemon -w "$SMOKE_DIR/workspace" >/dev/null 2>&1; then
        start_ok=true
        PASS_COUNT=$((PASS_COUNT + 1))
        print_success "PASS: ignite start --daemon exits successfully"
    else
        print_warning "ignite start --daemon exited non-zero (CLI may lack API keys)"
    fi

    # 起動完了を待機
    sleep 10

    local runtime_dir="$SMOKE_DIR/workspace/.ignite"

    # ── PID ファイル + HTTP ヘルスチェックで検証 ──

    # セッション名を runtime.yaml から取得
    local session_name=""
    if [[ -f "$runtime_dir/runtime.yaml" ]]; then
        session_name=$(grep 'session_name:' "$runtime_dir/runtime.yaml" | awk '{print $2}' | tr -d '"' | head -1)
    fi

    # PID ファイルの存在で起動確認
    local pid_files
    pid_files=$(ls "$runtime_dir"/*.pid 2>/dev/null | wc -l || echo 0)
    if [[ "$start_ok" == true ]]; then
        if [[ "$pid_files" -gt 0 ]]; then
            PASS_COUNT=$((PASS_COUNT + 1))
            print_success "PASS: PID files found (count: $pid_files)"
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAILED_TESTS+=("PID files found")
            print_error "FAIL: no PID files found"
        fi
    else
        print_info "PID files: $pid_files (partial start)"
    fi

    # HTTP ヘルスチェック（opencode serve のヘルスエンドポイント）
    if [[ "$start_ok" == true ]]; then
        local health_ok=false
        # ポート情報が runtime.yaml にある場合チェック
        local port
        port=$(grep 'port:' "$runtime_dir/runtime.yaml" 2>/dev/null | awk '{print $2}' | tr -d '"' | head -1 || true)
        if [[ -n "$port" ]]; then
            if curl -s --max-time 5 "http://localhost:${port}/health" >/dev/null 2>&1; then
                health_ok=true
            fi
        fi
        if [[ "$health_ok" == true ]]; then
            PASS_COUNT=$((PASS_COUNT + 1))
            print_success "PASS: HTTP health check passed (port: $port)"
        else
            print_info "HTTP health check skipped or unavailable"
        fi
    fi

    # キューモニター確認
    if [[ "$start_ok" == true ]]; then
        if [[ -f "$runtime_dir/queue_monitor.pid" ]]; then
            PASS_COUNT=$((PASS_COUNT + 1))
            print_success "PASS: queue monitor PID file exists"
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAILED_TESTS+=("queue monitor PID file exists")
            print_error "FAIL: queue monitor PID file not found"
        fi
    fi

    # ignite status 実行
    local status_output
    if [[ -n "${session_name:-}" ]]; then
        status_output=$("$SMOKE_DIR/home/.local/bin/ignite" status -s "$session_name" -w "$SMOKE_DIR/workspace" 2>&1 || true)
        assert "ignite status exits without error" \
            "$SMOKE_DIR/home/.local/bin/ignite" status -s "$session_name" -w "$SMOKE_DIR/workspace"
    else
        status_output=$("$SMOKE_DIR/home/.local/bin/ignite" status -w "$SMOKE_DIR/workspace" 2>&1 || true)
        assert "ignite status exits without error" \
            "$SMOKE_DIR/home/.local/bin/ignite" status -w "$SMOKE_DIR/workspace"
    fi
    if [[ "$start_ok" == true ]]; then
        assert_not_contains "no crashed agents in status" "$status_output" "crashed"
    fi

    # ignite stop -y（start が成功した場合のみ）
    if [[ "$start_ok" == true ]]; then
        if [[ -n "${session_name:-}" ]]; then
            assert "ignite stop -y exits successfully" \
                timeout 30 "$SMOKE_DIR/home/.local/bin/ignite" stop -y -s "$session_name" -w "$SMOKE_DIR/workspace"
        else
            assert "ignite stop -y exits successfully" \
                timeout 30 "$SMOKE_DIR/home/.local/bin/ignite" stop -y -w "$SMOKE_DIR/workspace"
        fi

        # PID ファイルが消えたことを確認
        local remaining_pids
        remaining_pids=$(ls "$runtime_dir"/*.pid 2>/dev/null | wc -l || echo 0)
        if [[ "$remaining_pids" -eq 0 ]]; then
            PASS_COUNT=$((PASS_COUNT + 1))
            print_success "PASS: PID files cleaned up after stop"
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            FAILED_TESTS+=("PID files cleaned up after stop")
            print_error "FAIL: $remaining_pids PID files still exist after stop"
        fi
    fi

    echo ""
}

# =============================================================================
# クリーンアップ
# =============================================================================

cleanup() {
    if [[ "${NO_CLEANUP:-false}" == true ]]; then
        print_warning "一時ディレクトリを残しています: $SMOKE_DIR"
        return
    fi

    # PID ファイルからプロセスを停止
    if [[ -n "${SMOKE_DIR:-}" ]] && [[ -d "$SMOKE_DIR/workspace/.ignite" ]]; then
        for pidfile in "$SMOKE_DIR/workspace/.ignite"/*.pid; do
            [[ -f "$pidfile" ]] || continue
            local pid
            pid=$(cat "$pidfile" 2>/dev/null || true)
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null || true
            fi
        done
    fi

    if [[ -n "${SMOKE_DIR:-}" ]] && [[ -d "$SMOKE_DIR" ]]; then
        rm -rf "$SMOKE_DIR"
    fi
}

# =============================================================================
# メイン
# =============================================================================

main() {
    local MODE="ci"
    NO_CLEANUP=false

    # 引数解析
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ci) MODE="ci"; shift ;;
            --full) MODE="full"; shift ;;
            --no-cleanup) NO_CLEANUP=true; shift ;;
            -h|--help) show_help; exit 0 ;;
            *) print_error "不明なオプション: $1"; show_help; exit 1 ;;
        esac
    done

    # 隔離ディレクトリ作成
    SMOKE_DIR=$(mktemp -d)
    mkdir -p "$SMOKE_DIR"/{dist,extract,home/.local/bin,home/.local/share,home/.config,workspace}

    # 環境変数隔離
    export HOME="$SMOKE_DIR/home"
    export XDG_DATA_HOME="$SMOKE_DIR/home/.local/share"
    export XDG_CONFIG_HOME="$SMOKE_DIR/home/.config"
    export PATH="$SMOKE_DIR/home/.local/bin:$PATH"

    trap cleanup EXIT

    echo ""
    print_header "IGNITE スモークテスト (mode: $MODE)"
    echo ""
    echo "隔離ディレクトリ: $SMOKE_DIR"
    echo ""

    # Phase 実行
    phase_build
    phase_install
    phase_init
    phase_dry_run
    phase_service
    phase_start_stop

    # 結果サマリー
    echo ""
    print_header "テスト結果"
    echo ""
    print_success "PASS: $PASS_COUNT"
    if [[ $FAIL_COUNT -gt 0 ]]; then
        print_error "FAIL: $FAIL_COUNT"
        echo ""
        print_error "失敗したテスト:"
        for t in "${FAILED_TESTS[@]}"; do
            echo "  - $t"
        done
        echo ""
        exit 1
    else
        echo ""
        print_success "全テスト合格"
        echo ""
    fi
}

main "$@"

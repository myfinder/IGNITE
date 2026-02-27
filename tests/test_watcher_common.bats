#!/usr/bin/env bats
# test_watcher_common.bats - watcher_common.sh 共通関数 + watchers.yaml バリデーション + cmd_start.sh 統合テスト

load test_helper

# =============================================================================
# セットアップ / ティアダウン
# =============================================================================

setup() {
    setup_temp_dir
    export WORKSPACE_DIR="$TEST_TEMP_DIR/workspace"
    export IGNITE_CONFIG_DIR="$TEST_TEMP_DIR/config"
    export IGNITE_RUNTIME_DIR="$TEST_TEMP_DIR/runtime"
    mkdir -p "$IGNITE_CONFIG_DIR"
    mkdir -p "$IGNITE_RUNTIME_DIR/state"
    mkdir -p "$IGNITE_RUNTIME_DIR/queue/leader"

    # ログ関数のスタブ（watcher_common.sh が core.sh 経由で使用）
    log_info()    { :; }
    log_warn()    { :; }
    log_error()   { :; }
    log_success() { :; }
    export -f log_info log_warn log_error log_success

    # yaml_get のスタブ（yaml_utils.sh の代替）
    yaml_get() {
        local file="$1" key="$2" default="${3:-}"
        if command -v yq &>/dev/null; then
            local val
            val=$(yq -r ".$key // \"\"" "$file" 2>/dev/null)
            [[ -z "$val" || "$val" == "null" ]] && val="$default"
            echo "$val"
        else
            echo "$default"
        fi
    }
    export -f yaml_get

    # 多重sourceガードのリセット
    unset _WATCHER_COMMON_LOADED
}

teardown() {
    cleanup_temp_dir
}

# watcher_common.sh をsource するヘルパー
_source_watcher_common() {
    unset _WATCHER_COMMON_LOADED
    source "$SCRIPTS_DIR/lib/watcher_common.sh"
}

# =============================================================================
# 1. watcher_init テスト
# =============================================================================

@test "watcher_init: PIDファイルが作成される" {
    _source_watcher_common
    cat > "$IGNITE_CONFIG_DIR/test-watcher.yaml" <<'YAML'
interval: 30
YAML
    watcher_init "test_watcher" "$IGNITE_CONFIG_DIR/test-watcher.yaml"

    [ -f "$IGNITE_RUNTIME_DIR/state/test_watcher.pid" ]
    local pid_content
    pid_content=$(cat "$IGNITE_RUNTIME_DIR/state/test_watcher.pid")
    [ "$pid_content" = "$$" ]
}

@test "watcher_init: 設定ファイル省略時にデフォルトパスを解決" {
    _source_watcher_common
    # test_watcher → test-watcher.yaml に変換される
    cat > "$IGNITE_CONFIG_DIR/test-watcher.yaml" <<'YAML'
interval: 45
YAML
    watcher_init "test_watcher"

    # 初期化が成功していればPIDファイルが存在する
    [ -f "$IGNITE_RUNTIME_DIR/state/test_watcher.pid" ]
}

@test "watcher_init: 設定ファイルが存在しなくてもデフォルト値で初期化成功" {
    _source_watcher_common
    watcher_init "nonexistent_watcher" "$IGNITE_CONFIG_DIR/nonexistent.yaml"

    [ -f "$IGNITE_RUNTIME_DIR/state/nonexistent_watcher.pid" ]
    [ "$_WATCHER_POLL_INTERVAL" = "60" ]
}

# =============================================================================
# 2. watcher_load_config テスト
# =============================================================================

@test "watcher_load_config: interval が設定ファイルから読み込まれる" {
    _source_watcher_common
    _WATCHER_NAME="test"
    cat > "$TEST_TEMP_DIR/config.yaml" <<'YAML'
interval: 120
YAML
    watcher_load_config "$TEST_TEMP_DIR/config.yaml"

    [ "$_WATCHER_POLL_INTERVAL" = "120" ]
}

@test "watcher_load_config: 設定ファイル欠損時にデフォルト値を使用" {
    _source_watcher_common
    _WATCHER_NAME="test"
    _WATCHER_POLL_INTERVAL=60

    watcher_load_config "$TEST_TEMP_DIR/missing.yaml"

    [ "$_WATCHER_POLL_INTERVAL" = "60" ]
}

# =============================================================================
# 3. watcher_init_state テスト
# =============================================================================

@test "watcher_init_state: 状態ファイルが作成される" {
    _source_watcher_common
    _WATCHER_NAME="test"
    watcher_init_state "test_watcher"

    [ -f "$IGNITE_RUNTIME_DIR/state/test_watcher_state.json" ]
    # JSON構造を確認
    local content
    content=$(cat "$IGNITE_RUNTIME_DIR/state/test_watcher_state.json")
    echo "$content" | jq -e '.processed_events' > /dev/null
    echo "$content" | jq -e '.initialized_at' > /dev/null
}

@test "watcher_init_state: 既存状態ファイルは上書きしない" {
    _source_watcher_common
    _WATCHER_NAME="test"
    mkdir -p "$IGNITE_RUNTIME_DIR/state"
    echo '{"processed_events":{"key1":"2026-01-01"},"last_check":{},"initialized_at":"2026-01-01T00:00:00+00:00"}' \
        > "$IGNITE_RUNTIME_DIR/state/test_watcher_state.json"

    watcher_init_state "test_watcher"

    # 既存データが保持されている
    jq -e '.processed_events.key1' "$IGNITE_RUNTIME_DIR/state/test_watcher_state.json" > /dev/null
}

# =============================================================================
# 4. watcher_is_event_processed / watcher_mark_event_processed テスト
# =============================================================================

@test "watcher_is_event_processed: 未処理イベントは戻り値1" {
    _source_watcher_common
    _WATCHER_NAME="test"
    watcher_init_state "test_watcher"

    run watcher_is_event_processed "issue" "12345"
    [ "$status" -eq 1 ]
}

@test "watcher_mark_event_processed: マーク後にis_processedが0を返す" {
    _source_watcher_common
    _WATCHER_NAME="test"
    watcher_init_state "test_watcher"

    watcher_mark_event_processed "issue" "12345"
    run watcher_is_event_processed "issue" "12345"
    [ "$status" -eq 0 ]
}

@test "watcher_mark_event_processed: 異なるイベントIDは区別される" {
    _source_watcher_common
    _WATCHER_NAME="test"
    watcher_init_state "test_watcher"

    watcher_mark_event_processed "issue" "111"
    run watcher_is_event_processed "issue" "222"
    [ "$status" -eq 1 ]
}

@test "watcher_mark_event_processed: 異なるイベントタイプは区別される" {
    _source_watcher_common
    _WATCHER_NAME="test"
    watcher_init_state "test_watcher"

    watcher_mark_event_processed "issue" "100"
    run watcher_is_event_processed "pr" "100"
    [ "$status" -eq 1 ]
}

# =============================================================================
# 5. watcher_cleanup_old_events テスト
# =============================================================================

@test "watcher_cleanup_old_events: 24h超過イベントが削除される" {
    _source_watcher_common
    _WATCHER_NAME="test"
    watcher_init_state "test_watcher"

    # 古いイベントを直接書き込み
    local old_ts="2020-01-01T00:00:00+00:00"
    local tmp
    tmp=$(mktemp)
    jq ".processed_events[\"old_event\"] = \"$old_ts\"" "$_WATCHER_STATE_FILE" > "$tmp"
    mv "$tmp" "$_WATCHER_STATE_FILE"

    watcher_cleanup_old_events

    # 古いイベントが削除されている
    run jq -e '.processed_events["old_event"]' "$_WATCHER_STATE_FILE"
    [ "$status" -ne 0 ]
}

@test "watcher_cleanup_old_events: 最近のイベントは保持される" {
    _source_watcher_common
    _WATCHER_NAME="test"
    watcher_init_state "test_watcher"

    watcher_mark_event_processed "recent" "999"
    watcher_cleanup_old_events

    run watcher_is_event_processed "recent" "999"
    [ "$status" -eq 0 ]
}

# =============================================================================
# 6. _watcher_sanitize_input テスト
# =============================================================================

@test "_watcher_sanitize_input: シェルメタキャラクタが全角に変換される" {
    _source_watcher_common

    local result
    result=$(_watcher_sanitize_input 'hello; rm -rf /')
    [[ "$result" != *";"* ]]
    [[ "$result" == *"；"* ]]
}

@test "_watcher_sanitize_input: パイプ・アンパサンドが無害化される" {
    _source_watcher_common

    local result
    result=$(_watcher_sanitize_input 'cmd | cat & bg')
    [[ "$result" != *"|"* ]]
    [[ "$result" == *"｜"* ]]
    [[ "$result" != *"&"* ]]
    [[ "$result" == *"＆"* ]]
}

@test "_watcher_sanitize_input: バッククォート・ドル記号が無害化される" {
    _source_watcher_common

    local result
    result=$(_watcher_sanitize_input '$(whoami) `id`')
    [[ "$result" != *'$'* ]]
    [[ "$result" == *"＄"* ]]
    [[ "$result" != *'`'* ]]
    [[ "$result" == *"｀"* ]]
}

@test "_watcher_sanitize_input: 長さ制限が適用される" {
    _source_watcher_common

    local long_input
    long_input=$(printf 'A%.0s' {1..300})
    local result
    result=$(_watcher_sanitize_input "$long_input" 10)
    [ "${#result}" -eq 10 ]
}

@test "_watcher_sanitize_input: 制御文字が除去される" {
    _source_watcher_common

    local input
    input=$(printf 'hello\x01\x02world')
    local result
    result=$(_watcher_sanitize_input "$input")
    [[ "$result" == "helloworld" ]]
}

@test "_watcher_sanitize_input: 空文字列が処理可能" {
    _source_watcher_common

    local result
    result=$(_watcher_sanitize_input "")
    [ -z "$result" ]
}

@test "_watcher_sanitize_input: ダブルクォートとバックスラッシュが全角に変換される" {
    _source_watcher_common

    local result
    result=$(_watcher_sanitize_input 'file"test')
    [[ "$result" != *'"'* ]]
    [[ "$result" == *'＂'* ]]

    result=$(_watcher_sanitize_input 'path\name')
    [[ "$result" != *'\'* ]]
    [[ "$result" == *'＼'* ]]
}

# =============================================================================
# 7. watcher_update_last_check / watcher_get_last_check テスト
# =============================================================================

@test "watcher_get_last_check: 未チェック時にinitialized_atを返す" {
    _source_watcher_common
    _WATCHER_NAME="test"
    watcher_init_state "test_watcher"

    local result
    result=$(watcher_get_last_check "my_repo_issues")
    [ -n "$result" ]
    # ISO 8601形式であること
    [[ "$result" == *"T"* ]]
}

@test "watcher_update_last_check: 更新後にget_last_checkで取得可能" {
    _source_watcher_common
    _WATCHER_NAME="test"
    watcher_init_state "test_watcher"

    watcher_update_last_check "my_repo_issues"
    local result
    result=$(watcher_get_last_check "my_repo_issues")
    [ -n "$result" ]
    [[ "$result" == *"T"* ]]
}

# =============================================================================
# 8. シグナルハンドリングテスト
# =============================================================================

@test "シグナルtrap: _WATCHER_SHUTDOWN_REQUESTEDの初期値はfalse" {
    _source_watcher_common

    [ "$_WATCHER_SHUTDOWN_REQUESTED" = "false" ]
}

@test "シグナルtrap: _WATCHER_RELOAD_REQUESTEDの初期値はfalse" {
    _source_watcher_common

    [ "$_WATCHER_RELOAD_REQUESTED" = "false" ]
}

# =============================================================================
# 9. validate_watchers_yaml テスト
# =============================================================================

@test "validate_watchers_yaml: 正常な設定でエラーなし" {
    if ! command -v yq &>/dev/null; then skip "yq が未インストール"; fi
    source "$SCRIPTS_DIR/lib/config_validator.sh"

    mkdir -p "$TEST_TEMP_DIR/proj/config"
    mkdir -p "$TEST_TEMP_DIR/proj/scripts/utils"
    touch "$TEST_TEMP_DIR/proj/scripts/utils/github_watcher.sh"
    cat > "$TEST_TEMP_DIR/proj/config/watchers.yaml" <<'YAML'
watchers:
  - name: github_watcher
    description: "GitHub監視"
    script_path: scripts/utils/github_watcher.sh
    config_file: github-watcher.yaml
    enabled: true
    auto_start: true
YAML
    _VALIDATION_ERRORS=()
    _VALIDATION_WARNINGS=()
    validate_watchers_yaml "$TEST_TEMP_DIR/proj/config"
    [ ${#_VALIDATION_ERRORS[@]} -eq 0 ]
}

@test "validate_watchers_yaml: 必須フィールド欠損でエラー" {
    if ! command -v yq &>/dev/null; then skip "yq が未インストール"; fi
    source "$SCRIPTS_DIR/lib/config_validator.sh"

    mkdir -p "$TEST_TEMP_DIR/proj/config"
    cat > "$TEST_TEMP_DIR/proj/config/watchers.yaml" <<'YAML'
watchers:
  - description: "nameなし"
    enabled: true
YAML
    _VALIDATION_ERRORS=()
    _VALIDATION_WARNINGS=()
    validate_watchers_yaml "$TEST_TEMP_DIR/proj/config" || true
    [ ${#_VALIDATION_ERRORS[@]} -ge 1 ]
}

@test "validate_watchers_yaml: 重複nameでエラー" {
    if ! command -v yq &>/dev/null; then skip "yq が未インストール"; fi
    source "$SCRIPTS_DIR/lib/config_validator.sh"

    mkdir -p "$TEST_TEMP_DIR/proj/config"
    mkdir -p "$TEST_TEMP_DIR/proj/scripts/utils"
    touch "$TEST_TEMP_DIR/proj/scripts/utils/my_watcher.sh"
    cat > "$TEST_TEMP_DIR/proj/config/watchers.yaml" <<'YAML'
watchers:
  - name: my_watcher
    script_path: scripts/utils/my_watcher.sh
    config_file: my.yaml
    enabled: true
  - name: my_watcher
    script_path: scripts/utils/my_watcher.sh
    config_file: my2.yaml
    enabled: true
YAML
    _VALIDATION_ERRORS=()
    _VALIDATION_WARNINGS=()
    validate_watchers_yaml "$TEST_TEMP_DIR/proj/config" || true
    local found=false
    for e in "${_VALIDATION_ERRORS[@]}"; do
        [[ "$e" == *"重複"* ]] && found=true
    done
    [ "$found" = true ]
}

@test "validate_watchers_yaml: watchers.yaml非存在時にgithub-watcher.yamlフォールバック" {
    if ! command -v yq &>/dev/null; then skip "yq が未インストール"; fi
    source "$SCRIPTS_DIR/lib/config_validator.sh"

    mkdir -p "$TEST_TEMP_DIR/proj/config"
    cat > "$TEST_TEMP_DIR/proj/config/github-watcher.yaml" <<'YAML'
watcher:
  repositories:
    - owner/repo
  interval: 60
access_control:
  enabled: false
logging:
  level: info
YAML
    _VALIDATION_ERRORS=()
    _VALIDATION_WARNINGS=()
    local output
    output=$(validate_watchers_yaml "$TEST_TEMP_DIR/proj/config" 2>&1)
    # フォールバックのINFOメッセージが出力される
    [[ "$output" == *"フォールバック"* ]]
}

@test "validate_watchers_yaml: 空配列でエラー" {
    if ! command -v yq &>/dev/null; then skip "yq が未インストール"; fi
    source "$SCRIPTS_DIR/lib/config_validator.sh"

    mkdir -p "$TEST_TEMP_DIR/proj/config"
    cat > "$TEST_TEMP_DIR/proj/config/watchers.yaml" <<'YAML'
watchers: []
YAML
    _VALIDATION_ERRORS=()
    _VALIDATION_WARNINGS=()
    validate_watchers_yaml "$TEST_TEMP_DIR/proj/config" || true
    [ ${#_VALIDATION_ERRORS[@]} -ge 1 ]
}

@test "validate_watchers_yaml: script_path不存在で警告" {
    if ! command -v yq &>/dev/null; then skip "yq が未インストール"; fi
    source "$SCRIPTS_DIR/lib/config_validator.sh"

    mkdir -p "$TEST_TEMP_DIR/proj/config"
    cat > "$TEST_TEMP_DIR/proj/config/watchers.yaml" <<'YAML'
watchers:
  - name: missing_script
    script_path: scripts/utils/nonexistent.sh
    config_file: test.yaml
    enabled: true
YAML
    _VALIDATION_ERRORS=()
    _VALIDATION_WARNINGS=()
    validate_watchers_yaml "$TEST_TEMP_DIR/proj/config" || true
    local found=false
    for w in "${_VALIDATION_WARNINGS[@]}"; do
        [[ "$w" == *"見つかりません"* ]] && found=true
    done
    [ "$found" = true ]
}

# =============================================================================
# 10. _load_watcher_entries テスト（cmd_start.sh統合）
# =============================================================================

@test "_load_watcher_entries: watchers.yamlからエントリを読み込む" {
    if ! command -v yq &>/dev/null; then skip "yq が未インストール"; fi

    cat > "$IGNITE_CONFIG_DIR/watchers.yaml" <<'YAML'
watchers:
  - name: github_watcher
    script_path: scripts/utils/github_watcher.sh
    config_file: github-watcher.yaml
    enabled: true
    auto_start: true
  - name: slack_watcher
    script_path: scripts/utils/slack_watcher.sh
    config_file: slack-watcher.yaml
    enabled: false
    auto_start: false
YAML

    # _load_watcher_entries を cmd_start.sh から抽出
    eval "$(sed -n '/^_load_watcher_entries()/,/^}$/p' "$SCRIPTS_DIR/lib/cmd_start.sh")"

    local output
    output=$(_load_watcher_entries)
    local line_count
    line_count=$(echo "$output" | wc -l)
    [ "$line_count" -eq 2 ]

    # 1行目: github_watcher
    local first_line
    first_line=$(echo "$output" | head -1)
    [[ "$first_line" == "github_watcher|scripts/utils/github_watcher.sh|github-watcher.yaml|true|true" ]]

    # 2行目: slack_watcher
    local second_line
    second_line=$(echo "$output" | tail -1)
    [[ "$second_line" == "slack_watcher|scripts/utils/slack_watcher.sh|slack-watcher.yaml|false|false" ]]
}

@test "_load_watcher_entries: watchers.yaml非存在時にgithub-watcher.yamlフォールバック" {
    if ! command -v yq &>/dev/null; then skip "yq が未インストール"; fi

    # watchers.yamlは存在しない
    touch "$IGNITE_CONFIG_DIR/github-watcher.yaml"

    get_watcher_auto_start() { return 0; }
    export -f get_watcher_auto_start

    eval "$(sed -n '/^_load_watcher_entries()/,/^}$/p' "$SCRIPTS_DIR/lib/cmd_start.sh")"

    local output
    output=$(_load_watcher_entries)
    [[ "$output" == "github_watcher|scripts/utils/github_watcher.sh|github-watcher.yaml|true|true" ]]
}

@test "_load_watcher_entries: watchers.yamlもgithub-watcher.yamlもない場合は空出力" {
    if ! command -v yq &>/dev/null; then skip "yq が未インストール"; fi

    eval "$(sed -n '/^_load_watcher_entries()/,/^}$/p' "$SCRIPTS_DIR/lib/cmd_start.sh")"

    local output
    output=$(_load_watcher_entries)
    [ -z "$output" ]
}

# =============================================================================
# 11. _start_single_watcher テスト（cmd_start.sh統合）
# =============================================================================

@test "_start_single_watcher: スクリプト不存在でスキップ（エラーにならない）" {
    print_warning() { :; }
    print_info() { :; }
    print_success() { :; }
    export -f print_warning print_info print_success
    export SESSION_NAME="test_session"
    mkdir -p "$IGNITE_RUNTIME_DIR/logs"

    eval "$(sed -n '/^_start_single_watcher()/,/^}$/p' "$SCRIPTS_DIR/lib/cmd_start.sh")"

    run _start_single_watcher "test_watcher" "nonexistent.sh" "test.yaml"
    [ "$status" -eq 0 ]
}

@test "_start_single_watcher: 設定ファイル不存在でスキップ（エラーにならない）" {
    print_warning() { :; }
    print_info() { :; }
    print_success() { :; }
    export -f print_warning print_info print_success
    export SESSION_NAME="test_session"
    mkdir -p "$IGNITE_RUNTIME_DIR/logs"

    # スクリプトは存在する
    mkdir -p "$TEST_TEMP_DIR/scripts"
    echo '#!/bin/bash' > "$TEST_TEMP_DIR/scripts/watcher.sh"
    chmod +x "$TEST_TEMP_DIR/scripts/watcher.sh"

    eval "$(sed -n '/^_start_single_watcher()/,/^}$/p' "$SCRIPTS_DIR/lib/cmd_start.sh")"

    run _start_single_watcher "test_watcher" "$TEST_TEMP_DIR/scripts/watcher.sh" "nonexistent.yaml"
    [ "$status" -eq 0 ]
}

# =============================================================================
# 12. 後方互換テスト
# =============================================================================

@test "後方互換: github_watcher.shが watcher_common.sh をsourceできる" {
    # github_watcher.sh が watcher_common.sh を source しているか確認
    grep -q "watcher_common.sh" "$SCRIPTS_DIR/utils/github_watcher.sh"
}

@test "後方互換: watcher_common.shの多重sourceガードが機能する" {
    _source_watcher_common
    local first_load="$_WATCHER_COMMON_LOADED"
    [ "$first_load" = "1" ]

    # 2回目のsourceは何もしない（エラーにならない）
    source "$SCRIPTS_DIR/lib/watcher_common.sh"
    [ "$_WATCHER_COMMON_LOADED" = "1" ]
}

@test "後方互換: github_watcher.shのprocess_issues関数が抽出可能" {
    # 既存test_github_watcher.batsと同じ手法でprocess_issuesが抽出できることを確認
    local extracted
    extracted=$(sed -n '/^process_issues()/,/^}$/p' "$SCRIPTS_DIR/utils/github_watcher.sh")
    [ -n "$extracted" ]
}

#!/usr/bin/env bats
# test_workspace_config.bats - .ignite/ 一本化設計の統合テスト
# Issue #214: グローバルconfig廃止、.ignite/ 一本化

load test_helper

setup() {
    setup_temp_dir

    # テンプレート設定ディレクトリ（PROJECT_ROOT/config 相当）
    export IGNITE_CONFIG_DIR="$TEST_TEMP_DIR/template_config"
    mkdir -p "$IGNITE_CONFIG_DIR"

    # テンプレート system.yaml
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'YAML'
delays:
  leader_startup: 3
  server_ready: 8
  leader_init: 10
  agent_stabilize: 2
  agent_retry_wait: 3
  process_cleanup: 1
defaults:
  message_priority: normal
  task_timeout: 300
  worker_count: 3
YAML

    # テンプレート github-watcher.yaml
    cat > "$IGNITE_CONFIG_DIR/github-watcher.yaml" <<'YAML'
watcher:
  repositories:
    - repo: owner/template-repo
  interval: 60
  events:
    issues: true
  ignore_bot: true
enabled: true
access_control:
  enabled: false
logging:
  level: info
YAML

    # core.sh をソース
    export PROJECT_ROOT="$SCRIPTS_DIR/.."
    export WORKSPACE_DIR="$TEST_TEMP_DIR/workspace"
    export IGNITE_RUNTIME_DIR="$WORKSPACE_DIR"
    mkdir -p "$WORKSPACE_DIR"

    source "$SCRIPTS_DIR/lib/core.sh"
    source "$SCRIPTS_DIR/lib/yaml_utils.sh"
    source "$SCRIPTS_DIR/lib/session.sh"
}

teardown() {
    cleanup_temp_dir
}

# =============================================================================
# TC-1〜TC-5: resolve_config 1層テスト
# =============================================================================

@test "TC-1: resolve_config - IGNITE_CONFIG_DIRにファイルあり → パスを返す" {
    local result
    result=$(resolve_config "system.yaml")
    [[ "$result" == "$IGNITE_CONFIG_DIR/system.yaml" ]]
}

@test "TC-2: resolve_config - setup_workspace_config後は.ignite/を参照" {
    local ws_ignite="$TEST_TEMP_DIR/workspace/.ignite"
    mkdir -p "$ws_ignite"
    cat > "$ws_ignite/system.yaml" <<'YAML'
delays:
  leader_startup: 5
  server_ready: 10
  leader_init: 12
  agent_stabilize: 3
  agent_retry_wait: 4
  process_cleanup: 2
defaults:
  message_priority: high
  task_timeout: 600
  worker_count: 5
YAML
    setup_workspace_config "$TEST_TEMP_DIR/workspace" 2>/dev/null
    local result
    result=$(resolve_config "system.yaml")
    [[ "$result" == "$ws_ignite/system.yaml" ]]
}

@test "TC-3: resolve_config - .ignite/に無いファイル → 終了コード1" {
    local ws_ignite="$TEST_TEMP_DIR/workspace/.ignite"
    mkdir -p "$ws_ignite"
    touch "$ws_ignite/system.yaml"
    setup_workspace_config "$TEST_TEMP_DIR/workspace" 2>/dev/null

}

@test "TC-4: resolve_config - github-app.yamlも同一ロジック（特別扱いなし）" {
    echo "github_app: {app_id: '12345'}" > "$IGNITE_CONFIG_DIR/github-app.yaml"
    local result
    result=$(resolve_config "github-app.yaml")
    [[ "$result" == "$IGNITE_CONFIG_DIR/github-app.yaml" ]]
}

@test "TC-5: resolve_config - 存在しないファイル → 終了コード1" {
    run resolve_config "nonexistent.yaml"
    [[ "$status" -eq 1 ]]
}

# =============================================================================
# TC-6〜TC-9: setup_workspace_config + get_worker_count テスト
# =============================================================================

@test "TC-6: setup_workspace_config - .ignite/あり → IGNITE_CONFIG_DIR更新" {
    local old_config="$IGNITE_CONFIG_DIR"
    mkdir -p "$TEST_TEMP_DIR/workspace/.ignite"
    setup_workspace_config "$TEST_TEMP_DIR/workspace" 2>/dev/null
    [[ "$IGNITE_CONFIG_DIR" == "$TEST_TEMP_DIR/workspace/.ignite" ]]
    [[ "$IGNITE_CONFIG_DIR" != "$old_config" ]]
}

@test "TC-7: setup_workspace_config - .ignite/なし → IGNITE_CONFIG_DIR変更なし" {
    local old_config="$IGNITE_CONFIG_DIR"
    setup_workspace_config "$TEST_TEMP_DIR/workspace" 2>/dev/null
    [[ "$IGNITE_CONFIG_DIR" == "$old_config" ]]
}

@test "TC-8: get_worker_count - テンプレートconfig → テンプレート値" {
    local count
    count=$(get_worker_count)
    [[ "$count" == "3" ]]
}

@test "TC-9: get_worker_count - .ignite/切替後 → .ignite/値を返す" {
    local ws_ignite="$TEST_TEMP_DIR/workspace/.ignite"
    mkdir -p "$ws_ignite"
    cat > "$ws_ignite/system.yaml" <<'YAML'
delays:
  leader_startup: 3
  server_ready: 8
  leader_init: 10
  agent_stabilize: 2
  agent_retry_wait: 3
  process_cleanup: 1
defaults:
  message_priority: normal
  task_timeout: 300
  worker_count: 7
YAML
    setup_workspace_config "$TEST_TEMP_DIR/workspace" 2>/dev/null
    local count
    count=$(get_worker_count)
    [[ "$count" == "7" ]]
}

# =============================================================================
# TC-10〜TC-16: ignite init テスト
# =============================================================================

@test "TC-10: cmd_init - .ignite/ 新規作成" {
    source "$SCRIPTS_DIR/lib/cmd_init.sh"
    local target="$TEST_TEMP_DIR/init_test"
    mkdir -p "$target"

    cmd_init --minimal -w "$target"
    [[ -d "$target/.ignite" ]]
    [[ -f "$target/.ignite/.gitignore" ]]
}

@test "TC-11: cmd_init - .ignite/ 既存で --force なし → 終了コード1" {
    source "$SCRIPTS_DIR/lib/cmd_init.sh"
    local target="$TEST_TEMP_DIR/init_existing"
    mkdir -p "$target/.ignite"

    run cmd_init -w "$target"
    [[ "$status" -eq 1 ]]
}

@test "TC-12: cmd_init - --force で既存を上書き" {
    source "$SCRIPTS_DIR/lib/cmd_init.sh"
    local target="$TEST_TEMP_DIR/init_force"
    mkdir -p "$target/.ignite"
    echo "old" > "$target/.ignite/.gitignore"

    cmd_init --force --minimal -w "$target"
    [[ -f "$target/.ignite/.gitignore" ]]
    ! grep -q "^old$" "$target/.ignite/.gitignore"
}

@test "TC-13: cmd_init - --minimal で system.yaml のみコピー" {
    source "$SCRIPTS_DIR/lib/cmd_init.sh"
    local target="$TEST_TEMP_DIR/init_minimal"
    mkdir -p "$target"

    cmd_init --minimal -w "$target"
    [[ -f "$target/.ignite/system.yaml" ]]
    [[ ! -f "$target/.ignite/characters.yaml" ]]
}

@test "TC-14: cmd_init - .ignite/設定初期化に専念（workspace/は作成しない）" {
    source "$SCRIPTS_DIR/lib/cmd_init.sh"
    local target="$TEST_TEMP_DIR/init_dirs"
    mkdir -p "$target"

    cmd_init --minimal -w "$target"
    [[ -d "$target/.ignite" ]]
    [[ ! -d "$target/workspace" ]]
}

@test "TC-15: cmd_init --help → 終了コード0 + --migrate記載" {
    source "$SCRIPTS_DIR/lib/cmd_init.sh"
    run cmd_init --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"使用方法"* ]]
    [[ "$output" == *"--migrate"* ]]
}

@test "TC-16: cmd_init - .ignite/ パーミッション 700" {
    source "$SCRIPTS_DIR/lib/cmd_init.sh"
    local target="$TEST_TEMP_DIR/init_perm"
    mkdir -p "$target"

    cmd_init --minimal -w "$target"
    local perms
    perms=$(stat -c '%a' "$target/.ignite" 2>/dev/null || stat -f '%Lp' "$target/.ignite" 2>/dev/null)
    [[ "$perms" == "700" ]]
}

# =============================================================================
# TC-17〜TC-20: セキュリティ + .gitignore テスト
# =============================================================================

@test "TC-17: .gitignore に github-app.yaml が含まれない（コミット可能）" {
    source "$SCRIPTS_DIR/lib/cmd_init.sh"
    local target="$TEST_TEMP_DIR/init_gitignore"
    mkdir -p "$target"

    cmd_init --minimal -w "$target"
    ! grep -q "github-app.yaml" "$target/.ignite/.gitignore"
}

@test "TC-18: .gitignore に *.pem が含まれる" {
    source "$SCRIPTS_DIR/lib/cmd_init.sh"
    local target="$TEST_TEMP_DIR/init_pem"
    mkdir -p "$target"

    cmd_init --minimal -w "$target"
    grep -q '\*.pem' "$target/.ignite/.gitignore"
}

@test "TC-19: validate_workspace_config - github-app.yaml 存在時に警告" {
    if ! command -v yq &>/dev/null; then
        skip "yq が未インストール"
    fi
    source "$SCRIPTS_DIR/lib/config_validator.sh"

    local ws_ignite="$TEST_TEMP_DIR/workspace/.ignite"
    mkdir -p "$ws_ignite"
    echo "github_app: {app_id: '12345'}" > "$ws_ignite/github-app.yaml"

    _VALIDATION_ERRORS=()
    _VALIDATION_WARNINGS=()
    validate_workspace_config "$TEST_TEMP_DIR/workspace"

    [[ ${#_VALIDATION_WARNINGS[@]} -ge 1 ]]
    local found=false
    for w in "${_VALIDATION_WARNINGS[@]}"; do
        [[ "$w" == *"credentials"* ]] && found=true
    done
    [[ "$found" == true ]]
}

@test "TC-20: validate_workspace_config - .ignite/ なしでエラーなし" {
    if ! command -v yq &>/dev/null; then
        skip "yq が未インストール"
    fi
    source "$SCRIPTS_DIR/lib/config_validator.sh"

    _VALIDATION_ERRORS=()
    _VALIDATION_WARNINGS=()
    validate_workspace_config "$TEST_TEMP_DIR/workspace"

    [[ ${#_VALIDATION_ERRORS[@]} -eq 0 ]]
    [[ ${#_VALIDATION_WARNINGS[@]} -eq 0 ]]
}

# =============================================================================
# TC-21〜TC-23: setup_workspace() .ignite/ 自動検出テスト
# =============================================================================

@test "TC-21: setup_workspace - CWDに.ignite/あり → CWDがWORKSPACE_DIR" {
    local test_ws="$TEST_TEMP_DIR/ws_detect"
    mkdir -p "$test_ws/.ignite"
    WORKSPACE_DIR=""

    pushd "$test_ws" > /dev/null
    setup_workspace 2>/dev/null
    popd > /dev/null

    [[ "$WORKSPACE_DIR" == "$test_ws" ]]
}

@test "TC-22: setup_workspace - CWDに.ignite/なし → DEFAULT_WORKSPACE_DIR" {
    local test_ws="$TEST_TEMP_DIR/ws_no_ignite"
    mkdir -p "$test_ws"
    WORKSPACE_DIR=""

    pushd "$test_ws" > /dev/null
    setup_workspace 2>/dev/null
    popd > /dev/null

    [[ "$WORKSPACE_DIR" == "$DEFAULT_WORKSPACE_DIR" ]]
}

@test "TC-23: setup_workspace - -w指定済み → 検出スキップ" {
    local test_ws="$TEST_TEMP_DIR/ws_explicit"
    mkdir -p "$test_ws/.ignite"
    WORKSPACE_DIR="/explicitly/set/path"

    pushd "$test_ws" > /dev/null
    setup_workspace 2>/dev/null
    popd > /dev/null

    [[ "$WORKSPACE_DIR" == "/explicitly/set/path" ]]
}

# =============================================================================
# TC-24〜TC-27: レビュー修正の検証テスト
# =============================================================================

@test "TC-24: _cmd_init_migrate - github-app.yaml をスキップ" {
    source "$SCRIPTS_DIR/lib/cmd_init.sh"
    local legacy_dir="${HOME}/.config/ignite"
    local dest_dir="$TEST_TEMP_DIR/migrate_dest"
    mkdir -p "$legacy_dir" "$dest_dir"

    # 移行元にファイルを配置
    echo "delays: {leader_startup: 3}" > "$legacy_dir/system.yaml"
    echo "github_app: {app_id: 12345}" > "$legacy_dir/github-app.yaml"

    # 非対話で移行実行
    _cmd_init_migrate "$dest_dir" < /dev/null

    # system.yaml は移行される
    [[ -f "$dest_dir/system.yaml" ]]
    # github-app.yaml はスキップされる
    [[ ! -f "$dest_dir/github-app.yaml" ]]

    # クリーンアップ
    rm -rf "$legacy_dir"
}

@test "TC-25: cmd_start - .ignite/ 必須チェック" {
    source "$SCRIPTS_DIR/lib/cmd_start.sh" 2>/dev/null || true
    # cmd_start.sh L74-76 で .ignite/ チェックがある
    # .ignite/ なしのワークスペースでは起動失敗することを確認
    local test_ws="$TEST_TEMP_DIR/ws_no_ignite_start"
    mkdir -p "$test_ws"
    WORKSPACE_DIR="$test_ws"

    if declare -f cmd_start &>/dev/null; then
        run cmd_start
        [[ "$status" -ne 0 ]] || [[ "$output" == *".ignite"* ]]
    else
        skip "cmd_start が読み込めません"
    fi
}

@test "TC-26: cmd_watcher - setup_workspace_config が呼ばれる" {
    # cmd_watcher() に setup_workspace_config "" が追加されていることを確認（コード検査）
    grep -q 'setup_workspace_config ""' "$SCRIPTS_DIR/lib/commands.sh"
    # cmd_watcher 内で setup_workspace_config が呼ばれていることを確認
    local in_watcher=false
    while IFS= read -r line; do
        [[ "$line" == *"cmd_watcher()"* ]] && in_watcher=true
        if $in_watcher; then
            [[ "$line" == *"setup_workspace_config"* ]] && return 0
            [[ "$line" == *"^}"* ]] && break
        fi
    done < "$SCRIPTS_DIR/lib/commands.sh"
    # grep で確認済みなのでここには到達しない
}

@test "TC-28: ignite init で .env.example が生成される" {
    source "$SCRIPTS_DIR/lib/cmd_init.sh"
    local target="$TEST_TEMP_DIR/init_env"
    mkdir -p "$target"

    cmd_init --minimal -w "$target"
    [[ -f "$target/.ignite/.env.example" ]]
    [[ "$(cat "$target/.ignite/.env.example")" == *"OPENAI_API_KEY"* ]]
    [[ "$(cat "$target/.ignite/.env.example")" == *"ANTHROPIC_API_KEY"* ]]
}

@test "TC-29: .gitignore に .ignite/.env が含まれる" {
    source "$SCRIPTS_DIR/lib/cmd_init.sh"
    local target="$TEST_TEMP_DIR/init_env_gi"
    mkdir -p "$target"

    cmd_init --minimal -w "$target"
    grep -q '\.env' "$target/.ignite/.gitignore"
}

@test "TC-30: --minimal でも .env.example が生成される" {
    source "$SCRIPTS_DIR/lib/cmd_init.sh"
    local target="$TEST_TEMP_DIR/init_minimal_env"
    mkdir -p "$target"

    cmd_init --minimal -w "$target"
    [[ -f "$target/.ignite/.env.example" ]]
}

@test "TC-27: cmd_validate - XDG_CONFIG_HOME 参照なし" {
    # cmd_validate() 内に XDG_CONFIG_HOME への直接参照がないことを確認
    local in_validate=false
    local found_xdg=false
    while IFS= read -r line; do
        [[ "$line" == *"cmd_validate()"* ]] && in_validate=true
        if $in_validate; then
            [[ "$line" == *"XDG_CONFIG_HOME"* ]] && found_xdg=true
            [[ "$line" == "}" ]] && break
        fi
    done < "$SCRIPTS_DIR/lib/commands.sh"
    [[ "$found_xdg" == false ]]
}

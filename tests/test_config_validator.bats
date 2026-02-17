#!/usr/bin/env bats
# test_config_validator.bats - 設定バリデーション テスト

load test_helper

setup() {
    setup_temp_dir
    # config_validator.sh は yq が必要
    if ! command -v yq &>/dev/null; then
        skip "yq が未インストール"
    fi
    source "$SCRIPTS_DIR/lib/config_validator.sh"
}

teardown() {
    cleanup_temp_dir
}

# --- validate_array_min ---

@test "validate_array_min: 空配列でエラー検出" {
    cat > "$TEST_TEMP_DIR/test.yaml" <<'YAML'
items: []
YAML
    _VALIDATION_ERRORS=()
    validate_array_min "$TEST_TEMP_DIR/test.yaml" ".items" 1 || true
    [[ ${#_VALIDATION_ERRORS[@]} -eq 1 ]]
    [[ "${_VALIDATION_ERRORS[0]}" == *"要素数が不足"* ]]
}

@test "validate_array_min: 要素ありでエラーなし" {
    cat > "$TEST_TEMP_DIR/test.yaml" <<'YAML'
items:
  - item1
YAML
    _VALIDATION_ERRORS=()
    validate_array_min "$TEST_TEMP_DIR/test.yaml" ".items" 1
    [[ ${#_VALIDATION_ERRORS[@]} -eq 0 ]]
}

# --- validate_required ---

@test "validate_required: 未設定フィールドでエラー検出" {
    cat > "$TEST_TEMP_DIR/test.yaml" <<'YAML'
other_field: value
YAML
    _VALIDATION_ERRORS=()
    validate_required "$TEST_TEMP_DIR/test.yaml" ".missing_field" || true
    [[ ${#_VALIDATION_ERRORS[@]} -eq 1 ]]
    [[ "${_VALIDATION_ERRORS[0]}" == *"必須フィールドが未設定"* ]]
}

# --- validate_enum ---

@test "validate_enum: 許可外の値でエラー検出" {
    cat > "$TEST_TEMP_DIR/test.yaml" <<'YAML'
level: invalid
YAML
    _VALIDATION_ERRORS=()
    validate_enum "$TEST_TEMP_DIR/test.yaml" ".level" debug info warn error || true
    [[ ${#_VALIDATION_ERRORS[@]} -eq 1 ]]
    [[ "${_VALIDATION_ERRORS[0]}" == *"許可されていない値"* ]]
}

# --- validate_watcher_yaml 複合テスト ---

@test "validate_watcher_yaml: allowed_users空配列でエラーメッセージのフォーマット確認" {
    cat > "$TEST_TEMP_DIR/watcher.yaml" <<'YAML'
watcher:
  repositories:
    - owner/repo
  interval: 60
  events:
    issues: true
  ignore_bot: true
access_control:
  enabled: true
  allowed_users: []
logging:
  level: info
YAML
    _VALIDATION_ERRORS=()
    _VALIDATION_WARNINGS=()
    validate_watcher_yaml "$TEST_TEMP_DIR/watcher.yaml" || true
    [[ ${#_VALIDATION_ERRORS[@]} -ge 1 ]]
    # エラーメッセージに要素数不足が含まれる
    local found=false
    for e in "${_VALIDATION_ERRORS[@]}"; do
        [[ "$e" == *"allowed_users"*"要素数が不足"* ]] && found=true
    done
    [[ "$found" == true ]]
}

@test "validate_watcher_yaml: 複数エラーが全て蓄積される" {
    cat > "$TEST_TEMP_DIR/watcher.yaml" <<'YAML'
watcher:
  repositories: []
  interval: 5
access_control:
  enabled: true
  allowed_users: []
logging:
  level: invalid_level
YAML
    _VALIDATION_ERRORS=()
    _VALIDATION_WARNINGS=()
    validate_watcher_yaml "$TEST_TEMP_DIR/watcher.yaml" || true
    # repositories空 + interval範囲外 + allowed_users空 + level不正 = 最低3件以上
    [[ ${#_VALIDATION_ERRORS[@]} -ge 3 ]]
}

# --- set -e 互換テスト ---

@test "set -e 有効時にバリデーションエラーでサイレント終了しない" {
    cat > "$TEST_TEMP_DIR/watcher.yaml" <<'YAML'
watcher:
  repositories:
    - owner/repo
  interval: 60
access_control:
  enabled: true
  allowed_users: []
YAML
    _VALIDATION_ERRORS=()
    _VALIDATION_WARNINGS=()
    # set -e を有効にした状態で || true 付きで呼び出し
    set -e
    validate_watcher_yaml "$TEST_TEMP_DIR/watcher.yaml" || true
    # ここに到達すること自体が成功（サイレント終了していない）
    [[ ${#_VALIDATION_ERRORS[@]} -ge 1 ]]
    set +e
}

# --- validate_all_configs ---

@test "validate_all_configs: エラーありでもレポートが出力される" {
    mkdir -p "$TEST_TEMP_DIR/config"
    cat > "$TEST_TEMP_DIR/config/system.yaml" <<'YAML'
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
  worker_count: 2
YAML
    mkdir -p "$TEST_TEMP_DIR/xdg"
    cat > "$TEST_TEMP_DIR/xdg/github-watcher.yaml" <<'YAML'
watcher:
  repositories:
    - owner/repo
  interval: 60
access_control:
  enabled: true
  allowed_users: []
logging:
  level: info
YAML
    local output
    output=$(validate_all_configs "$TEST_TEMP_DIR/config" "$TEST_TEMP_DIR/xdg" 2>&1) || true
    # エラー件数が報告される
    [[ "$output" == *"エラー:"* ]] || [[ "$output" == *"ERROR"* ]]
}

# --- --skip-validation フラグ確認 ---

@test "skip_validation: cmd_start.sh にオプションが存在する" {
    grep -q "skip-validation" "$SCRIPTS_DIR/lib/cmd_start.sh"
}

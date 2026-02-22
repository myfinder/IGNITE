#!/usr/bin/env bats
# =============================================================================
# cli_provider.sh テスト
# テスト対象: scripts/lib/cli_provider.sh + プロバイダー実装
# =============================================================================

load 'test_helper'

setup() {
    setup_temp_dir

    # テスト用の IGNITE_CONFIG_DIR を一時ディレクトリに設定
    export IGNITE_CONFIG_DIR="$TEST_TEMP_DIR/config_dir"
    mkdir -p "$IGNITE_CONFIG_DIR"

    # 最小限の system.yaml を作成
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
defaults:
  message_priority: normal
EOF

    # core.sh を source（cli_provider.sh は core.sh から自動読み込み）
    source "$SCRIPTS_DIR/lib/core.sh"
}

teardown() {
    cleanup_temp_dir
}

# =============================================================================
# cli_load_config
# =============================================================================

@test "cli_load_config: cli: セクションなしでデフォルト opencode" {
    cli_load_config
    [ "$CLI_PROVIDER" = "opencode" ]
    [ "$CLI_COMMAND" = "opencode" ]
}

@test "cli_load_config: provider=opencode を正しく読み込み" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: opencode
  model: openai/o3
EOF
    cli_load_config
    [ "$CLI_PROVIDER" = "opencode" ]
    [ "$CLI_MODEL" = "openai/o3" ]
    [ "$CLI_COMMAND" = "opencode" ]
}

@test "cli_load_config: provider=claude を正しく読み込み" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: claude
  model: claude-sonnet-4-20250514
EOF
    cli_load_config
    [ "$CLI_PROVIDER" = "claude" ]
    [ "$CLI_MODEL" = "claude-sonnet-4-20250514" ]
    [ "$CLI_COMMAND" = "claude" ]
}

@test "cli_load_config: provider=codex を正しく読み込み" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: codex
  model: gpt-5.2-codex
EOF
    cli_load_config
    [ "$CLI_PROVIDER" = "codex" ]
    [ "$CLI_MODEL" = "gpt-5.2-codex" ]
    [ "$CLI_COMMAND" = "codex" ]
}

@test "cli_load_config: 不正な provider で opencode にフォールバック" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: invalid_provider
  model: openai/o3
EOF
    cli_load_config
    [ "$CLI_PROVIDER" = "opencode" ]
}

# =============================================================================
# cli_get_process_names
# =============================================================================

@test "cli_get_process_names: opencode は 'opencode node' を返す" {
    cli_load_config
    local names
    names=$(cli_get_process_names)
    [[ "$names" == "opencode node" ]]
}

@test "cli_get_process_names: claude は 'claude node' を返す" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: claude
  model: claude-sonnet-4-20250514
EOF
    cli_load_config
    local names
    names=$(cli_get_process_names)
    [[ "$names" == "claude node" ]]
}

@test "cli_get_process_names: codex は 'codex node' を返す" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: codex
  model: gpt-5.2-codex
EOF
    cli_load_config
    local names
    names=$(cli_get_process_names)
    [[ "$names" == "codex node" ]]
}

# =============================================================================
# cli_get_process_pattern
# =============================================================================

@test "cli_get_process_pattern: opencode は 'opencode' を返す" {
    cli_load_config
    local pattern
    pattern=$(cli_get_process_pattern)
    [[ "$pattern" == "opencode" ]]
}

@test "cli_get_process_pattern: claude は 'claude' を返す" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: claude
  model: claude-sonnet-4-20250514
EOF
    cli_load_config
    local pattern
    pattern=$(cli_get_process_pattern)
    [[ "$pattern" == "claude" ]]
}

@test "cli_get_process_pattern: codex は 'codex' を返す" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: codex
  model: gpt-5.2-codex
EOF
    cli_load_config
    local pattern
    pattern=$(cli_get_process_pattern)
    [[ "$pattern" == "codex" ]]
}

# =============================================================================
# cli_setup_project_config
# =============================================================================

@test "cli_setup_project_config: opencode で .ignite/opencode_leader.json を生成" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: opencode
  model: openai/o3
EOF
    cli_load_config
    local ws_dir="$TEST_TEMP_DIR/ws_default"
    mkdir -p "$ws_dir/.ignite"
    cli_setup_project_config "$ws_dir" "leader" "/tmp/char.md" "/tmp/instr.md"
    [ -f "$ws_dir/.ignite/opencode_leader.json" ]
    [[ "$(cat "$ws_dir/.ignite/opencode_leader.json")" == *'"model": "openai/o3"'* ]]
}

@test "cli_setup_project_config: opencode で正しいフィールドを含む" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: opencode
  model: openai/o3
EOF
    cli_load_config
    local ws_dir="$TEST_TEMP_DIR/ws_opencode"
    mkdir -p "$ws_dir/.ignite"
    cli_setup_project_config "$ws_dir" "leader" "/tmp/char.md" "/tmp/instr.md"
    [ -f "$ws_dir/.ignite/opencode_leader.json" ]
    [[ "$(cat "$ws_dir/.ignite/opencode_leader.json")" == *'"model": "openai/o3"'* ]]
    [[ "$(cat "$ws_dir/.ignite/opencode_leader.json")" == *'$schema'* ]]
    [[ "$(cat "$ws_dir/.ignite/opencode_leader.json")" == *'"permission"'* ]]
    [[ "$(cat "$ws_dir/.ignite/opencode_leader.json")" == *'"*": "allow"'* ]]
    [[ "$(cat "$ws_dir/.ignite/opencode_leader.json")" == *'"instructions"'* ]]
    [[ "$(cat "$ws_dir/.ignite/opencode_leader.json")" == *'/tmp/char.md'* ]]
    [[ "$(cat "$ws_dir/.ignite/opencode_leader.json")" == *'/tmp/instr.md'* ]]
}

@test "cli_setup_project_config: opencode で .ignite/ がなければルートに生成" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: opencode
  model: openai/o3
EOF
    cli_load_config
    local ws_dir="$TEST_TEMP_DIR/ws_no_ignite"
    mkdir -p "$ws_dir"
    cli_setup_project_config "$ws_dir" "leader"
    [ -f "$ws_dir/opencode_leader.json" ]
}

@test "cli_setup_project_config: opencode で既存ファイルは最新設定で再生成される" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: opencode
  model: openai/o3
EOF
    cli_load_config
    local ws_dir="$TEST_TEMP_DIR/ws_existing"
    mkdir -p "$ws_dir/.ignite"
    echo '{"custom": true, "model": "old/model"}' > "$ws_dir/.ignite/opencode_leader.json"
    cli_setup_project_config "$ws_dir" "leader"
    [[ "$(cat "$ws_dir/.ignite/opencode_leader.json")" == *'"model": "openai/o3"'* ]]
}

@test "cli_setup_project_config: claude で .claude_flags_{role} ファイルを生成" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: claude
  model: claude-sonnet-4-20250514
EOF
    cli_load_config
    local ws_dir="$TEST_TEMP_DIR/ws_claude"
    mkdir -p "$ws_dir/.ignite"
    # テスト用のダミーインストラクションファイルを作成
    echo "test" > "$TEST_TEMP_DIR/char.md"
    echo "test" > "$TEST_TEMP_DIR/instr.md"
    cli_setup_project_config "$ws_dir" "leader" "$TEST_TEMP_DIR/char.md" "$TEST_TEMP_DIR/instr.md"
    [ -f "$ws_dir/.ignite/.claude_flags_leader" ]
    [[ "$(cat "$ws_dir/.ignite/.claude_flags_leader")" == *"--append-system-prompt"* ]]
}

@test "cli_setup_project_config: codex で .codex_init_prompt_{role} ファイルを生成" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: codex
  model: gpt-5.2-codex
EOF
    cli_load_config
    local ws_dir="$TEST_TEMP_DIR/ws_codex"
    mkdir -p "$ws_dir/.ignite"
    echo "test instructions" > "$TEST_TEMP_DIR/char.md"
    echo "test more" > "$TEST_TEMP_DIR/instr.md"
    cli_setup_project_config "$ws_dir" "leader" "$TEST_TEMP_DIR/char.md" "$TEST_TEMP_DIR/instr.md"
    [ -f "$ws_dir/.ignite/.codex_init_prompt_leader" ]
    [[ "$(cat "$ws_dir/.ignite/.codex_init_prompt_leader")" == *"test instructions"* ]]
}

# =============================================================================
# cli_get_required_commands
# =============================================================================

@test "cli_get_required_commands: opencode は 'opencode jq'" {
    cli_load_config
    local cmds
    cmds=$(cli_get_required_commands)
    [[ "$cmds" == "opencode jq" ]]
}

@test "cli_get_required_commands: claude は 'claude jq'" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: claude
  model: claude-sonnet-4-20250514
EOF
    cli_load_config
    local cmds
    cmds=$(cli_get_required_commands)
    [[ "$cmds" == "claude jq" ]]
}

@test "cli_get_required_commands: codex は 'codex jq'" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: codex
  model: gpt-5.2-codex
EOF
    cli_load_config
    local cmds
    cmds=$(cli_get_required_commands)
    [[ "$cmds" == "codex jq" ]]
}

# =============================================================================
# cli_get_flock_timeout
# =============================================================================

@test "cli_get_flock_timeout: opencode は 600 を返す" {
    cli_load_config
    local timeout
    timeout=$(cli_get_flock_timeout)
    [[ "$timeout" == "600" ]]
}

@test "cli_get_flock_timeout: claude は 600 を返す" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: claude
  model: claude-sonnet-4-20250514
EOF
    cli_load_config
    local timeout
    timeout=$(cli_get_flock_timeout)
    [[ "$timeout" == "600" ]]
}

@test "cli_get_flock_timeout: codex は 600 を返す" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: codex
  model: gpt-5.2-codex
EOF
    cli_load_config
    local timeout
    timeout=$(cli_get_flock_timeout)
    [[ "$timeout" == "600" ]]
}

# =============================================================================
# cli_load_config: log_level
# =============================================================================

@test "cli_load_config: log_level を正しく読み込み" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: opencode
  model: openai/o3
  log_level: WARN
EOF
    cli_load_config
    [ "$CLI_LOG_LEVEL" = "WARN" ]
}

@test "cli_load_config: log_level 未設定で空文字" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: opencode
  model: openai/o3
EOF
    cli_load_config
    [ -z "$CLI_LOG_LEVEL" ]
}

@test "cli_load_config: 不正な log_level で警告+空にフォールバック" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: opencode
  model: openai/o3
  log_level: TRACE
EOF
    run cli_load_config
    [ "$status" -eq 0 ]
    [[ "$output" == *"不正な cli.log_level"* ]]
    # フォールバック後の値を確認
    cli_load_config 2>/dev/null
    [ -z "$CLI_LOG_LEVEL" ]
}

# =============================================================================
# cli_check_session_alive テスト
# =============================================================================

@test "cli_check_session_alive: セッション ID ファイルが存在すれば成功" {
    cli_load_config
    export IGNITE_RUNTIME_DIR="$TEST_TEMP_DIR/runtime"
    mkdir -p "$IGNITE_RUNTIME_DIR/state"
    echo "test-session-id" > "$IGNITE_RUNTIME_DIR/state/.agent_session_0"
    run cli_check_session_alive "0"
    [ "$status" -eq 0 ]
}

@test "cli_check_session_alive: セッション ID ファイルがなければ失敗" {
    cli_load_config
    export IGNITE_RUNTIME_DIR="$TEST_TEMP_DIR/runtime"
    mkdir -p "$IGNITE_RUNTIME_DIR/state"
    run cli_check_session_alive "0"
    [ "$status" -ne 0 ]
}

@test "cli_check_session_alive: セッション ID ファイルが空なら失敗" {
    cli_load_config
    export IGNITE_RUNTIME_DIR="$TEST_TEMP_DIR/runtime"
    mkdir -p "$IGNITE_RUNTIME_DIR/state"
    echo -n "" > "$IGNITE_RUNTIME_DIR/state/.agent_session_0"
    run cli_check_session_alive "0"
    [ "$status" -ne 0 ]
}

# =============================================================================
# cli_save_agent_state / cli_load_agent_state テスト
# =============================================================================

@test "cli_save_agent_state: port 引数なしで session_id と name を保存" {
    export IGNITE_RUNTIME_DIR="$TEST_TEMP_DIR/runtime"
    mkdir -p "$IGNITE_RUNTIME_DIR/state"
    cli_save_agent_state "0" "test-session-123" "TestAgent"
    [ "$(cat "$IGNITE_RUNTIME_DIR/state/.agent_session_0")" = "test-session-123" ]
    [ "$(cat "$IGNITE_RUNTIME_DIR/state/.agent_name_0")" = "TestAgent" ]
    # port ファイルは作成されない
    [ ! -f "$IGNITE_RUNTIME_DIR/state/.agent_port_0" ]
}

@test "cli_load_agent_state: _AGENT_SESSION_ID と _AGENT_NAME を読み込み" {
    export IGNITE_RUNTIME_DIR="$TEST_TEMP_DIR/runtime"
    mkdir -p "$IGNITE_RUNTIME_DIR/state"
    echo "test-session-456" > "$IGNITE_RUNTIME_DIR/state/.agent_session_0"
    echo "TestAgent2" > "$IGNITE_RUNTIME_DIR/state/.agent_name_0"
    cli_load_agent_state "0"
    [ "$_AGENT_SESSION_ID" = "test-session-456" ]
    [ "$_AGENT_NAME" = "TestAgent2" ]
}

# =============================================================================
# _log_session_response テスト
# =============================================================================

@test "_log_session_response: ログファイルにJSONLを書き込み" {
    local runtime_dir="$TEST_TEMP_DIR/runtime"
    mkdir -p "$runtime_dir/logs"
    export CLI_PROVIDER="claude"
    _log_session_response "leader" "sess-001" '{"result":"ok"}' "$runtime_dir"
    local log_file="$runtime_dir/logs/session_leader.jsonl"
    [ -f "$log_file" ]
    # jqで各フィールドが読めること
    [ "$(jq -r '.role' "$log_file")" = "leader" ]
    [ "$(jq -r '.sid' "$log_file")" = "sess-001" ]
    [ "$(jq -r '.provider' "$log_file")" = "claude" ]
    [ "$(jq -r '.type' "$log_file")" = "response" ]
    [ "$(jq -r '.ts' "$log_file")" != "null" ]
    [ "$(jq -r '.data.result' "$log_file")" = "ok" ]
}

@test "_log_session_response: 初回実行時にログディレクトリが存在すれば成功" {
    local runtime_dir="$TEST_TEMP_DIR/runtime"
    mkdir -p "$runtime_dir/logs"
    export CLI_PROVIDER="opencode"
    _log_session_response "coordinator" "sess-002" '{"msg":"hello"}' "$runtime_dir"
    [ -f "$runtime_dir/logs/session_coordinator.jsonl" ]
}

@test "_log_session_response: 複数回呼び出しでJSONL追記" {
    local runtime_dir="$TEST_TEMP_DIR/runtime"
    mkdir -p "$runtime_dir/logs"
    export CLI_PROVIDER="codex"
    _log_session_response "worker" "s1" '{"n":1}' "$runtime_dir"
    _log_session_response "worker" "s1" '{"n":2}' "$runtime_dir"
    local lines
    lines=$(wc -l < "$runtime_dir/logs/session_worker.jsonl")
    [ "$lines" -eq 2 ]
}

@test "_log_session_response: ログローテーション（5MB超で_prev.jsonlに退避）" {
    local runtime_dir="$TEST_TEMP_DIR/runtime"
    mkdir -p "$runtime_dir/logs"
    local log_file="$runtime_dir/logs/session_leader.jsonl"
    # 5MB超のダミーファイルを作成
    dd if=/dev/zero of="$log_file" bs=1024 count=5121 2>/dev/null
    export CLI_PROVIDER="claude"
    _log_session_response "leader" "sess-rot" '{"rotated":true}' "$runtime_dir"
    # _prev.jsonl が作成されている
    [ -f "$runtime_dir/logs/session_leader_prev.jsonl" ]
    # 新しいログファイルに最新エントリがある
    [ -f "$log_file" ]
    [ "$(jq -r '.sid' "$log_file")" = "sess-rot" ]
}

@test "_log_session_response: 空レスポンスでもエラーにならない" {
    local runtime_dir="$TEST_TEMP_DIR/runtime"
    mkdir -p "$runtime_dir/logs"
    export CLI_PROVIDER="claude"
    run _log_session_response "leader" "sess-empty" '' "$runtime_dir"
    [ "$status" -eq 0 ]
}

@test "_log_session_response: logsディレクトリ未作成でもエラーにならない" {
    local runtime_dir="$TEST_TEMP_DIR/runtime_nodir"
    # logsディレクトリを作成しない
    export CLI_PROVIDER="claude"
    run _log_session_response "leader" "sess-nodir" '{"test":1}' "$runtime_dir"
    [ "$status" -eq 0 ]
}

#!/usr/bin/env bats
# =============================================================================
# cli_provider.sh テスト
# テスト対象: scripts/lib/cli_provider.sh
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

# =============================================================================
# cli_get_process_names
# =============================================================================

@test "cli_get_process_names: opencode は 'opencode node' を返す" {
    cli_load_config
    local names
    names=$(cli_get_process_names)
    [[ "$names" == "opencode node" ]]
}

# =============================================================================
# cli_setup_project_config
# =============================================================================

@test "cli_setup_project_config: .ignite/opencode_leader.json を生成" {
    cli_load_config
    local ws_dir="$TEST_TEMP_DIR/ws_default"
    mkdir -p "$ws_dir/.ignite"
    cli_setup_project_config "$ws_dir" "leader" "/tmp/char.md" "/tmp/instr.md"
    [ -f "$ws_dir/.ignite/opencode_leader.json" ]
    [[ "$(cat "$ws_dir/.ignite/opencode_leader.json")" == *'"model": "openai/gpt-5.2-codex"'* ]]
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

@test "cli_setup_project_config: .ignite/ がなければルートに opencode_leader.json を生成" {
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

@test "cli_setup_project_config: 既存 opencode_leader.json は最新設定で再生成される" {
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

# =============================================================================
# cli_get_required_commands
# =============================================================================

@test "cli_get_required_commands: opencode は 'opencode curl jq'" {
    cli_load_config
    local cmds
    cmds=$(cli_get_required_commands)
    [[ "$cmds" == "opencode curl jq" ]]
}

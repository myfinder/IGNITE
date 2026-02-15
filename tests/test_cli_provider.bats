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

    # 最小限の system.yaml を作成（デフォルト: cli セクションなし）
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
tmux:
  window_name: ignite
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
tmux:
  window_name: ignite
EOF
    cli_load_config
    [ "$CLI_PROVIDER" = "opencode" ]
    [ "$CLI_MODEL" = "openai/o3" ]
    [ "$CLI_COMMAND" = "opencode" ]
}

@test "cli_load_config: 未対応プロバイダーでエラー" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: unknown_cli
tmux:
  window_name: ignite
EOF
    run cli_load_config
    [ "$status" -eq 1 ]
    [[ "$output" == *"未対応"* ]]
}

# =============================================================================
# cli_build_launch_command
# =============================================================================

@test "cli_build_launch_command: opencode（デフォルト）の起動コマンドが正しい" {
    cli_load_config
    local cmd
    cmd=$(cli_build_launch_command "/tmp/ws")
    [[ "$cmd" == *"OPENCODE_CONFIG='.ignite/opencode_leader.json' opencode"* ]]
    [[ "$cmd" == *"WORKSPACE_DIR='/tmp/ws'"* ]]
    [[ "$cmd" == *"cd '/tmp/ws'"* ]]
    [[ "$cmd" != *"--dangerously-skip-permissions"* ]]
}

@test "cli_build_launch_command: claude の起動コマンドが正しい" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: claude
  model: claude-opus-4-6
tmux:
  window_name: ignite
EOF
    cli_load_config
    local cmd
    cmd=$(cli_build_launch_command "/tmp/ws")
    [[ "$cmd" == *"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1"* ]]
    [[ "$cmd" == *"claude --model"* ]]
    [[ "$cmd" == *"--dangerously-skip-permissions"* ]]
    [[ "$cmd" == *"--teammate-mode in-process"* ]]
    [[ "$cmd" == *"WORKSPACE_DIR='/tmp/ws'"* ]]
    [[ "$cmd" == *"cd '/tmp/ws'"* ]]
}

@test "cli_build_launch_command: opencode の起動コマンドが正しい" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: opencode
  model: openai/o3
EOF
    cli_load_config
    local cmd
    cmd=$(cli_build_launch_command "/tmp/ws")
    [[ "$cmd" == *"OPENCODE_CONFIG='.ignite/opencode_leader.json' opencode"* ]]
    [[ "$cmd" == *"WORKSPACE_DIR='/tmp/ws'"* ]]
    # opencode はフラグではなく opencode.json の permission で制御
    [[ "$cmd" != *"--dangerously-skip-permissions"* ]]
}

@test "cli_build_launch_command: extra_env が含まれる" {
    cli_load_config
    local cmd
    cmd=$(cli_build_launch_command "/tmp/ws" "export IGNITE_WORKER_ID=1 && ")
    [[ "$cmd" == *"IGNITE_WORKER_ID=1"* ]]
}

@test "cli_build_launch_command: gh_export が先頭に含まれる" {
    cli_load_config
    local cmd
    cmd=$(cli_build_launch_command "/tmp/ws" "" "export GH_TOKEN=xxx && ")
    [[ "$cmd" == "export GH_TOKEN=xxx && "* ]]
}

# =============================================================================
# cli_get_process_names
# =============================================================================

@test "cli_get_process_names: opencode（デフォルト）は 'opencode node' を返す" {
    cli_load_config
    local names
    names=$(cli_get_process_names)
    [[ "$names" == "opencode node" ]]
}

@test "cli_get_process_names: claude は 'claude node' を返す" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: claude
  model: claude-opus-4-6
tmux:
  window_name: ignite
EOF
    cli_load_config
    local names
    names=$(cli_get_process_names)
    [[ "$names" == "claude node" ]]
}

@test "cli_get_process_names: opencode は 'opencode node' を返す" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: opencode
  model: openai/o3
EOF
    cli_load_config
    local names
    names=$(cli_get_process_names)
    [[ "$names" == "opencode node" ]]
}

# =============================================================================
# cli_needs_permission_accept
# =============================================================================

@test "cli_needs_permission_accept: opencode（デフォルト）は 1 (不要)" {
    cli_load_config
    run cli_needs_permission_accept
    [ "$status" -eq 1 ]
}

@test "cli_needs_permission_accept: claude は 0 (必要)" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: claude
  model: claude-opus-4-6
tmux:
  window_name: ignite
EOF
    cli_load_config
    cli_needs_permission_accept
}

@test "cli_needs_permission_accept: opencode は 1 (不要)" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: opencode
  model: openai/o3
EOF
    cli_load_config
    run cli_needs_permission_accept
    [ "$status" -eq 1 ]
}

# =============================================================================
# cli_needs_prompt_injection
# =============================================================================

@test "cli_needs_prompt_injection: opencode（デフォルト）は 1 (不要)" {
    cli_load_config
    run cli_needs_prompt_injection
    [ "$status" -eq 1 ]
}

@test "cli_needs_prompt_injection: claude は 0 (必要)" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: claude
  model: claude-opus-4-6
tmux:
  window_name: ignite
EOF
    cli_load_config
    cli_needs_prompt_injection
}

@test "cli_needs_prompt_injection: opencode は 1 (不要)" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: opencode
  model: openai/o3
EOF
    cli_load_config
    run cli_needs_prompt_injection
    [ "$status" -eq 1 ]
}

# =============================================================================
# cli_is_cost_tracking_supported
# =============================================================================

@test "cli_is_cost_tracking_supported: opencode（デフォルト）は非対応" {
    cli_load_config
    run cli_is_cost_tracking_supported
    [ "$status" -eq 1 ]
}

@test "cli_is_cost_tracking_supported: claude は対応" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: claude
  model: claude-opus-4-6
tmux:
  window_name: ignite
EOF
    cli_load_config
    cli_is_cost_tracking_supported
}

@test "cli_is_cost_tracking_supported: opencode は非対応" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: opencode
  model: openai/o3
EOF
    cli_load_config
    run cli_is_cost_tracking_supported
    [ "$status" -eq 1 ]
}

# =============================================================================
# cli_setup_project_config
# =============================================================================

@test "cli_setup_project_config: opencode（デフォルト）で .ignite/opencode_leader.json を生成" {
    cli_load_config
    local ws_dir="$TEST_TEMP_DIR/ws_default"
    mkdir -p "$ws_dir/.ignite"
    cli_setup_project_config "$ws_dir" "leader" "/tmp/char.md" "/tmp/instr.md"
    [ -f "$ws_dir/.ignite/opencode_leader.json" ]
    [[ "$(cat "$ws_dir/.ignite/opencode_leader.json")" == *'"model": "openai/gpt-5.2-codex"'* ]]
}

@test "cli_setup_project_config: claude では何も生成しない" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: claude
  model: claude-opus-4-6
tmux:
  window_name: ignite
EOF
    cli_load_config
    local ws_dir="$TEST_TEMP_DIR/ws_claude"
    mkdir -p "$ws_dir/.ignite"
    cli_setup_project_config "$ws_dir"
    [ ! -f "$ws_dir/.ignite/opencode.json" ]
    [ ! -f "$ws_dir/opencode.json" ]
}

@test "cli_setup_project_config: opencode で .ignite/opencode_leader.json を生成" {
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
# cli_get_env_vars
# =============================================================================

@test "cli_get_env_vars: opencode（デフォルト）は OPENCODE_CONFIG を含む" {
    cli_load_config
    local vars
    vars=$(cli_get_env_vars)
    [[ "$vars" == *"OPENCODE_CONFIG=.ignite/opencode.json"* ]]
}

@test "cli_get_env_vars: claude は AGENT_TEAMS を含む" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: claude
  model: claude-opus-4-6
tmux:
  window_name: ignite
EOF
    cli_load_config
    local vars
    vars=$(cli_get_env_vars)
    [[ "$vars" == *"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1"* ]]
}

@test "cli_get_env_vars: opencode は OPENCODE_CONFIG のみ（API Key は .env から読み込み）" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: opencode
  model: openai/o3
EOF
    cli_load_config
    local vars
    vars=$(cli_get_env_vars)
    [[ "$vars" == *"OPENCODE_CONFIG=.ignite/opencode.json"* ]]
    [[ "$vars" != *"OPENAI_API_KEY"* ]]
    [[ "$vars" != *"ANTHROPIC_API_KEY"* ]]
}

# =============================================================================
# cli_get_required_commands
# =============================================================================

@test "cli_get_required_commands: opencode（デフォルト）は 'tmux opencode gh'" {
    cli_load_config
    local cmds
    cmds=$(cli_get_required_commands)
    [[ "$cmds" == "tmux opencode gh" ]]
}

@test "cli_get_required_commands: claude は 'tmux claude gh'" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: claude
  model: claude-opus-4-6
tmux:
  window_name: ignite
EOF
    cli_load_config
    local cmds
    cmds=$(cli_get_required_commands)
    [[ "$cmds" == "tmux claude gh" ]]
}

@test "cli_get_required_commands: opencode は 'tmux opencode gh'" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: opencode
  model: openai/o3
EOF
    cli_load_config
    local cmds
    cmds=$(cli_get_required_commands)
    [[ "$cmds" == "tmux opencode gh" ]]
}

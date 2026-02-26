#!/usr/bin/env bats
# =============================================================================
# isolation.sh テスト
# テスト対象: scripts/lib/isolation.sh
# =============================================================================

load 'test_helper'

setup() {
    setup_temp_dir

    export IGNITE_CONFIG_DIR="$TEST_TEMP_DIR/config_dir"
    mkdir -p "$IGNITE_CONFIG_DIR"

    # isolation OFF のデフォルト system.yaml
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: claude
  model: claude-opus-4-6
defaults:
  message_priority: normal
isolation:
  enabled: false
  runtime: podman
  image: ignite-agent:latest
  resource_memory: 4g
  resource_cpus: 4
EOF

    export IGNITE_RUNTIME_DIR="$TEST_TEMP_DIR/runtime"
    mkdir -p "$IGNITE_RUNTIME_DIR/state"
    mkdir -p "$IGNITE_RUNTIME_DIR/tmp"

    # core.sh を source（cli_provider.sh + isolation.sh が自動読み込み）
    source "$SCRIPTS_DIR/lib/core.sh"
}

teardown() {
    cleanup_temp_dir
}

# =============================================================================
# isolation_is_enabled
# =============================================================================

@test "isolation_is_enabled: enabled=false で false を返す" {
    run isolation_is_enabled
    [ "$status" -eq 1 ]
}

@test "isolation_is_enabled: enabled=true で true を返す" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: claude
  model: claude-opus-4-6
defaults:
  message_priority: normal
isolation:
  enabled: true
  runtime: podman
  image: ignite-agent:latest
EOF
    run isolation_is_enabled
    [ "$status" -eq 0 ]
}

@test "isolation_is_enabled: isolation セクションなしでデフォルト false" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: claude
  model: claude-opus-4-6
defaults:
  message_priority: normal
EOF
    run isolation_is_enabled
    [ "$status" -eq 1 ]
}

# =============================================================================
# isolation_check_prerequisites
# =============================================================================

@test "isolation_check_prerequisites: podman 未インストール時エラー" {
    # podman コマンドが存在しないランタイムを指定
    _ISOLATION_RUNTIME="__nonexistent_runtime_for_test__"
    run isolation_check_prerequisites
    [ "$status" -eq 1 ]
    [[ "$output" == *"インストールされていません"* ]]
}

# =============================================================================
# isolation_get_container_name
# =============================================================================

@test "isolation_get_container_name: 一意なコンテナ名を生成" {
    local name1
    name1=$(isolation_get_container_name "/home/user/workspace1")
    [[ "$name1" == ignite-ws-* ]]
    # 8文字のハッシュ
    local hash="${name1#ignite-ws-}"
    [ "${#hash}" -eq 8 ]
}

@test "isolation_get_container_name: 同じパスで決定的な結果" {
    local name1 name2
    name1=$(isolation_get_container_name "/home/user/workspace1")
    name2=$(isolation_get_container_name "/home/user/workspace1")
    [ "$name1" = "$name2" ]
}

@test "isolation_get_container_name: 異なるパスで異なる名前" {
    local name1 name2
    name1=$(isolation_get_container_name "/home/user/workspace1")
    name2=$(isolation_get_container_name "/home/user/workspace2")
    [ "$name1" != "$name2" ]
}

# =============================================================================
# isolation_write_message_file
# =============================================================================

@test "isolation_write_message_file: メッセージをファイルに書き出し" {
    local msg="Hello, World! テストメッセージ"
    local msg_file
    msg_file=$(isolation_write_message_file "$msg")

    [ -f "$msg_file" ]
    local content
    content=$(cat "$msg_file")
    [ "$content" = "$msg" ]
}

@test "isolation_write_message_file: 特殊文字を含むメッセージ" {
    local msg='Message with "quotes" and $vars and `backticks`'
    local msg_file
    msg_file=$(isolation_write_message_file "$msg")

    [ -f "$msg_file" ]
    local content
    content=$(cat "$msg_file")
    [ "$content" = "$msg" ]
}

@test "isolation_write_message_file: 複数呼び出しで異なるファイル" {
    local file1 file2
    file1=$(isolation_write_message_file "msg1")
    file2=$(isolation_write_message_file "msg2")
    [ "$file1" != "$file2" ]
}

# =============================================================================
# isolation_exec: ステートファイル未存在時エラー
# =============================================================================

@test "isolation_exec: container_name ステートファイルなしでエラー" {
    rm -f "$IGNITE_RUNTIME_DIR/state/container_name"
    run isolation_exec echo "test"
    [ "$status" -eq 1 ]
}

# =============================================================================
# isolation_is_container_running: ステートファイルなし時 false
# =============================================================================

@test "isolation_is_container_running: ステートファイルなしで false" {
    rm -f "$IGNITE_RUNTIME_DIR/state/container_name"
    run isolation_is_container_running
    [ "$status" -eq 1 ]
}

# =============================================================================
# isolation_stop_container: ステートファイルなしで安全に終了
# =============================================================================

@test "isolation_stop_container: ステートファイルなしで安全に return 0" {
    rm -f "$IGNITE_RUNTIME_DIR/state/container_name"
    run isolation_stop_container "$IGNITE_RUNTIME_DIR"
    [ "$status" -eq 0 ]
}

# =============================================================================
# isolation_get_container_info: ステートファイルなしで "none"
# =============================================================================

@test "isolation_get_container_info: ステートファイルなしで none を返す" {
    rm -f "$IGNITE_RUNTIME_DIR/state/container_name"
    run isolation_get_container_info
    [ "$status" -eq 1 ]
    [ "$output" = "none" ]
}

# =============================================================================
# isolation_get_container_name: パス正規化
# =============================================================================

@test "isolation_get_container_name: 末尾スラッシュで結果が変わらない" {
    local name1 name2
    name1=$(isolation_get_container_name "/home/user/workspace1")
    name2=$(isolation_get_container_name "/home/user/workspace1/")
    [ "$name1" = "$name2" ]
}

# =============================================================================
# isolation_exec_with_env: パース
# =============================================================================

@test "isolation_exec_with_env: container_name ステートファイルなしでエラー" {
    rm -f "$IGNITE_RUNTIME_DIR/state/container_name"
    run isolation_exec_with_env -e "FOO=bar" -- echo "test"
    [ "$status" -eq 1 ]
}

# =============================================================================
# isolation_stop_container: カスタムタイムアウト
# =============================================================================

@test "isolation_stop_container: ステートファイルなしでカスタムタイムアウトでも安全に return 0" {
    rm -f "$IGNITE_RUNTIME_DIR/state/container_name"
    run isolation_stop_container "$IGNITE_RUNTIME_DIR" 60
    [ "$status" -eq 0 ]
}

# =============================================================================
# _isolation_get_network_option: フォールバック
# =============================================================================

@test "_isolation_get_network_option: 存在しないランタイムで slirp4netns にフォールバック" {
    _ISOLATION_RUNTIME="__nonexistent_runtime__"
    run _isolation_get_network_option
    [ "$status" -eq 0 ]
    [ "$output" = "slirp4netns" ]
}

# =============================================================================
# isolation OFF 時の既存機能互換性
# =============================================================================

@test "isolation OFF: cli_load_config が正常に完了" {
    # isolation.enabled=false で cli_load_config がエラーなく完了すること
    run cli_load_config
    [ "$status" -eq 0 ]
    [ "$CLI_PROVIDER" = "claude" ]
}

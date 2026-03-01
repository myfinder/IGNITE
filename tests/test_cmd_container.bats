#!/usr/bin/env bats
# =============================================================================
# cmd_container.sh テスト
# テスト対象: scripts/lib/cmd_container.sh (_resolve_containerfile)
# =============================================================================

load 'test_helper'

setup() {
    setup_temp_dir

    export IGNITE_CONFIG_DIR="$TEST_TEMP_DIR/config_dir"
    mkdir -p "$IGNITE_CONFIG_DIR"

    # デフォルト system.yaml
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
  containerfile: ""
  resource_memory: 4g
  resource_cpus: 4
EOF

    export IGNITE_RUNTIME_DIR="$TEST_TEMP_DIR/runtime"
    mkdir -p "$IGNITE_RUNTIME_DIR/state"
    mkdir -p "$IGNITE_RUNTIME_DIR/tmp"

    export WORKSPACE_DIR="$TEST_TEMP_DIR/workspace"
    mkdir -p "$WORKSPACE_DIR"

    # core.sh を source（IGNITE_DATA_DIR は core.sh 内で PROJECT_ROOT に上書きされる）
    source "$SCRIPTS_DIR/lib/core.sh"
    source "$SCRIPTS_DIR/lib/cmd_container.sh"

    # core.sh source 後に IGNITE_DATA_DIR を一時ディレクトリに上書き
    # (プロジェクト本体の containers/ を汚染しないため)
    IGNITE_DATA_DIR="$TEST_TEMP_DIR/data_dir"
    mkdir -p "$IGNITE_DATA_DIR"
}

teardown() {
    cleanup_temp_dir
}

# =============================================================================
# _resolve_containerfile - CLI -f 指定
# =============================================================================

@test "_resolve_containerfile: CLI -f 指定のファイルが返る (return 0)" {
    local cf="$TEST_TEMP_DIR/custom/Containerfile.test"
    mkdir -p "$(dirname "$cf")"
    echo "FROM ubuntu" > "$cf"

    run _resolve_containerfile "$cf"
    [ "$status" -eq 0 ]
    [ "$output" = "$cf" ]
}

@test "_resolve_containerfile: CLI -f 指定のファイルが存在しない (return 2)" {
    run _resolve_containerfile "/nonexistent/Containerfile"
    [ "$status" -eq 2 ]
    [ -z "$output" ]
}

@test "_resolve_containerfile: CLI -f 相対パスが絶対パスに変換される" {
    local cf="$WORKSPACE_DIR/Containerfile.custom"
    echo "FROM ubuntu" > "$cf"

    run _resolve_containerfile "Containerfile.custom"
    [ "$status" -eq 0 ]
    [ "$output" = "$WORKSPACE_DIR/Containerfile.custom" ]
}

# =============================================================================
# _resolve_containerfile - system.yaml 指定
# =============================================================================

@test "_resolve_containerfile: system.yaml containerfile 指定が返る (return 0)" {
    local cf="$WORKSPACE_DIR/my/Containerfile"
    mkdir -p "$(dirname "$cf")"
    echo "FROM ubuntu" > "$cf"

    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<EOF
cli:
  provider: claude
isolation:
  enabled: true
  image: ignite-agent:latest
  containerfile: "$cf"
EOF

    run _resolve_containerfile
    [ "$status" -eq 0 ]
    [ "$output" = "$cf" ]
}

@test "_resolve_containerfile: system.yaml containerfile 相対パスはワークスペース基準" {
    local cf="$WORKSPACE_DIR/Containerfile.ws"
    echo "FROM ubuntu" > "$cf"

    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: claude
isolation:
  enabled: true
  image: ignite-agent:latest
  containerfile: Containerfile.ws
EOF

    run _resolve_containerfile
    [ "$status" -eq 0 ]
    [ "$output" = "$WORKSPACE_DIR/Containerfile.ws" ]
}

@test "_resolve_containerfile: system.yaml containerfile が存在しない (return 2)" {
    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<'EOF'
cli:
  provider: claude
isolation:
  enabled: true
  image: ignite-agent:latest
  containerfile: nonexistent/Containerfile
EOF

    run _resolve_containerfile
    [ "$status" -eq 2 ]
    [ -z "$output" ]
}

# =============================================================================
# _resolve_containerfile - .ignite/containers/ フォールバック
# =============================================================================

@test "_resolve_containerfile: .ignite/containers/Containerfile.agent が返る (return 0)" {
    mkdir -p "$IGNITE_CONFIG_DIR/containers"
    echo "FROM ubuntu" > "$IGNITE_CONFIG_DIR/containers/Containerfile.agent"

    run _resolve_containerfile
    [ "$status" -eq 0 ]
    [ "$output" = "$IGNITE_CONFIG_DIR/containers/Containerfile.agent" ]
}

# =============================================================================
# _resolve_containerfile - インストール先フォールバック
# =============================================================================

@test "_resolve_containerfile: IGNITE_DATA_DIR フォールバック (return 1)" {
    mkdir -p "$IGNITE_DATA_DIR/containers"
    echo "FROM ubuntu" > "$IGNITE_DATA_DIR/containers/Containerfile.agent"

    run _resolve_containerfile
    [ "$status" -eq 1 ]
    [ "$output" = "$IGNITE_DATA_DIR/containers/Containerfile.agent" ]
}

# =============================================================================
# _resolve_containerfile - どこにもない
# =============================================================================

@test "_resolve_containerfile: どこにもない場合 (return 2)" {
    # SCRIPT_DIR と IGNITE_DATA_DIR のフォールバックも無効化
    SCRIPT_DIR="$TEST_TEMP_DIR/no_scripts"
    mkdir -p "$SCRIPT_DIR"
    IGNITE_DATA_DIR="$TEST_TEMP_DIR/no_data"
    mkdir -p "$IGNITE_DATA_DIR"

    run _resolve_containerfile
    [ "$status" -eq 2 ]
    [ -z "$output" ]
}

# =============================================================================
# _resolve_containerfile - 優先順位テスト
# =============================================================================

@test "_resolve_containerfile: CLI -f が system.yaml より優先される" {
    local cli_cf="$TEST_TEMP_DIR/cli/Containerfile"
    mkdir -p "$(dirname "$cli_cf")"
    echo "FROM cli" > "$cli_cf"

    local sys_cf="$WORKSPACE_DIR/Containerfile.sys"
    echo "FROM sys" > "$sys_cf"

    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<EOF
cli:
  provider: claude
isolation:
  enabled: true
  image: ignite-agent:latest
  containerfile: "$sys_cf"
EOF

    run _resolve_containerfile "$cli_cf"
    [ "$status" -eq 0 ]
    [ "$output" = "$cli_cf" ]
}

@test "_resolve_containerfile: system.yaml が .ignite/containers/ より優先される" {
    local sys_cf="$WORKSPACE_DIR/Containerfile.sys"
    echo "FROM sys" > "$sys_cf"

    mkdir -p "$IGNITE_CONFIG_DIR/containers"
    echo "FROM local" > "$IGNITE_CONFIG_DIR/containers/Containerfile.agent"

    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<EOF
cli:
  provider: claude
isolation:
  enabled: true
  image: ignite-agent:latest
  containerfile: "$sys_cf"
EOF

    run _resolve_containerfile
    [ "$status" -eq 0 ]
    [ "$output" = "$sys_cf" ]
}

@test "_resolve_containerfile: .ignite/containers/ が IGNITE_DATA_DIR より優先される" {
    mkdir -p "$IGNITE_CONFIG_DIR/containers"
    echo "FROM local" > "$IGNITE_CONFIG_DIR/containers/Containerfile.agent"

    mkdir -p "$IGNITE_DATA_DIR/containers"
    echo "FROM data" > "$IGNITE_DATA_DIR/containers/Containerfile.agent"

    run _resolve_containerfile
    [ "$status" -eq 0 ]
    [ "$output" = "$IGNITE_CONFIG_DIR/containers/Containerfile.agent" ]
}

# =============================================================================
# _resolve_containerfile - 専用パーサー（P2: スペース含むパス）
# =============================================================================

@test "_resolve_containerfile: system.yaml containerfile にスペース含むパスを解決できる" {
    local cf="$WORKSPACE_DIR/my dir/Containerfile"
    mkdir -p "$(dirname "$cf")"
    echo "FROM ubuntu" > "$cf"

    cat > "$IGNITE_CONFIG_DIR/system.yaml" <<EOF
cli:
  provider: claude
isolation:
  enabled: true
  image: ignite-agent:latest
  containerfile: "my dir/Containerfile"
EOF

    run _resolve_containerfile
    [ "$status" -eq 0 ]
    [ "$output" = "$WORKSPACE_DIR/my dir/Containerfile" ]
}

# =============================================================================
# cmd_build_image - オプション解析テスト（P5: 統合テスト）
# =============================================================================

@test "cmd_build_image: -f オプションが解析される" {
    # cmd_build_image は -w 必須。未初期化で早期エラーになることを確認
    run cmd_build_image -w "$TEST_TEMP_DIR/nonexist" -f "/some/Containerfile"
    [ "$status" -eq 1 ]
    # -w チェックでエラー（.ignite/ がない）
    [[ "$output" == *"初期化されていません"* ]]
}

@test "cmd_build_image: --help で -f オプションが表示される" {
    run cmd_build_image --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--containerfile"* ]]
    [[ "$output" == *"-f"* ]]
}

@test "cmd_build_image: 不正なオプションでエラー" {
    run cmd_build_image --invalid-opt
    [ "$status" -eq 1 ]
    [[ "$output" == *"不正なオプション"* ]]
}

# =============================================================================
# _init_generate_containerignore テスト（P6）
# =============================================================================

@test "cmd_init: .containerignore が生成される" {
    source "$SCRIPTS_DIR/lib/cmd_init.sh"
    local target="$TEST_TEMP_DIR/init_containerignore"
    mkdir -p "$target"

    cmd_init --minimal -w "$target"
    [ -f "$target/.ignite/.containerignore" ]
    # 主要パターンが含まれていること
    grep -q ".ignite/queue/" "$target/.ignite/.containerignore"
    grep -q ".git/" "$target/.ignite/.containerignore"
    grep -q "node_modules/" "$target/.ignite/.containerignore"
}

@test "cmd_init --force: .containerignore が再生成される" {
    source "$SCRIPTS_DIR/lib/cmd_init.sh"
    local target="$TEST_TEMP_DIR/init_containerignore_force"
    mkdir -p "$target/.ignite"
    echo "old-content" > "$target/.ignite/.containerignore"

    cmd_init --force --minimal -w "$target"
    [ -f "$target/.ignite/.containerignore" ]
    ! grep -q "old-content" "$target/.ignite/.containerignore"
}

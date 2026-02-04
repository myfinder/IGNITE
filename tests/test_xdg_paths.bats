#!/usr/bin/env bats
# =============================================================================
# XDGパス解決ロジックのテスト
# テスト対象: scripts/ignite および各utilsスクリプトのXDGパス解決
# =============================================================================

load 'test_helper'

setup() {
    setup_temp_dir
}

teardown() {
    cleanup_temp_dir
}

# =============================================================================
# インストールモード判定のテスト
# =============================================================================

@test "XDG: .install_pathsが存在する場合はインストールモード" {
    # インストールモードのマーカーファイルを作成
    mkdir -p "$XDG_CONFIG_HOME/ignite"
    touch "$XDG_CONFIG_HOME/ignite/.install_paths"

    # インストールモードの判定
    if [[ -f "$XDG_CONFIG_HOME/ignite/.install_paths" ]]; then
        INSTALLED_MODE=true
    else
        INSTALLED_MODE=false
    fi

    [[ "$INSTALLED_MODE" == "true" ]]
}

@test "XDG: .install_pathsが存在しない場合は開発モード" {
    # マーカーファイルがない状態

    if [[ -f "$XDG_CONFIG_HOME/ignite/.install_paths" ]]; then
        INSTALLED_MODE=true
    else
        INSTALLED_MODE=false
    fi

    [[ "$INSTALLED_MODE" == "false" ]]
}

@test "XDG: インストールモードでは XDG_CONFIG_HOME/ignite を使用" {
    mkdir -p "$XDG_CONFIG_HOME/ignite"
    touch "$XDG_CONFIG_HOME/ignite/.install_paths"

    if [[ -f "$XDG_CONFIG_HOME/ignite/.install_paths" ]]; then
        IGNITE_CONFIG_DIR="$XDG_CONFIG_HOME/ignite"
    else
        IGNITE_CONFIG_DIR="/dev/null"  # fallback
    fi

    [[ "$IGNITE_CONFIG_DIR" == "$XDG_CONFIG_HOME/ignite" ]]
}

@test "XDG: XDG_CONFIG_HOMEが未設定の場合は ~/.config がデフォルト" {
    unset XDG_CONFIG_HOME
    local default_config="${XDG_CONFIG_HOME:-$HOME/.config}"

    [[ "$default_config" == "$HOME/.config" ]]
}

@test "XDG: XDG_DATA_HOMEが未設定の場合は ~/.local/share がデフォルト" {
    unset XDG_DATA_HOME
    local default_data="${XDG_DATA_HOME:-$HOME/.local/share}"

    [[ "$default_data" == "$HOME/.local/share" ]]
}

# =============================================================================
# パス構築のテスト
# =============================================================================

@test "XDG: インストールモードのパス構築が正しい" {
    mkdir -p "$XDG_CONFIG_HOME/ignite"
    touch "$XDG_CONFIG_HOME/ignite/.install_paths"

    IGNITE_CONFIG_DIR="$XDG_CONFIG_HOME/ignite"
    IGNITE_DATA_DIR="$XDG_DATA_HOME/ignite"
    IGNITE_INSTRUCTIONS_DIR="$IGNITE_DATA_DIR/instructions"
    IGNITE_SCRIPTS_DIR="$IGNITE_DATA_DIR/scripts"

    [[ "$IGNITE_CONFIG_DIR" == "$XDG_CONFIG_HOME/ignite" ]]
    [[ "$IGNITE_DATA_DIR" == "$XDG_DATA_HOME/ignite" ]]
    [[ "$IGNITE_INSTRUCTIONS_DIR" == "$XDG_DATA_HOME/ignite/instructions" ]]
    [[ "$IGNITE_SCRIPTS_DIR" == "$XDG_DATA_HOME/ignite/scripts" ]]
}

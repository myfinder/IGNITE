#!/usr/bin/env bash
# =============================================================================
# テストヘルパー
# batsテスト用の共通セットアップとユーティリティ
# =============================================================================

# テスト用の一時ディレクトリを作成
setup_temp_dir() {
    export TEST_TEMP_DIR=$(mktemp -d)
    export XDG_CONFIG_HOME="$TEST_TEMP_DIR/config"
    export XDG_DATA_HOME="$TEST_TEMP_DIR/data"
    mkdir -p "$XDG_CONFIG_HOME"
    mkdir -p "$XDG_DATA_HOME"
}

# 一時ディレクトリをクリーンアップ
cleanup_temp_dir() {
    if [[ -n "${TEST_TEMP_DIR:-}" && -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

# プロジェクトルートを取得
get_project_root() {
    cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

# スクリプトのパスを取得
PROJECT_ROOT="$(get_project_root)"
SCRIPTS_DIR="$PROJECT_ROOT/scripts"
UTILS_DIR="$SCRIPTS_DIR/utils"

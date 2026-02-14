#!/usr/bin/env bats
# =============================================================================
# cmd_service.sh テスト
# テスト対象: scripts/lib/cmd_service.sh
# =============================================================================

load 'test_helper'

setup() {
    setup_temp_dir

    # PROJECT_ROOT の元の値を保存（lifecycle テスト用）
    export PROJECT_ROOT_ORIG="$PROJECT_ROOT"

    # cmd_service.sh が依存するライブラリを source
    source "$SCRIPTS_DIR/lib/core.sh"
    source "$SCRIPTS_DIR/lib/cmd_help.sh"
    source "$SCRIPTS_DIR/lib/cmd_service.sh"

    # テスト用ディレクトリ
    export UNIT_DIR="$TEST_TEMP_DIR/systemd/user"
    mkdir -p "$UNIT_DIR"

    # テンプレート用ディレクトリ
    export TEMPLATE_DIR="$TEST_TEMP_DIR/templates/systemd"
    mkdir -p "$TEMPLATE_DIR"
    cp "$PROJECT_ROOT/templates/systemd/ignite@.service" "$TEMPLATE_DIR/"
}

teardown() {
    cleanup_temp_dir
}

# =============================================================================
# ディスパッチ
# =============================================================================

@test "service: 不明なアクションでヘルプ表示+エラー終了" {
    run cmd_service "unknown-action"
    [ "$status" -eq 1 ]
    [[ "$output" == *"service"* ]]
}

@test "service: アクションなしでヘルプ表示" {
    run cmd_service
    [ "$status" -eq 0 ]
    [[ "$output" == *"service"* ]]
}

# =============================================================================
# install
# =============================================================================

@test "install: テンプレートが見つからない場合エラー" {
    # テンプレートが存在しないパスのみを検索させる
    IGNITE_DATA_DIR="$TEST_TEMP_DIR/nonexistent"
    IGNITE_CONFIG_DIR="$TEST_TEMP_DIR/nonexistent2"
    PROJECT_ROOT="$TEST_TEMP_DIR/nonexistent3"

    run _service_install
    [ "$status" -eq 1 ]
    [[ "$output" == *"見つかりません"* ]]
}

@test "install: 初回インストールでユニットファイルが配置される" {
    # systemctl をスタブ化
    systemctl() { return 0; }
    export -f systemctl

    # HOME を書き換えてインストール先を制御
    export HOME="$TEST_TEMP_DIR"
    PROJECT_ROOT="$TEST_TEMP_DIR"

    run _service_install
    [ "$status" -eq 0 ]
    [ -f "$TEST_TEMP_DIR/.config/systemd/user/ignite@.service" ]
    [[ "$output" == *"インストールしました"* ]]
}

@test "install: --force で既存ファイルを上書き" {
    systemctl() { return 0; }
    export -f systemctl

    export HOME="$TEST_TEMP_DIR"
    PROJECT_ROOT="$TEST_TEMP_DIR"

    # 古いバージョンのユニットファイルを配置
    mkdir -p "$TEST_TEMP_DIR/.config/systemd/user"
    echo "old content" > "$TEST_TEMP_DIR/.config/systemd/user/ignite@.service"

    run _service_install --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"インストールしました"* ]]

    # 内容が更新されていること
    local content
    content=$(cat "$TEST_TEMP_DIR/.config/systemd/user/ignite@.service")
    [[ "$content" != "old content" ]]
}

@test "install: 同一ファイルの場合スキップ" {
    systemctl() { return 0; }
    export -f systemctl

    export HOME="$TEST_TEMP_DIR"
    PROJECT_ROOT="$TEST_TEMP_DIR"

    # 同一内容のユニットファイルを配置
    mkdir -p "$TEST_TEMP_DIR/.config/systemd/user"
    cp "$TEMPLATE_DIR/ignite@.service" "$TEST_TEMP_DIR/.config/systemd/user/ignite@.service"

    run _service_install
    [ "$status" -eq 0 ]
    [[ "$output" == *"最新版です"* ]]
}

@test "install: 差分がある場合 diff が表示される" {
    systemctl() { return 0; }
    export -f systemctl

    export HOME="$TEST_TEMP_DIR"
    PROJECT_ROOT="$TEST_TEMP_DIR"

    # 古いバージョンのユニットファイルを配置
    mkdir -p "$TEST_TEMP_DIR/.config/systemd/user"
    echo "old content" > "$TEST_TEMP_DIR/.config/systemd/user/ignite@.service"

    # --force で差分表示＋確認スキップ
    run _service_install --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"変更があります"* ]]
    # diff -u の出力特徴: ---/+++ ヘッダーが含まれる
    [[ "$output" == *"---"* ]]
    [[ "$output" == *"+++"* ]]
}

# =============================================================================
# uninstall
# =============================================================================

@test "uninstall: ユニットファイルが削除される" {
    systemctl() { return 0; }
    export -f systemctl

    export HOME="$TEST_TEMP_DIR"
    mkdir -p "$TEST_TEMP_DIR/.config/systemd/user"
    touch "$TEST_TEMP_DIR/.config/systemd/user/ignite@.service"

    run _service_uninstall
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_TEMP_DIR/.config/systemd/user/ignite@.service" ]
    [[ "$output" == *"削除しました"* ]]
}

@test "uninstall: ユニットファイルがない場合警告" {
    systemctl() { return 0; }
    export -f systemctl

    export HOME="$TEST_TEMP_DIR"
    mkdir -p "$TEST_TEMP_DIR/.config/systemd/user"

    run _service_uninstall
    [ "$status" -eq 0 ]
    [[ "$output" == *"見つかりませんでした"* ]]
}

# =============================================================================
# enable / disable
# =============================================================================

@test "enable: セッション名なしでエラー" {
    systemctl() { return 0; }
    export -f systemctl

    run _service_enable
    [ "$status" -eq 1 ]
    [[ "$output" == *"セッション名を指定"* ]]
}

@test "disable: セッション名なしでエラー" {
    systemctl() { return 0; }
    export -f systemctl

    run _service_disable
    [ "$status" -eq 1 ]
    [[ "$output" == *"セッション名を指定"* ]]
}

# =============================================================================
# start / stop / restart
# =============================================================================

@test "start: セッション名なしでエラー" {
    systemctl() { return 0; }
    export -f systemctl

    run _service_start
    [ "$status" -eq 1 ]
    [[ "$output" == *"セッション名を指定"* ]]
}

@test "stop: セッション名なしでエラー" {
    systemctl() { return 0; }
    export -f systemctl

    run _service_stop
    [ "$status" -eq 1 ]
    [[ "$output" == *"セッション名を指定"* ]]
}

@test "restart: セッション名なしでエラー" {
    systemctl() { return 0; }
    export -f systemctl

    run _service_restart
    [ "$status" -eq 1 ]
    [[ "$output" == *"セッション名を指定"* ]]
}

# =============================================================================
# status
# =============================================================================

@test "status: セッション指定なしで全サービス一覧" {
    systemctl() {
        if [[ "$*" == *"list-units"* ]]; then
            echo "ignite@test.service loaded active running IGNITE test"
            return 0
        fi
        return 0
    }
    export -f systemctl

    run _service_status
    [ "$status" -eq 0 ]
    [[ "$output" == *"サービス状態"* ]]
}

# =============================================================================
# setup-env
# =============================================================================

@test "setup-env: 環境変数ファイルが生成される" {
    export IGNITE_CONFIG_DIR="$TEST_TEMP_DIR/ignite_config"

    run _service_setup_env </dev/null
    [ "$status" -eq 0 ]
    [ -f "$TEST_TEMP_DIR/ignite_config/env" ]
    [[ "$output" == *"環境変数ファイルを作成しました"* ]]
}

@test "setup-env: パーミッションが 600 になる" {
    export IGNITE_CONFIG_DIR="$TEST_TEMP_DIR/ignite_config"

    run _service_setup_env </dev/null
    [ "$status" -eq 0 ]

    local perms
    perms=$(stat -c '%a' "$TEST_TEMP_DIR/ignite_config/env")
    [ "$perms" = "600" ]
}

@test "setup-env: --force で上書き" {
    export IGNITE_CONFIG_DIR="$TEST_TEMP_DIR/ignite_config"
    mkdir -p "$TEST_TEMP_DIR/ignite_config"
    echo "old" > "$TEST_TEMP_DIR/ignite_config/env"

    run _service_setup_env --force </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"環境変数ファイルを作成しました"* ]]

    local content
    content=$(cat "$TEST_TEMP_DIR/ignite_config/env")
    [[ "$content" == *"ANTHROPIC_API_KEY"* ]]
}

# =============================================================================
# E2E lifecycle（systemd 実環境）
# =============================================================================

@test "lifecycle: install → enable → disable → uninstall" {
    # systemctl --user が使えない環境ではスキップ
    if ! systemctl --user status &>/dev/null; then
        skip "systemctl --user is not available"
    fi

    export HOME="$TEST_TEMP_DIR"
    PROJECT_ROOT="$TEST_TEMP_DIR"
    mkdir -p "$TEMPLATE_DIR"
    cp "$PROJECT_ROOT_ORIG/templates/systemd/ignite@.service" "$TEMPLATE_DIR/"

    # install
    run _service_install
    [ "$status" -eq 0 ]
    [ -f "$TEST_TEMP_DIR/.config/systemd/user/ignite@.service" ]

    # enable
    run _service_enable "bats-test-$$"
    [ "$status" -eq 0 ]

    # disable
    run _service_disable "bats-test-$$"
    [ "$status" -eq 0 ]

    # uninstall
    run _service_uninstall
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_TEMP_DIR/.config/systemd/user/ignite@.service" ]
}

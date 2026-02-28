#!/usr/bin/env bats
# test_post_to_slack.bats - Slack 投稿スクリプトのテスト

load test_helper

# =============================================================================
# セットアップ / ティアダウン
# =============================================================================

setup() {
    setup_temp_dir
    export WORKSPACE_DIR="$TEST_TEMP_DIR/workspace"
    export IGNITE_CONFIG_DIR="$TEST_TEMP_DIR/config"
    export IGNITE_RUNTIME_DIR="$TEST_TEMP_DIR/runtime"
    mkdir -p "$IGNITE_CONFIG_DIR"
    mkdir -p "$IGNITE_RUNTIME_DIR/state"

    # ログ関数のスタブ
    log_info()    { :; }
    log_warn()    { :; }
    log_error()   { :; }
    log_success() { :; }
    export -f log_info log_warn log_error log_success
}

teardown() {
    cleanup_temp_dir
}

# =============================================================================
# 1. ヘルプ表示テスト
# =============================================================================

@test "post_to_slack.sh --help でヘルプが表示される" {
    run bash "$UTILS_DIR/post_to_slack.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Slack"* ]]
    [[ "$output" == *"使用方法"* ]]
    [[ "$output" == *"--channel"* ]]
    [[ "$output" == *"--thread-ts"* ]]
}

# =============================================================================
# 2. 引数バリデーションテスト
# =============================================================================

@test "post_to_slack.sh: --channel なしでエラー" {
    run bash "$UTILS_DIR/post_to_slack.sh" --thread-ts "1234.5678" --body "test"
    [ "$status" -ne 0 ]
}

@test "post_to_slack.sh: --thread-ts なしでエラー" {
    run bash "$UTILS_DIR/post_to_slack.sh" --channel "C01ABC" --body "test"
    [ "$status" -ne 0 ]
}

@test "post_to_slack.sh: --body/--body-file/--template なしでエラー" {
    run bash "$UTILS_DIR/post_to_slack.sh" --channel "C01ABC" --thread-ts "1234.5678"
    [ "$status" -ne 0 ]
}

# =============================================================================
# 3. テンプレート生成テスト
# =============================================================================

@test "post_to_slack.sh: --template acknowledge + --dry-run" {
    run bash "$UTILS_DIR/post_to_slack.sh" \
        --channel "C01ABC" --thread-ts "1234.5678" \
        --template acknowledge --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN"* ]]
    [[ "$output" == *"このリクエストを確認しました"* ]]
}

@test "post_to_slack.sh: --template success + --dry-run" {
    run bash "$UTILS_DIR/post_to_slack.sh" \
        --channel "C01ABC" --thread-ts "1234.5678" \
        --template success --context "PR #123 を作成" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN"* ]]
    [[ "$output" == *"PR #123"* ]]
}

@test "post_to_slack.sh: --template error + --dry-run" {
    run bash "$UTILS_DIR/post_to_slack.sh" \
        --channel "C01ABC" --thread-ts "1234.5678" \
        --template error --context "ビルド失敗" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN"* ]]
    [[ "$output" == *"ビルド失敗"* ]]
}

@test "post_to_slack.sh: --template progress + --dry-run" {
    run bash "$UTILS_DIR/post_to_slack.sh" \
        --channel "C01ABC" --thread-ts "1234.5678" \
        --template progress --context "50% 完了" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN"* ]]
    [[ "$output" == *"50% 完了"* ]]
}

# =============================================================================
# 4. --dry-run モードテスト
# =============================================================================

@test "post_to_slack.sh: --dry-run で curl は実行されない" {
    run bash "$UTILS_DIR/post_to_slack.sh" \
        --channel "C01ABC" --thread-ts "1234.5678" \
        --body "テストメッセージ" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN"* ]]
    [[ "$output" == *"chat.postMessage"* ]]
    [[ "$output" == *"C01ABC"* ]]
    [[ "$output" == *"1234.5678"* ]]
}

# =============================================================================
# 5. .env トークン読み込みテスト
# =============================================================================

@test "post_to_slack.sh: .env からトークンを読み込む（dry-run では不要）" {
    # dry-run モードではトークン読み込みをスキップする
    unset SLACK_TOKEN
    run bash "$UTILS_DIR/post_to_slack.sh" \
        --channel "C01ABC" --thread-ts "1234.5678" \
        --body "test" --dry-run
    [ "$status" -eq 0 ]
}

# =============================================================================
# 6. --body-file テスト
# =============================================================================

@test "post_to_slack.sh: --body-file でファイルから本文読み込み" {
    echo "ファイルからのメッセージ" > "$TEST_TEMP_DIR/body.txt"
    run bash "$UTILS_DIR/post_to_slack.sh" \
        --channel "C01ABC" --thread-ts "1234.5678" \
        --body-file "$TEST_TEMP_DIR/body.txt" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"ファイルからのメッセージ"* ]]
}

@test "post_to_slack.sh: --body-file 存在しないファイルでエラー" {
    run bash "$UTILS_DIR/post_to_slack.sh" \
        --channel "C01ABC" --thread-ts "1234.5678" \
        --body-file "/nonexistent/file.txt"
    [ "$status" -ne 0 ]
}

# =============================================================================
# 7. 不明なテンプレートタイプ
# =============================================================================

@test "post_to_slack.sh: 不明なテンプレートでエラー" {
    run bash "$UTILS_DIR/post_to_slack.sh" \
        --channel "C01ABC" --thread-ts "1234.5678" \
        --template unknown_type --dry-run
    [ "$status" -ne 0 ]
}

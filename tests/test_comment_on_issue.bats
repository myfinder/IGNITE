#!/usr/bin/env bats
# test_comment_on_issue.bats - comment_on_issue.sh べき等性チェックテスト
#
# Issue #261: コメント重複投稿防止の検証

load test_helper

setup() {
    setup_temp_dir
    export WORKSPACE_DIR="$TEST_TEMP_DIR/workspace"
    export IGNITE_RUNTIME_DIR="$WORKSPACE_DIR"
    mkdir -p "$IGNITE_RUNTIME_DIR/state"

    # ログ関数スタブ
    log_info() { echo "INFO: $*" >&2; }
    log_warn() { echo "WARN: $*" >&2; }
    log_error() { echo "ERROR: $*" >&2; }
    export -f log_info log_warn log_error

    # get_bot_token スタブ
    get_bot_token() { echo "ghs_fake_token_for_test"; }
    export -f get_bot_token

    # gh api モックディレクトリ
    mkdir -p "$TEST_TEMP_DIR/mock_bin"

    # comment_on_issue.sh から _is_duplicate_comment と post_comment を抽出
    eval "$(sed -n '/_is_duplicate_comment()/,/^}/p' "$SCRIPTS_DIR/utils/comment_on_issue.sh")"
    eval "$(sed -n '/^post_comment()/,/^}/p' "$SCRIPTS_DIR/utils/comment_on_issue.sh")"
}

teardown() {
    cleanup_temp_dir
}

# =============================================================================
# ヘルパー: ghモック作成
# =============================================================================

_create_gh_mock() {
    local response="$1"
    cat > "$TEST_TEMP_DIR/mock_bin/gh" << GHEOF
#!/bin/bash
echo '$response'
GHEOF
    chmod +x "$TEST_TEMP_DIR/mock_bin/gh"
    export PATH="$TEST_TEMP_DIR/mock_bin:$PATH"
}

_create_gh_mock_post_tracker() {
    # GET: 既存コメントを返す、POST: 投稿をファイルに記録
    local get_response="$1"
    cat > "$TEST_TEMP_DIR/mock_bin/gh" << GHEOF
#!/bin/bash
if [[ "\$*" == *"-f body="* ]]; then
    echo "posted" > "$TEST_TEMP_DIR/post_called"
    echo '{"id":999}'
elif [[ "\$*" == *"--paginate"* ]]; then
    echo '$get_response'
else
    echo '$get_response'
fi
GHEOF
    chmod +x "$TEST_TEMP_DIR/mock_bin/gh"
    export PATH="$TEST_TEMP_DIR/mock_bin:$PATH"
}

_create_gh_mock_error() {
    cat > "$TEST_TEMP_DIR/mock_bin/gh" << 'GHEOF'
#!/bin/bash
if [[ "$*" == *"-f body="* ]]; then
    echo "posted" > "$TEST_TEMP_DIR_ENV/post_called"
    echo '{"id":999}'
else
    exit 1
fi
GHEOF
    chmod +x "$TEST_TEMP_DIR/mock_bin/gh"
    # エラーモック用に環境変数でパスを渡す
    export TEST_TEMP_DIR_ENV="$TEST_TEMP_DIR"
    export PATH="$TEST_TEMP_DIR/mock_bin:$PATH"
}

# =============================================================================
# テスト
# =============================================================================

@test "idempotency: 重複コメントが存在する場合スキップされる" {
    _create_gh_mock_post_tracker '[{"body":"既存コメント"},{"body":"テストコメント本文"}]'

    run post_comment "test/repo" "123" "テストコメント本文" "false"

    [[ "$status" -eq 0 ]]
    # 重複検出時は投稿されないこと
    [[ ! -f "$TEST_TEMP_DIR/post_called" ]]
}

@test "idempotency: 重複なしの場合通常投稿される" {
    _create_gh_mock_post_tracker '[{"body":"別のコメント"},{"body":"関係ないコメント"}]'

    run post_comment "test/repo" "123" "新規コメント" "false"

    [[ "$status" -eq 0 ]]
    [[ -f "$TEST_TEMP_DIR/post_called" ]]
}

@test "idempotency: コメント一覧取得エラー時は投稿を続行する" {
    _create_gh_mock_error

    run post_comment "test/repo" "123" "投稿内容" "false"

    [[ "$status" -eq 0 ]]
    [[ -f "$TEST_TEMP_DIR/post_called" ]]
}

@test "idempotency: Bot名義での重複チェックがBot Tokenを使用する" {
    # Bot Tokenを使うモック
    cat > "$TEST_TEMP_DIR/mock_bin/gh" << 'GHEOF'
#!/bin/bash
if [[ -n "${GH_TOKEN:-}" ]] && [[ "$GH_TOKEN" == ghs_* ]]; then
    if [[ "$*" == *"-f body="* ]]; then
        echo "posted" > "$TEST_TEMP_DIR_ENV/post_called"
        echo '{"id":999}'
    else
        echo "bot_used" > "$TEST_TEMP_DIR_ENV/bot_token_used"
        echo '[{"body":"既にある"}]'
    fi
else
    if [[ "$*" == *"-f body="* ]]; then
        echo "posted" > "$TEST_TEMP_DIR_ENV/post_called"
        echo '{"id":999}'
    else
        echo '[{"body":"既にある"}]'
    fi
fi
GHEOF
    chmod +x "$TEST_TEMP_DIR/mock_bin/gh"
    export TEST_TEMP_DIR_ENV="$TEST_TEMP_DIR"
    export PATH="$TEST_TEMP_DIR/mock_bin:$PATH"

    run post_comment "test/repo" "123" "新しいコメント" "true"

    [[ "$status" -eq 0 ]]
    [[ -f "$TEST_TEMP_DIR/bot_token_used" ]]
}

@test "idempotency: 前後の空白差異は吸収される" {
    _create_gh_mock_post_tracker '[{"body":"  テストコメント  \n"}]'

    run post_comment "test/repo" "123" "テストコメント" "false"

    [[ "$status" -eq 0 ]]
    # 空白差異を吸収して重複と判定するため、投稿されない
    [[ ! -f "$TEST_TEMP_DIR/post_called" ]]
}

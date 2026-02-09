#!/usr/bin/env bats
# test_github_watcher.bats - github_watcher.sh process_issues() メンション検出テスト
#
# github_watcher.sh は起動時に設定ファイル読み込み・API接続等の外部依存が多いため、
# 直接 source せず、テストに必要な関数のみを抽出してテストする。

load test_helper

setup() {
    setup_temp_dir
    export WORKSPACE_DIR="$TEST_TEMP_DIR/workspace"
    mkdir -p "$WORKSPACE_DIR/queue/leader"
    mkdir -p "$WORKSPACE_DIR/state"
    export MENTION_PATTERN="@ignite-gh-app"
    export DEFAULT_MESSAGE_PRIORITY="normal"
    export IGNORE_BOT="true"
    export ACCESS_CONTROL_ENABLED="false"
    export STATE_FILE="$TEST_TEMP_DIR/state.json"
    echo '{"processed_events":{},"last_check":{}}' > "$STATE_FILE"

    # github_watcher.sh から必要な関数のみを抽出
    # ログ関数のスタブ
    log_event() { :; }
    log_success() { :; }
    log_info() { :; }
    export -f log_event log_success log_info

    # イベント処理のスタブ
    is_event_processed() { return 1; }  # 未処理として扱う
    is_human_event() { return 0; }      # 人間として扱う
    is_user_authorized() { return 0; }  # 認可済みとして扱う
    mark_event_processed() { :; }
    update_last_check() { :; }
    export -f is_event_processed is_human_event is_user_authorized mark_event_processed update_last_check

    # create_event_message: github_event YAML を生成
    create_event_message() {
        local event_type="$1" repo="$2" event_data="$3"
        local message_file="${WORKSPACE_DIR}/queue/leader/github_event_$(date +%s%6N).yaml"
        local issue_number issue_title
        issue_number=$(echo "$event_data" | jq -r '.number')
        issue_title=$(echo "$event_data" | jq -r '.title')
        cat > "$message_file" <<EVEOF
type: github_event
from: github_watcher
to: leader
payload:
  event_type: ${event_type}
  repository: ${repo}
  issue_number: ${issue_number}
  issue_title: "${issue_title}"
EVEOF
        echo "$message_file"
    }
    export -f create_event_message

    # create_task_message: github_task YAML を生成
    create_task_message() {
        local event_type="$1" repo="$2" event_data="$3" trigger_type="$4"
        local message_file="${WORKSPACE_DIR}/queue/leader/github_task_$(date +%s%6N).yaml"
        local issue_number issue_title issue_body
        issue_number=$(echo "$event_data" | jq -r '.number')
        issue_title=$(echo "$event_data" | jq -r '.title // ""')
        issue_body=$(echo "$event_data" | jq -r '.body // ""' | head -c 1000)
        cat > "$message_file" <<TKEOF
type: github_task
from: github_watcher
to: leader
priority: high
payload:
  trigger: "${trigger_type}"
  repository: ${repo}
  issue_number: ${issue_number}
  issue_title: "${issue_title}"
TKEOF
        echo "$message_file"
    }
    export -f create_task_message

    # process_issues 関数を github_watcher.sh から抽出して定義
    # sed で関数本体を抽出し eval で読み込む
    eval "$(sed -n '/^process_issues()/,/^}$/p' "$SCRIPTS_DIR/utils/github_watcher.sh")"
}

teardown() {
    cleanup_temp_dir
}

# --- テスト ---

@test "process_issues: メンション付きIssueでgithub_taskが生成される" {
    fetch_issues() {
        echo '{"id":12345,"number":999,"title":"テスト","body":"@ignite-gh-app 実装してください","author":"myfinder","author_type":"User","state":"open","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","url":"https://github.com/test/repo/issues/999"}'
    }
    export -f fetch_issues

    process_issues "test/repo"

    local task_count
    task_count=$(ls "$WORKSPACE_DIR/queue/leader/github_task_"*.yaml 2>/dev/null | wc -l)
    [[ "$task_count" -ge 1 ]]

    # trigger が "implement" であること
    grep -q 'trigger: "implement"' "$WORKSPACE_DIR/queue/leader/github_task_"*.yaml
}

@test "process_issues: メンションなしIssueでgithub_eventが生成される" {
    fetch_issues() {
        echo '{"id":12346,"number":1000,"title":"通常Issue","body":"メンションなしの通常Issue","author":"myfinder","author_type":"User","state":"open","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","url":"https://github.com/test/repo/issues/1000"}'
    }
    export -f fetch_issues

    process_issues "test/repo"

    local event_count
    event_count=$(ls "$WORKSPACE_DIR/queue/leader/github_event_"*.yaml 2>/dev/null | wc -l)
    [[ "$event_count" -ge 1 ]]

    # github_task は生成されないこと
    local task_count
    task_count=$(ls "$WORKSPACE_DIR/queue/leader/github_task_"*.yaml 2>/dev/null | wc -l)
    [[ "$task_count" -eq 0 ]]
}

@test "process_issues: reviewキーワードでtrigger_type=reviewになる" {
    fetch_issues() {
        echo '{"id":12347,"number":1001,"title":"レビュー依頼","body":"@ignite-gh-app このPRをレビューしてください","author":"myfinder","author_type":"User","state":"open","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","url":"https://github.com/test/repo/issues/1001"}'
    }
    export -f fetch_issues

    process_issues "test/repo"

    grep -q 'trigger: "review"' "$WORKSPACE_DIR/queue/leader/github_task_"*.yaml
}

@test "process_issues: body空(null)のIssueでgithub_eventが生成される" {
    fetch_issues() {
        echo '{"id":12348,"number":1002,"title":"bodyなし","body":null,"author":"myfinder","author_type":"User","state":"open","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","url":"https://github.com/test/repo/issues/1002"}'
    }
    export -f fetch_issues

    process_issues "test/repo"

    local event_count
    event_count=$(ls "$WORKSPACE_DIR/queue/leader/github_event_"*.yaml 2>/dev/null | wc -l)
    [[ "$event_count" -ge 1 ]]

    # github_task は生成されないこと
    local task_count
    task_count=$(ls "$WORKSPACE_DIR/queue/leader/github_task_"*.yaml 2>/dev/null | wc -l)
    [[ "$task_count" -eq 0 ]]
}

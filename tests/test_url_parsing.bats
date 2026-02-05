#!/usr/bin/env bats
# =============================================================================
# URLパース関数のテスト
# テスト対象: scripts/utils/create_pr.sh の parse_issue_url()
# =============================================================================

load 'test_helper'

setup() {
    setup_temp_dir

    # parse_issue_url 関数を抽出して読み込み
    # （create_pr.sh全体を読み込むと副作用があるため、関数のみ抽出）
    eval "$(sed -n '/^parse_issue_url()/,/^}/p' "$UTILS_DIR/create_pr.sh")"
}

teardown() {
    cleanup_temp_dir
}

# =============================================================================
# parse_issue_url のテスト
# =============================================================================

@test "parse_issue_url: 標準的なGitHub Issue URLをパースできる" {
    parse_issue_url "https://github.com/owner/repo/issues/123"

    [[ "$REPO" == "owner/repo" ]]
    [[ "$ISSUE_NUMBER" == "123" ]]
}

@test "parse_issue_url: 大きなIssue番号をパースできる" {
    parse_issue_url "https://github.com/myfinder/IGNITE/issues/9999"

    [[ "$REPO" == "myfinder/IGNITE" ]]
    [[ "$ISSUE_NUMBER" == "9999" ]]
}

@test "parse_issue_url: ハイフンを含むリポジトリ名をパースできる" {
    parse_issue_url "https://github.com/my-org/my-repo/issues/42"

    [[ "$REPO" == "my-org/my-repo" ]]
    [[ "$ISSUE_NUMBER" == "42" ]]
}

@test "parse_issue_url: アンダースコアを含むリポジトリ名をパースできる" {
    parse_issue_url "https://github.com/my_org/my_repo/issues/1"

    [[ "$REPO" == "my_org/my_repo" ]]
    [[ "$ISSUE_NUMBER" == "1" ]]
}

@test "parse_issue_url: 不正なURLは失敗する" {
    run parse_issue_url "https://example.com/not-github"

    [[ "$status" -eq 1 ]]
}

@test "parse_issue_url: Issue番号がないURLは失敗する" {
    run parse_issue_url "https://github.com/owner/repo/issues/"

    [[ "$status" -eq 1 ]]
}

@test "parse_issue_url: PRのURLは失敗する（issuesパスのみ対応）" {
    run parse_issue_url "https://github.com/owner/repo/pull/123"

    [[ "$status" -eq 1 ]]
}

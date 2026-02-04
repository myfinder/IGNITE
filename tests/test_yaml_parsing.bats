#!/usr/bin/env bats
# =============================================================================
# YAMLパーシング関数のテスト
# テスト対象: grep/awkベースのYAMLパース処理
# =============================================================================

load 'test_helper'

setup() {
    setup_temp_dir

    # テスト用のYAMLファイルを作成
    cat > "$TEST_TEMP_DIR/test_config.yaml" << 'EOF'
interval: 60
state_file: "workspace/state/test.json"
ignore_bot: true

repositories:
  - repo: owner/repo1
  - repo: owner/repo2
  - simple-owner/simple-repo

events:
  issues: true
  issue_comments: true
  pull_requests: false

access_control:
  enabled: true
  allowed_users:
    - user1
    - user2
    - "user3"
EOF
}

teardown() {
    cleanup_temp_dir
}

# =============================================================================
# 単純な値のパース
# =============================================================================

@test "YAML: interval値を正しくパースできる" {
    local config_file="$TEST_TEMP_DIR/test_config.yaml"
    local interval=$(grep -E '^\s*interval:' "$config_file" | head -1 | awk '{print $2}' | tr -d '"')

    [[ "$interval" == "60" ]]
}

@test "YAML: state_file値を正しくパースできる" {
    local config_file="$TEST_TEMP_DIR/test_config.yaml"
    local state_file=$(grep -E '^\s*state_file:' "$config_file" | head -1 | awk '{print $2}' | tr -d '"')

    [[ "$state_file" == "workspace/state/test.json" ]]
}

@test "YAML: boolean値(true)を正しくパースできる" {
    local config_file="$TEST_TEMP_DIR/test_config.yaml"
    local ignore_bot=$(grep -E '^\s*ignore_bot:' "$config_file" | head -1 | awk '{print $2}' | tr -d '"')

    [[ "$ignore_bot" == "true" ]]
}

@test "YAML: boolean値(false)を正しくパースできる" {
    local config_file="$TEST_TEMP_DIR/test_config.yaml"
    local pull_requests=$(grep -E '^\s*pull_requests:' "$config_file" | head -1 | awk '{print $2}' | tr -d '"')

    [[ "$pull_requests" == "false" ]]
}

# =============================================================================
# ネストした値のパース
# =============================================================================

@test "YAML: access_control.enabled を正しくパースできる" {
    local config_file="$TEST_TEMP_DIR/test_config.yaml"
    local enabled=$(awk '/^access_control:/{found=1} found && /^[[:space:]]+enabled:/{print $2; exit}' "$config_file" | tr -d '"')

    [[ "$enabled" == "true" ]]
}

# =============================================================================
# リスト値のパース
# =============================================================================

@test "YAML: repositoriesリストをパースできる" {
    local config_file="$TEST_TEMP_DIR/test_config.yaml"
    local repos=()
    local in_repos=false

    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*repositories: ]]; then
            in_repos=true
            continue
        fi
        if [[ "$in_repos" == true ]]; then
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*repo:[[:space:]]*(.+) ]]; then
                local repo="${BASH_REMATCH[1]}"
                repo=$(echo "$repo" | tr -d '"' | tr -d "'" | xargs)
                repos+=("$repo")
            elif [[ "$line" =~ ^[[:space:]]*-[[:space:]]*([^:]+)$ ]]; then
                local repo="${BASH_REMATCH[1]}"
                repo=$(echo "$repo" | tr -d '"' | tr -d "'" | xargs)
                repos+=("$repo")
            elif [[ "$line" =~ ^[[:space:]]*[a-z_]+:[[:space:]] ]]; then
                in_repos=false
            fi
        fi
    done < "$config_file"

    [[ "${#repos[@]}" -eq 3 ]]
    [[ "${repos[0]}" == "owner/repo1" ]]
    [[ "${repos[1]}" == "owner/repo2" ]]
    [[ "${repos[2]}" == "simple-owner/simple-repo" ]]
}

@test "YAML: allowed_usersリストをパースできる" {
    local config_file="$TEST_TEMP_DIR/test_config.yaml"
    local users=()
    local in_allowed=false

    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*allowed_users: ]]; then
            in_allowed=true
            continue
        fi
        if [[ "$in_allowed" == true ]]; then
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*[\"\']?([^\"\']+)[\"\']?$ ]]; then
                local user="${BASH_REMATCH[1]}"
                user=$(echo "$user" | xargs)
                [[ -n "$user" ]] && users+=("$user")
            elif [[ "$line" =~ ^[[:space:]]*[a-z_]+: ]] && [[ ! "$line" =~ ^[[:space:]]*- ]]; then
                in_allowed=false
            fi
        fi
    done < "$config_file"

    [[ "${#users[@]}" -eq 3 ]]
    [[ "${users[0]}" == "user1" ]]
    [[ "${users[1]}" == "user2" ]]
    [[ "${users[2]}" == "user3" ]]
}

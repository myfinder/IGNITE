#!/bin/bash
# GitHub イベント監視デーモン
# 定期的にGitHub APIをポーリングしてイベントを検知し、
# 新規イベントを workspace/queue/ に投入します

set -e
set -u

# スクリプトのディレクトリを取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/core.sh"
source "${SCRIPT_DIR}/../lib/cli_provider.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# WORKSPACE_DIR が未設定の場合、IGNITE_WORKSPACE_DIR からフォールバック
WORKSPACE_DIR="${WORKSPACE_DIR:-${IGNITE_WORKSPACE_DIR:-}}"
[[ -n "${WORKSPACE_DIR:-}" ]] && setup_workspace_config "$WORKSPACE_DIR"
cli_load_config 2>/dev/null || true

# YAMLユーティリティ
source "${SCRIPT_DIR}/../lib/yaml_utils.sh"

# Watcher共通ライブラリ
source "${SCRIPT_DIR}/../lib/watcher_common.sh"

# Bot Token / GitHub API 共通関数の読み込み
source "${SCRIPT_DIR}/github_helpers.sh"

# MIMEメッセージ構築ツール
IGNITE_MIME="${SCRIPT_DIR}/../lib/ignite_mime.py"

# デフォルト設定
DEFAULT_INTERVAL=60
DEFAULT_STATE_FILE="workspace/state/github_watcher_state.json"
DEFAULT_CONFIG_FILE="github-watcher.yaml"

# ハートビート設定
HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-10}"  # デフォルト10秒
WATCHER_HEARTBEAT_FILE="${IGNITE_RUNTIME_DIR:-}/state/github_watcher_heartbeat.json"
WATCHER_LOCK_FILE="${IGNITE_RUNTIME_DIR:-}/state/github_watcher.lock"

# シグナル制御フラグは watcher_common.sh の _WATCHER_* 変数を使用
# 後方互換エイリアス（process_events等から参照される場合に備える）
# 注意: 実際の制御は watcher_common.sh の _WATCHER_SHUTDOWN_REQUESTED 等が担当

# スクリプト固有ログ（core.sh の log_* はカラー・タイムスタンプ付きで提供済み）
log_event() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${CYAN}[EVENT]${NC} $1" >&2; }

# =============================================================================
# 外部データサニタイズ（watcher_common.sh に委譲）
# =============================================================================

# 後方互換ラッパー: watcher_common.sh の _watcher_sanitize_input() に委譲
_sanitize_external_input() { _watcher_sanitize_input "$@"; }

# =============================================================================
# 設定読み込み
# =============================================================================

# =============================================================================
# 関数名: load_config
# 目的: 設定ファイル(github-watcher.yaml)からGitHub Watcher設定を読み込む
# 引数: なし（環境変数 IGNITE_WATCHER_CONFIG または IGNITE_CONFIG_DIR を参照）
# 戻り値: なし（グローバル変数を設定）
# 副作用:
#   - POLL_INTERVAL: ポーリング間隔（秒）
#   - STATE_FILE: 処理済みイベントの状態ファイルパス
#   - REPOSITORIES: 監視対象リポジトリの配列
#   - WATCH_*: 各イベントタイプの監視フラグ
#   - MENTION_PATTERN: メンショントリガーパターン
#   - WORKSPACE_DIR: ワークスペースディレクトリパス
#   - ACCESS_CONTROL_ENABLED: アクセス制御の有効/無効
#   - ALLOWED_USERS: 許可ユーザーの配列
# 注意:
#   - YAMLパーサーではなく grep/awk で簡易的にパースしている
#   - 複雑なYAML構造には対応していない
# =============================================================================
load_config() {
    local config_file="${IGNITE_WATCHER_CONFIG:-${IGNITE_CONFIG_DIR}/${DEFAULT_CONFIG_FILE}}"

    if [[ ! -f "$config_file" ]]; then
        log_error "設定ファイルが見つかりません: $config_file"
        echo ""
        echo "設定ファイルを作成してください:"
        echo "  cp config/github-watcher.yaml.example config/github-watcher.yaml"
        exit 1
    fi

    # YAMLから設定を読み込み
    POLL_INTERVAL=$(yaml_get "$config_file" 'interval')
    POLL_INTERVAL=${POLL_INTERVAL:-$DEFAULT_INTERVAL}

    STATE_FILE=$(yaml_get "$config_file" 'state_file')
    STATE_FILE=${STATE_FILE:-$DEFAULT_STATE_FILE}
    # state_file が "workspace/..." で始まる場合は "workspace/" を除去
    STATE_FILE="${STATE_FILE#workspace/}"
    # IGNITE_RUNTIME_DIR (.ignite/) 配下に配置
    STATE_FILE="${IGNITE_RUNTIME_DIR:-${WORKSPACE_DIR:+${WORKSPACE_DIR}/.ignite}}/${STATE_FILE}"

    IGNORE_BOT=$(yaml_get "$config_file" 'ignore_bot')
    IGNORE_BOT=${IGNORE_BOT:-true}

    PATTERN_REFRESH_INTERVAL=$(yaml_get "$config_file" 'pattern_refresh_interval')
    PATTERN_REFRESH_INTERVAL=${PATTERN_REFRESH_INTERVAL:-60}

    # 監視対象リポジトリを取得
    REPOSITORIES=()
    REPO_PATTERNS=()   # グローバル（定期リフレッシュで再利用）
    if [[ "$_YQ_AVAILABLE" -eq 1 ]]; then
        # yq版: 構造化パース
        mapfile -t REPO_PATTERNS < <(yq -r '.watcher.repositories[] | select(has("pattern")) | .pattern' "$config_file" 2>/dev/null)
        mapfile -t REPOSITORIES < <(yq -r '.watcher.repositories[] | select(has("repo")) | .repo' "$config_file" 2>/dev/null)
        local simple_repos=()
        mapfile -t simple_repos < <(yq -r '.watcher.repositories[] | select(type == "!!str")' "$config_file" 2>/dev/null)
        REPOSITORIES+=("${simple_repos[@]}")
    else
        # フォールバック: 行ベースパース
        local in_repos=false
        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]*repositories: ]]; then
                in_repos=true
                continue
            fi
            if [[ "$in_repos" == true ]]; then
                if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*pattern:[[:space:]]*(.+) ]]; then
                    local pat="${BASH_REMATCH[1]}"
                    pat=$(echo "$pat" | tr -d '"' | tr -d "'" | xargs)
                    REPO_PATTERNS+=("$pat")
                elif [[ "$line" =~ ^[[:space:]]*-[[:space:]]*repo:[[:space:]]*(.+) ]]; then
                    local repo="${BASH_REMATCH[1]}"
                    repo=$(echo "$repo" | tr -d '"' | tr -d "'" | xargs)
                    REPOSITORIES+=("$repo")
                elif [[ "$line" =~ ^[[:space:]]*-[[:space:]]*([^:]+)$ ]]; then
                    local repo="${BASH_REMATCH[1]}"
                    repo=$(echo "$repo" | tr -d '"' | tr -d "'" | xargs)
                    REPOSITORIES+=("$repo")
                elif [[ "$line" =~ ^[[:space:]]*[a-z_]+:[[:space:]] ]] && [[ ! "$line" =~ ^[[:space:]]*base_branch: ]]; then
                    in_repos=false
                fi
            fi
        done < "$config_file"
    fi

    # イベントタイプ設定
    WATCH_ISSUES=$(yaml_get "$config_file" 'issues')
    WATCH_ISSUES=${WATCH_ISSUES:-true}

    WATCH_ISSUE_COMMENTS=$(yaml_get "$config_file" 'issue_comments')
    WATCH_ISSUE_COMMENTS=${WATCH_ISSUE_COMMENTS:-true}

    WATCH_PRS=$(yaml_get "$config_file" 'pull_requests')
    WATCH_PRS=${WATCH_PRS:-true}

    WATCH_PR_COMMENTS=$(yaml_get "$config_file" 'pr_comments')
    WATCH_PR_COMMENTS=${WATCH_PR_COMMENTS:-true}

    WATCH_PR_REVIEWS=$(yaml_get "$config_file" 'pr_reviews')
    WATCH_PR_REVIEWS=${WATCH_PR_REVIEWS:-true}

    # トリガー設定
    MENTION_PATTERN=$(yaml_get "$config_file" 'mention_pattern')
    MENTION_PATTERN=${MENTION_PATTERN:-"@ignite-gh-app"}

    # ワークスペース設定
    # IGNITE_WORKSPACE_DIR が設定されていればそれを使用（インストールモード対応）
    if [[ -n "${IGNITE_WORKSPACE_DIR:-}" ]]; then
        WORKSPACE_DIR="$IGNITE_WORKSPACE_DIR"
    else
        WORKSPACE_DIR=$(yaml_get "$config_file" 'workspace')
        WORKSPACE_DIR=${WORKSPACE_DIR:-"workspace"}
        if [[ "$WORKSPACE_DIR" != /* ]]; then
            WORKSPACE_DIR="${PROJECT_ROOT}/${WORKSPACE_DIR}"
        fi
    fi

    # アクセス制御設定
    ACCESS_CONTROL_ENABLED=$(yaml_get_nested "$config_file" '.access_control.enabled')
    ACCESS_CONTROL_ENABLED=${ACCESS_CONTROL_ENABLED:-false}

    # 許可ユーザーリストの読み込み
    ALLOWED_USERS=()
    if [[ "$_YQ_AVAILABLE" -eq 1 ]]; then
        mapfile -t ALLOWED_USERS < <(yaml_get_list "$config_file" '.access_control.allowed_users')
    else
        # フォールバック: 行ベースパース
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
                    [[ -n "$user" ]] && ALLOWED_USERS+=("$user")
                elif [[ "$line" =~ ^[[:space:]]*[a-z_]+: ]] && [[ ! "$line" =~ ^[[:space:]]*- ]]; then
                    in_allowed=false
                fi
            fi
        done < "$config_file"
    fi

    # ワイルドカードパターンを展開
    if [[ ${#REPO_PATTERNS[@]} -gt 0 ]]; then
        expand_patterns "${REPO_PATTERNS[@]}"
    fi

    # system.yaml からデフォルトメッセージ優先度を取得
    local system_yaml="${IGNITE_CONFIG_DIR}/system.yaml"
    DEFAULT_MESSAGE_PRIORITY=$(sed -n '/^defaults:/,/^[^ ]/p' "$system_yaml" 2>/dev/null \
        | awk -F': ' '/^  message_priority:/{print $2; exit}' | tr -d '"' | tr -d "'")
    DEFAULT_MESSAGE_PRIORITY="${DEFAULT_MESSAGE_PRIORITY:-normal}"
}

# ワイルドカードパターンをリポジトリ一覧に展開
# グローバル REPOSITORIES 配列に追加する
expand_patterns() {
    local patterns=("$@")

    for pat in "${patterns[@]}"; do
        # owner/pattern 形式からorgを抽出
        local org="${pat%%/*}"
        local name_pattern="${pat#*/}"

        log_info "パターン展開中: $pat"

        # Organization API でリポジトリ一覧を取得（org → user フォールバック）
        local repos=""
        repos=$(github_api_paginate "" "/orgs/${org}/repos" | jq -r '.[].full_name') || \
        repos=$(github_api_paginate "" "/users/${org}/repos" | jq -r '.[].full_name') || {
            log_warn "リポジトリ一覧の取得に失敗: $org"
            continue
        }

        # glob マッチングでフィルタ
        local match_count=0
        while IFS= read -r repo; do
            [[ -z "$repo" ]] && continue
            local repo_name="${repo#*/}"
            # shellcheck disable=SC2053  # 意図的な glob マッチング
            if [[ "$repo_name" == $name_pattern ]]; then
                # 重複チェック
                local dup=false
                for existing in "${REPOSITORIES[@]}"; do
                    if [[ "$existing" == "$repo" ]]; then
                        dup=true
                        break
                    fi
                done
                if [[ "$dup" == false ]]; then
                    REPOSITORIES+=("$repo")
                    match_count=$((match_count + 1))
                fi
            fi
        done <<< "$repos"

        log_info "パターン '$pat' → ${match_count} リポジトリにマッチ"
    done
}

# =============================================================================
# ステート管理（watcher_common.sh に委譲）
# =============================================================================

# 後方互換ラッパー: STATE_FILE を _WATCHER_STATE_FILE にブリッジして委譲
init_state() {
    _WATCHER_STATE_FILE="$STATE_FILE"
    mkdir -p "$(dirname "$STATE_FILE")"
    if [[ ! -f "$STATE_FILE" ]]; then
        local now
        now=$(date -Iseconds)
        echo "{\"processed_events\":{},\"last_check\":{},\"initialized_at\":\"$now\"}" > "$STATE_FILE"
        log_info "新規ステートファイル作成: $now 以降のイベントを監視"
    fi
}

# 初期化時刻を取得（sinceパラメータのフォールバック用）
# GitHub固有: fetch_*() が since パラメータに使用
get_initialized_at() {
    jq -r '.initialized_at // empty' "$STATE_FILE" 2>/dev/null
}

# =============================================================================
# 関数名: to_utc
# 目的: ローカルタイムゾーンのISO 8601形式タイムスタンプをUTC形式に変換する
# 引数:
#   $1 - 変換元のタイムスタンプ（例: "2024-01-01T12:00:00+09:00"）
# 戻り値: UTC形式のタイムスタンプ（例: "2024-01-01T03:00:00Z"）
# 注意:
#   - GitHub APIは since パラメータにUTC形式を要求するため必要
#   - GNU date (Linux) と BSD date (macOS) の両方に対応
#   - GNU date: date -d で入力形式を自動認識
#   - BSD date: -j -f で入力形式を明示的に指定
# =============================================================================
to_utc() {
    local timestamp="$1"
    if [[ -z "$timestamp" ]]; then
        echo ""
        return
    fi
    # date コマンドでUTC変換（GNU date と BSD date の両方に対応）
    if date --version &>/dev/null; then
        # GNU date
        date -u -d "$timestamp" -Iseconds 2>/dev/null | sed 's/+00:00$/Z/'
    else
        # BSD date (macOS)
        date -u -j -f "%Y-%m-%dT%H:%M:%S%z" "$timestamp" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null
    fi
}

# 後方互換ラッパー: watcher_common.sh の共通関数に委譲
is_event_processed() { watcher_is_event_processed "$@"; }
mark_event_processed() { watcher_mark_event_processed "$@"; }

# update_last_check は引数形式を維持（repo, event_type → "repo_event_type" キーに変換）
update_last_check() {
    local repo="$1"
    local event_type="$2"
    watcher_update_last_check "${repo}_${event_type}"
}

cleanup_old_events() { watcher_cleanup_old_events; }

# =============================================================================
# ハートビート
# =============================================================================

# _write_watcher_heartbeat
# queue_monitor の _write_heartbeat() と同一 JSON 形式でハートビートを書き込む
# アトミック書き込み: 一時ファイル + mv でファイル破損を防止
_write_watcher_heartbeat() {
    # IGNITE_RUNTIME_DIR が未設定の場合はスキップ
    [[ -z "${IGNITE_RUNTIME_DIR:-}" ]] && return 0

    local state_dir="${IGNITE_RUNTIME_DIR}/state"
    mkdir -p "$state_dir" 2>/dev/null || true

    # ハートビートファイルパスを更新（IGNITE_RUNTIME_DIR がload_config後に変わる可能性）
    WATCHER_HEARTBEAT_FILE="${state_dir}/github_watcher_heartbeat.json"

    local timestamp
    timestamp=$(date -Iseconds)

    # queue_monitor と同一 JSON 形式: {"timestamp":"...","resume_token":"...","session":"..."}
    # resume_token は queue_monitor のハートビートとスキーマを統一するため空文字列を維持
    local tmp_file
    tmp_file=$(mktemp "${state_dir}/.watcher_heartbeat.XXXXXX") || return 0
    printf '{"timestamp":"%s","resume_token":"%s","session":"%s"}\n' \
        "$timestamp" "" "${IGNITE_SESSION:-}" \
        > "$tmp_file"
    mv "$tmp_file" "$WATCHER_HEARTBEAT_FILE" 2>/dev/null || rm -f "$tmp_file"
}

# =============================================================================
# Bot判別
# =============================================================================

is_human_event() {
    local author_type="$1"
    local author_login="$2"

    # User タイプで、かつ [bot] サフィックスがない場合のみtrue
    [[ "$author_type" == "User" ]] && [[ ! "$author_login" =~ \[bot\]$ ]]
}

# =============================================================================
# アクセス制御
# =============================================================================

# ユーザーがタスクをトリガーする権限があるかチェック
is_user_authorized() {
    local username="$1"

    # アクセス制御が無効の場合は全員許可
    if [[ "$ACCESS_CONTROL_ENABLED" != "true" ]]; then
        return 0
    fi

    # 許可リストが空の場合は全員許可（設定ミス防止）
    if [[ ${#ALLOWED_USERS[@]} -eq 0 ]]; then
        log_warn "アクセス制御が有効ですが allowed_users が空です。全員許可します"
        return 0
    fi

    # ユーザー名を小文字で比較（GitHubは大文字小文字を区別しない）
    local username_lower
    username_lower=$(echo "$username" | tr '[:upper:]' '[:lower:]')

    for user in "${ALLOWED_USERS[@]}"; do
        local user_lower
        user_lower=$(echo "$user" | tr '[:upper:]' '[:lower:]')
        if [[ "$user_lower" == "$username_lower" ]]; then
            return 0
        fi
    done

    return 1
}

# =============================================================================
# イベント取得
# =============================================================================

# get_bot_token() は github_helpers.sh から提供（キャッシュ + リトライ機構付き）

# Issueイベントを取得
fetch_issues() {
    local repo="$1"
    local since=""

    # 最終チェック時刻があれば使用、なければ初期化時刻を使用
    since=$(jq -r ".last_check[\"${repo}_issues\"] // .initialized_at // empty" "$STATE_FILE")
    # GitHub APIはUTC形式を要求するので変換
    since=$(to_utc "$since")

    local api_url="/repos/${repo}/issues?state=all&sort=created&direction=desc&per_page=30"
    if [[ -n "$since" ]]; then
        api_url="${api_url}&since=${since}"
    fi

    github_api_get "$repo" "$api_url" | jq -c '.[] | select(.pull_request == null) | {
            id: .id,
            number: .number,
            title: .title,
            body: .body,
            author: .user.login,
            author_type: .user.type,
            state: .state,
            created_at: .created_at,
            updated_at: .updated_at,
            url: .html_url
        }' 2>/dev/null || echo ""
}

# Issueコメントを取得
fetch_issue_comments() {
    local repo="$1"
    local since=""

    # 最終チェック時刻があれば使用、なければ初期化時刻を使用
    since=$(jq -r ".last_check[\"${repo}_issue_comments\"] // .initialized_at // empty" "$STATE_FILE")
    # GitHub APIはUTC形式を要求するので変換
    since=$(to_utc "$since")

    local api_url="/repos/${repo}/issues/comments?sort=created&direction=desc&per_page=30"
    if [[ -n "$since" ]]; then
        api_url="${api_url}&since=${since}"
    fi

    github_api_get "$repo" "$api_url" | jq -c '.[] | {
            id: .id,
            issue_number: (.issue_url | split("/") | last | tonumber),
            body: .body,
            author: .user.login,
            author_type: .user.type,
            created_at: .created_at,
            url: .html_url
        }' 2>/dev/null || echo ""
}

# PRイベントを取得
fetch_prs() {
    local repo="$1"
    local since=""

    # 最終チェック時刻があれば使用、なければ初期化時刻を使用
    since=$(jq -r ".last_check[\"${repo}_prs\"] // .initialized_at // empty" "$STATE_FILE")

    # PRs API は since パラメータをサポートしていないので、
    # 取得後に created_at でフィルタリングする
    # 注: updated_at は考慮していないが、既存PRへの更新（コメント追加等）は
    #     fetch_pr_comments() で別途取得するため問題ない
    github_api_get "$repo" "/repos/${repo}/pulls?state=open&sort=created&direction=desc&per_page=30" | jq -c --arg since "${since:-1970-01-01T00:00:00Z}" '.[] | select(.created_at >= $since) | {
            id: .id,
            number: .number,
            title: .title,
            body: .body,
            author: .user.login,
            author_type: .user.type,
            state: .state,
            created_at: .created_at,
            updated_at: .updated_at,
            url: .html_url,
            head_ref: .head.ref,
            base_ref: .base.ref
        }' 2>/dev/null || echo ""
}

# PRコメントを取得（レビューコメントも含む）
fetch_pr_comments() {
    local repo="$1"
    local since=""

    # 最終チェック時刻があれば使用、なければ初期化時刻を使用
    since=$(jq -r ".last_check[\"${repo}_pr_comments\"] // .initialized_at // empty" "$STATE_FILE")
    # GitHub APIはUTC形式を要求するので変換
    since=$(to_utc "$since")

    local api_url="/repos/${repo}/pulls/comments?sort=created&direction=desc&per_page=30"
    if [[ -n "$since" ]]; then
        api_url="${api_url}&since=${since}"
    fi

    github_api_get "$repo" "$api_url" | jq -c '.[] | {
            id: .id,
            pr_number: (.pull_request_url | split("/") | last | tonumber),
            body: .body,
            author: .user.login,
            author_type: .user.type,
            created_at: .created_at,
            url: .html_url,
            path: .path,
            line: .line
        }' 2>/dev/null || echo ""
}

# PRレビューを取得（Approve/Request changes/Comment）
fetch_pr_reviews() {
    local repo="$1"
    local since=""

    # 最終チェック時刻があれば使用、なければ初期化時刻を使用
    since=$(jq -r ".last_check[\"${repo}_pr_reviews\"] // .initialized_at // empty" "$STATE_FILE")
    since=${since:-"1970-01-01T00:00:00Z"}
    # GitHub APIはUTC形式を要求するので変換
    since=$(to_utc "$since")

    # オープンなPRを取得してレビューをチェック
    local open_prs
    open_prs=$(github_api_get "$repo" "/repos/${repo}/pulls?state=open&per_page=30" | jq -r '.[].number' 2>/dev/null || echo "")

    [[ -z "$open_prs" ]] && return

    for pr_number in $open_prs; do
        local reviews_json
        reviews_json=$(github_api_get "$repo" "/repos/${repo}/pulls/${pr_number}/reviews" || echo "[]")
        # bodyが空でも取得（コード行コメントのみのレビューも検知するため）
        jq -c --arg since "$since" --arg pr_number "$pr_number" \
            '.[] | select(.submitted_at >= $since) | {
                id: .id,
                pr_number: ($pr_number | tonumber),
                body: (.body // ""),
                author: .user.login,
                author_type: .user.type,
                state: .state,
                submitted_at: .submitted_at,
                url: .html_url
            }' <(printf '%s' "$reviews_json") 2>/dev/null || true
    done
}

# PRレビューに紐づくコメント（コード行へのコメント）を取得
fetch_pr_review_comments() {
    local repo="$1"
    local pr_number="$2"
    local review_id="$3"

    github_api_get "$repo" "/repos/${repo}/pulls/${pr_number}/reviews/${review_id}/comments" | jq -r '.[] | .body' 2>/dev/null | tr '\n' ' ' || echo ""
}

# =============================================================================
# メッセージ生成
# =============================================================================

create_event_message() {
    local event_type="$1"
    local repo="$2"
    local event_data="$3"

    local timestamp
    timestamp=$(date -Iseconds)
    local message_id
    message_id=$(date +%s%6N)
    local queue_dir="${IGNITE_RUNTIME_DIR}/queue/leader"
    # IGNITE_MIME はファイルスコープで定義済み

    mkdir -p "$queue_dir"

    local message_file="${queue_dir}/github_event_${message_id}.mime"

    # イベントタイプに応じてボディYAMLを構築
    local body_yaml=""
    local issue_val=""
    case "$event_type" in
        issue_created|issue_updated)
            local issue_number issue_title issue_body author author_type url
            issue_number=$(echo "$event_data" | jq -r '.number')
            issue_title=$(_sanitize_external_input "$(echo "$event_data" | jq -r '.title')" 256)
            issue_body=$(_sanitize_external_input "$(echo "$event_data" | jq -r '.body // ""' | head -c 1000)" 10000)
            author=$(_sanitize_external_input "$(echo "$event_data" | jq -r '.author')" 128)
            author_type=$(echo "$event_data" | jq -r '.author_type')
            url=$(echo "$event_data" | jq -r '.url')
            issue_val="$issue_number"
            body_yaml="event_type: ${event_type}
issue_number: ${issue_number}
issue_title: \"${issue_title//\"/\\\"}\"
author: ${author}
author_type: ${author_type}
body: |
$(echo "$issue_body" | sed 's/^/  /')
url: \"${url}\""
            ;;

        issue_comment)
            local issue_number comment_id body author author_type url
            issue_number=$(echo "$event_data" | jq -r '.issue_number')
            comment_id=$(echo "$event_data" | jq -r '.id')
            body=$(_sanitize_external_input "$(echo "$event_data" | jq -r '.body // ""' | head -c 1000)" 10000)
            author=$(_sanitize_external_input "$(echo "$event_data" | jq -r '.author')" 128)
            author_type=$(echo "$event_data" | jq -r '.author_type')
            url=$(echo "$event_data" | jq -r '.url')
            issue_val="$issue_number"
            body_yaml="event_type: ${event_type}
issue_number: ${issue_number}
comment_id: ${comment_id}
author: ${author}
author_type: ${author_type}
body: |
$(echo "$body" | sed 's/^/  /')
url: \"${url}\""
            ;;

        pr_created|pr_updated)
            local pr_number pr_title pr_body author author_type url head_ref base_ref
            pr_number=$(echo "$event_data" | jq -r '.number')
            pr_title=$(_sanitize_external_input "$(echo "$event_data" | jq -r '.title')" 256)
            pr_body=$(_sanitize_external_input "$(echo "$event_data" | jq -r '.body // ""' | head -c 1000)" 10000)
            author=$(_sanitize_external_input "$(echo "$event_data" | jq -r '.author')" 128)
            author_type=$(echo "$event_data" | jq -r '.author_type')
            url=$(echo "$event_data" | jq -r '.url')
            head_ref=$(echo "$event_data" | jq -r '.head_ref')
            base_ref=$(echo "$event_data" | jq -r '.base_ref')
            issue_val="$pr_number"
            body_yaml="event_type: ${event_type}
pr_number: ${pr_number}
pr_title: \"${pr_title//\"/\\\"}\"
author: ${author}
author_type: ${author_type}
head_ref: ${head_ref}
base_ref: ${base_ref}
body: |
$(echo "$pr_body" | sed 's/^/  /')
url: \"${url}\""
            ;;

        pr_comment)
            local pr_number comment_id body author author_type url
            pr_number=$(echo "$event_data" | jq -r '.pr_number')
            comment_id=$(echo "$event_data" | jq -r '.id')
            body=$(_sanitize_external_input "$(echo "$event_data" | jq -r '.body // ""' | head -c 1000)" 10000)
            author=$(_sanitize_external_input "$(echo "$event_data" | jq -r '.author')" 128)
            author_type=$(echo "$event_data" | jq -r '.author_type')
            url=$(echo "$event_data" | jq -r '.url')
            issue_val="$pr_number"
            body_yaml="event_type: ${event_type}
pr_number: ${pr_number}
comment_id: ${comment_id}
author: ${author}
author_type: ${author_type}
body: |
$(echo "$body" | sed 's/^/  /')
url: \"${url}\""
            ;;

        pr_review)
            local pr_number review_id body author author_type review_state url
            pr_number=$(echo "$event_data" | jq -r '.pr_number')
            review_id=$(echo "$event_data" | jq -r '.id')
            body=$(_sanitize_external_input "$(echo "$event_data" | jq -r '.body // ""' | head -c 1000)" 10000)
            author=$(_sanitize_external_input "$(echo "$event_data" | jq -r '.author')" 128)
            author_type=$(echo "$event_data" | jq -r '.author_type')
            review_state=$(echo "$event_data" | jq -r '.state')
            url=$(echo "$event_data" | jq -r '.url')
            issue_val="$pr_number"
            body_yaml="event_type: ${event_type}
pr_number: ${pr_number}
review_id: ${review_id}
review_state: ${review_state}
author: ${author}
author_type: ${author_type}
body: |
$(echo "$body" | sed 's/^/  /')
url: \"${url}\""
            ;;
    esac

    # MIME構築
    local mime_args=(--from github_watcher --to leader --type github_event
                     --priority "${DEFAULT_MESSAGE_PRIORITY}" --repo "$repo")
    [[ -n "$issue_val" ]] && mime_args+=(--issue "$issue_val")
    python3 "$IGNITE_MIME" build "${mime_args[@]}" --body "$body_yaml" -o "$message_file"

    echo "$message_file"
}

# トリガーメッセージを検出（@ignite-gh-app など）
create_task_message() {
    local event_type="$1"
    local repo="$2"
    local event_data="$3"
    local trigger_type="$4"

    local timestamp message_id
    timestamp=$(date -Iseconds)
    message_id=$(date +%s%6N)
    local queue_dir="${IGNITE_RUNTIME_DIR}/queue/leader"

    mkdir -p "$queue_dir"

    local message_file="${queue_dir}/github_task_${message_id}.mime"

    local issue_number author body url
    issue_number=$(echo "$event_data" | jq -r '.issue_number // .pr_number // .number // 0')
    author=$(_sanitize_external_input "$(echo "$event_data" | jq -r '.author')" 128)
    body=$(_sanitize_external_input "$(echo "$event_data" | jq -r '.body // ""' | head -c 2000)" 10000)
    url=$(echo "$event_data" | jq -r '.url')

    # Issue/PR情報を取得（コメント/レビューからの場合）
    local issue_title=""
    local issue_body=""
    if [[ "$event_type" == "issue_comment" ]] && [[ "$issue_number" != "0" ]]; then
        local issue_info
        issue_info=$(github_api_get "$repo" "/repos/${repo}/issues/${issue_number}" || echo "{}")
        issue_title=$(_sanitize_external_input "$(echo "$issue_info" | jq -r '.title // ""')" 256)
        issue_body=$(_sanitize_external_input "$(echo "$issue_info" | jq -r '.body // ""' | head -c 1000)" 10000)
    elif [[ "$event_type" =~ ^pr_(comment|review)$ ]] && [[ "$issue_number" != "0" ]]; then
        local pr_info
        pr_info=$(github_api_get "$repo" "/repos/${repo}/pulls/${issue_number}" || echo "{}")
        issue_title=$(_sanitize_external_input "$(echo "$pr_info" | jq -r '.title // ""')" 256)
        issue_body=$(_sanitize_external_input "$(echo "$pr_info" | jq -r '.body // ""' | head -c 1000)" 10000)
    else
        issue_title=$(_sanitize_external_input "$(echo "$event_data" | jq -r '.title // ""')" 256)
        issue_body=$(_sanitize_external_input "$(echo "$event_data" | jq -r '.body // ""' | head -c 1000)" 10000)
    fi

    local body_yaml
    body_yaml="trigger: ${trigger_type}
repository: ${repo}
issue_number: ${issue_number}
issue_title: \"${issue_title//\"/\\\"}\"
issue_body: |
$(echo "$issue_body" | sed 's/^/  /')
requested_by: ${author}
trigger_comment: |
$(echo "$body" | sed 's/^/  /')
branch_prefix: \"ignite/\"
url: \"${url}\""

    local mime_args=(--from github_watcher --to leader --type github_task
                     --priority high --repo "$repo")
    [[ "$issue_number" != "0" ]] && mime_args+=(--issue "$issue_number")
    python3 "$IGNITE_MIME" build "${mime_args[@]}" --body "$body_yaml" -o "$message_file"

    echo "$message_file"
}

# =============================================================================
# イベント処理
# =============================================================================

process_events() {
    for repo in "${REPOSITORIES[@]}"; do
        log_info "リポジトリ監視: $repo"

        # Issues
        if [[ "$WATCH_ISSUES" == "true" ]]; then
            process_issues "$repo"
        fi

        # Issue Comments
        if [[ "$WATCH_ISSUE_COMMENTS" == "true" ]]; then
            process_issue_comments "$repo"
        fi

        # PRs
        if [[ "$WATCH_PRS" == "true" ]]; then
            process_prs "$repo"
        fi

        # PR Comments
        if [[ "$WATCH_PR_COMMENTS" == "true" ]]; then
            process_pr_comments "$repo"
        fi

        # PR Reviews
        if [[ "$WATCH_PR_REVIEWS" == "true" ]]; then
            process_pr_reviews "$repo"
        fi
    done
}

process_issues() {
    local repo="$1"
    local issues
    issues=$(fetch_issues "$repo")

    if [[ -z "$issues" ]]; then
        return
    fi

    echo "$issues" | while IFS= read -r issue; do
        [[ -z "$issue" ]] && continue

        local id
        id=$(echo "$issue" | jq -r '.id')
        local author_type
        author_type=$(echo "$issue" | jq -r '.author_type')
        local author
        author=$(echo "$issue" | jq -r '.author')

        # 処理済みチェック
        if is_event_processed "issue" "$id"; then
            continue
        fi

        # Bot判別
        if [[ "$IGNORE_BOT" == "true" ]] && ! is_human_event "$author_type" "$author"; then
            mark_event_processed "issue" "$id"
            continue
        fi

        # アクセス制御チェック
        if ! is_user_authorized "$author"; then
            log_info "アクセス制御: ユーザー '$author' のIssue作成をスキップ"
            mark_event_processed "issue" "$id"
            continue
        fi

        log_event "新規Issue検知: #$(echo "$issue" | jq -r '.number') by $author"

        local body
        body=$(echo "$issue" | jq -r '.body // ""')

        # トリガーパターンをチェック（Issue body内のメンション検出）
        if [[ "$body" =~ $MENTION_PATTERN ]]; then
            log_event "トリガー検知: $MENTION_PATTERN (by $author)"

            # タスク分類は Leader（LLM）に委譲
            local trigger_type="auto"

            local message_file
            message_file=$(create_task_message "issue_created" "$repo" "$issue" "$trigger_type")
            log_success "タスクメッセージ作成: $message_file"
        else
            local message_file
            message_file=$(create_event_message "issue_created" "$repo" "$issue")
            log_success "メッセージ作成: $message_file"
        fi

        mark_event_processed "issue" "$id"
    done

    update_last_check "$repo" "issues"
}

process_issue_comments() {
    local repo="$1"
    local comments
    comments=$(fetch_issue_comments "$repo")

    if [[ -z "$comments" ]]; then
        return
    fi

    echo "$comments" | while IFS= read -r comment; do
        [[ -z "$comment" ]] && continue

        local id
        id=$(echo "$comment" | jq -r '.id')
        local author_type
        author_type=$(echo "$comment" | jq -r '.author_type')
        local author
        author=$(echo "$comment" | jq -r '.author')
        local body
        body=$(echo "$comment" | jq -r '.body // ""')

        # 処理済みチェック
        if is_event_processed "issue_comment" "$id"; then
            continue
        fi

        # Bot判別
        if [[ "$IGNORE_BOT" == "true" ]] && ! is_human_event "$author_type" "$author"; then
            mark_event_processed "issue_comment" "$id"
            continue
        fi

        log_event "新規Issueコメント検知: #$(echo "$comment" | jq -r '.issue_number') by $author"

        # トリガーパターンをチェック
        if [[ "$body" =~ $MENTION_PATTERN ]]; then
            log_event "トリガー検知: $MENTION_PATTERN (by $author)"

            # アクセス制御チェック
            if ! is_user_authorized "$author"; then
                log_warn "アクセス拒否: ユーザー '$author' はallowed_usersに含まれていません"
                mark_event_processed "issue_comment" "$id"
                continue
            fi

            # タスク分類は Leader（LLM）に委譲
            local trigger_type="auto"

            local message_file
            message_file=$(create_task_message "issue_comment" "$repo" "$comment" "$trigger_type")
            log_success "タスクメッセージ作成: $message_file"
        else
            # アクセス制御チェック（トリガーなしコメント）
            if ! is_user_authorized "$author"; then
                log_info "アクセス制御: ユーザー '$author' のIssueコメントをスキップ"
                mark_event_processed "issue_comment" "$id"
                continue
            fi

            local message_file
            message_file=$(create_event_message "issue_comment" "$repo" "$comment")
            log_success "メッセージ作成: $message_file"
        fi

        mark_event_processed "issue_comment" "$id"
    done

    update_last_check "$repo" "issue_comments"
}

process_prs() {
    local repo="$1"
    local prs
    prs=$(fetch_prs "$repo")

    if [[ -z "$prs" ]]; then
        return
    fi

    echo "$prs" | while IFS= read -r pr; do
        [[ -z "$pr" ]] && continue

        local id
        id=$(echo "$pr" | jq -r '.id')
        local author_type
        author_type=$(echo "$pr" | jq -r '.author_type')
        local author
        author=$(echo "$pr" | jq -r '.author')
        local body
        body=$(echo "$pr" | jq -r '.body // ""')

        # 処理済みチェック
        if is_event_processed "pr" "$id"; then
            continue
        fi

        # Bot判別
        if [[ "$IGNORE_BOT" == "true" ]] && ! is_human_event "$author_type" "$author"; then
            mark_event_processed "pr" "$id"
            continue
        fi

        log_event "新規PR検知: #$(echo "$pr" | jq -r '.number') by $author"

        # トリガーパターンをチェック
        if [[ "$body" =~ $MENTION_PATTERN ]]; then
            log_event "トリガー検知: $MENTION_PATTERN (by $author)"

            # アクセス制御チェック
            if ! is_user_authorized "$author"; then
                log_warn "アクセス拒否: ユーザー '$author' はallowed_usersに含まれていません"
                mark_event_processed "pr" "$id"
                continue
            fi

            # タスク分類は Leader（LLM）に委譲
            local trigger_type="auto"

            local message_file
            message_file=$(create_task_message "pr_created" "$repo" "$pr" "$trigger_type")
            log_success "タスクメッセージ作成: $message_file"
        else
            # アクセス制御チェック（トリガーなしPR）
            if ! is_user_authorized "$author"; then
                log_info "アクセス制御: ユーザー '$author' のPR作成をスキップ"
                mark_event_processed "pr" "$id"
                continue
            fi

            local message_file
            message_file=$(create_event_message "pr_created" "$repo" "$pr")
            log_success "メッセージ作成: $message_file"
        fi

        mark_event_processed "pr" "$id"
    done

    update_last_check "$repo" "prs"
}

process_pr_comments() {
    local repo="$1"
    local comments
    comments=$(fetch_pr_comments "$repo")

    if [[ -z "$comments" ]]; then
        return
    fi

    echo "$comments" | while IFS= read -r comment; do
        [[ -z "$comment" ]] && continue

        local id
        id=$(echo "$comment" | jq -r '.id')
        local author_type
        author_type=$(echo "$comment" | jq -r '.author_type')
        local author
        author=$(echo "$comment" | jq -r '.author')
        local body
        body=$(echo "$comment" | jq -r '.body // ""')

        # 処理済みチェック
        if is_event_processed "pr_comment" "$id"; then
            continue
        fi

        # Bot判別
        if [[ "$IGNORE_BOT" == "true" ]] && ! is_human_event "$author_type" "$author"; then
            mark_event_processed "pr_comment" "$id"
            continue
        fi

        log_event "新規PRコメント検知: #$(echo "$comment" | jq -r '.pr_number') by $author"

        # トリガーパターンをチェック
        if [[ "$body" =~ $MENTION_PATTERN ]]; then
            log_event "トリガー検知: $MENTION_PATTERN (by $author)"

            # アクセス制御チェック
            if ! is_user_authorized "$author"; then
                log_warn "アクセス拒否: ユーザー '$author' はallowed_usersに含まれていません"
                mark_event_processed "pr_comment" "$id"
                continue
            fi

            # タスク分類は Leader（LLM）に委譲
            local trigger_type="auto"

            local message_file
            message_file=$(create_task_message "pr_comment" "$repo" "$comment" "$trigger_type")
            log_success "タスクメッセージ作成: $message_file"
        else
            # アクセス制御チェック（トリガーなしPRコメント）
            if ! is_user_authorized "$author"; then
                log_info "アクセス制御: ユーザー '$author' のPRコメントをスキップ"
                mark_event_processed "pr_comment" "$id"
                continue
            fi

            local message_file
            message_file=$(create_event_message "pr_comment" "$repo" "$comment")
            log_success "メッセージ作成: $message_file"
        fi

        mark_event_processed "pr_comment" "$id"
    done

    update_last_check "$repo" "pr_comments"
}

process_pr_reviews() {
    local repo="$1"
    local reviews
    reviews=$(fetch_pr_reviews "$repo")

    if [[ -z "$reviews" ]]; then
        return
    fi

    echo "$reviews" | while IFS= read -r review; do
        [[ -z "$review" ]] && continue

        local id
        id=$(echo "$review" | jq -r '.id')
        local pr_number
        pr_number=$(echo "$review" | jq -r '.pr_number')
        local author_type
        author_type=$(echo "$review" | jq -r '.author_type')
        local author
        author=$(echo "$review" | jq -r '.author')
        local body
        body=$(echo "$review" | jq -r '.body // ""')

        # 処理済みチェック
        if is_event_processed "pr_review" "$id"; then
            continue
        fi

        # Bot判別
        if [[ "$IGNORE_BOT" == "true" ]] && ! is_human_event "$author_type" "$author"; then
            mark_event_processed "pr_review" "$id"
            continue
        fi

        log_event "新規PRレビュー検知: #${pr_number} by $author"

        # レビュー本体 + コード行コメントを結合してメンションをチェック
        local review_comments=""
        if [[ -z "$body" ]] || ! [[ "$body" =~ $MENTION_PATTERN ]]; then
            # bodyが空、またはbodyにメンションがない場合、コード行コメントも取得
            review_comments=$(fetch_pr_review_comments "$repo" "$pr_number" "$id")
        fi
        local all_text="${body} ${review_comments}"

        # トリガーパターンをチェック（本体 + コード行コメント）
        if [[ "$all_text" =~ $MENTION_PATTERN ]]; then
            log_event "トリガー検知: $MENTION_PATTERN (by $author)"

            # アクセス制御チェック
            if ! is_user_authorized "$author"; then
                log_warn "アクセス拒否: ユーザー '$author' はallowed_usersに含まれていません"
                mark_event_processed "pr_review" "$id"
                continue
            fi

            # タスク分類は Leader（LLM）に委譲
            local trigger_type="auto"

            # コード行コメントがある場合、reviewデータにマージ
            if [[ -n "$review_comments" ]]; then
                review=$(echo "$review" | jq --arg comments "$review_comments" '. + {review_comments: $comments}')
            fi

            local message_file
            message_file=$(create_task_message "pr_review" "$repo" "$review" "$trigger_type")
            log_success "タスクメッセージ作成: $message_file"
        else
            # トリガーなしの場合
            # bodyもコメントも空の場合はスキップ（Approveのみ等）
            if [[ -z "$body" ]] && [[ -z "$review_comments" ]]; then
                log_info "PRレビュー #${pr_number} (id: $id): コメントなしのためスキップ"
                mark_event_processed "pr_review" "$id"
                continue
            fi

            # アクセス制御チェック（トリガーなしPRレビュー）
            if ! is_user_authorized "$author"; then
                log_info "アクセス制御: ユーザー '$author' のPRレビューをスキップ"
                mark_event_processed "pr_review" "$id"
                continue
            fi

            local message_file
            message_file=$(create_event_message "pr_review" "$repo" "$review")
            log_success "メッセージ作成: $message_file"
        fi

        mark_event_processed "pr_review" "$id"
    done

    update_last_check "$repo" "pr_reviews"
}

# =============================================================================
# メインループ
# =============================================================================

# watcher_poll() オーバーライド: process_events() + パターンリフレッシュ
# watcher_common.sh の watcher_run_daemon() から呼び出される
_GITHUB_REFRESH_COUNTER=0
watcher_poll() {
    # パターンの定期リフレッシュ
    if [[ ${#REPO_PATTERNS[@]} -gt 0 ]]; then
        _GITHUB_REFRESH_COUNTER=$((_GITHUB_REFRESH_COUNTER + 1))
        if [[ $_GITHUB_REFRESH_COUNTER -ge $PATTERN_REFRESH_INTERVAL ]]; then
            _GITHUB_REFRESH_COUNTER=0
            log_info "パターンリフレッシュ実行中..."
            expand_patterns "${REPO_PATTERNS[@]}" || log_warn "パターンリフレッシュ失敗、前回のリストを維持"
            log_info "現在の監視対象: ${REPOSITORIES[*]}"
        fi
    fi

    # SIGHUP リロード: GitHub 固有の設定リロード
    # watcher_common.sh は共通設定のみリロードするため、
    # GitHub固有の load_config + expand_patterns はここで実行
    if [[ "$_WATCHER_RELOAD_REQUESTED" == true ]]; then
        _WATCHER_RELOAD_REQUESTED=false
        load_config || log_warn "設定リロード失敗"
        _WATCHER_STATE_FILE="$STATE_FILE"
        _WATCHER_POLL_INTERVAL="$POLL_INTERVAL"
        if [[ ${#REPO_PATTERNS[@]} -gt 0 ]]; then
            expand_patterns "${REPO_PATTERNS[@]}" || log_warn "パターン展開失敗"
        fi
        log_info "設定リロード完了: 監視対象=${REPOSITORIES[*]}"
    fi

    process_events
}

run_daemon() {
    # 二重起動防止ロック（queue_monitor と同一パターン）
    if [[ -n "${IGNITE_RUNTIME_DIR:-}" ]]; then
        mkdir -p "${IGNITE_RUNTIME_DIR}/state" 2>/dev/null || true
        WATCHER_LOCK_FILE="${IGNITE_RUNTIME_DIR}/state/github_watcher.lock"
        exec 9>"$WATCHER_LOCK_FILE"
        if ! flock -n 9; then
            log_warn "github_watcher は既に稼働中です（flock取得失敗）"
            exit 1
        fi
    fi

    log_info "GitHub Watcher を起動します"
    log_info "監視間隔: ${POLL_INTERVAL}秒"
    log_info "監視対象リポジトリ: ${REPOSITORIES[*]}"
    log_info "ステートファイル: $STATE_FILE"
    if [[ ${#REPO_PATTERNS[@]} -gt 0 ]]; then
        log_info "パターンリフレッシュ間隔: ${PATTERN_REFRESH_INTERVAL}サイクル"
    fi

    # watcher_common.sh のポーリング間隔をGitHub固有設定で上書き
    _WATCHER_POLL_INTERVAL="$POLL_INTERVAL"

    # ハートビートコールバックをオーバーライド（queue_monitor の死活判定に使用）
    watcher_heartbeat() { _write_watcher_heartbeat; }

    # watcher_common.sh のデーモンループに委譲
    # 注意: SIGHUPリロードは watcher_poll() 内で GitHub 固有設定含めて処理
    watcher_run_daemon
}

run_once() {
    log_info "GitHub Watcher を単発実行します"
    log_info "監視対象リポジトリ: ${REPOSITORIES[*]}"

    process_events

    log_success "処理完了"
}

# =============================================================================
# ヘルプ
# =============================================================================

show_help() {
    cat << 'EOF'
GitHub イベント監視デーモン

使用方法:
  ./scripts/utils/github_watcher.sh [オプション]

オプション:
  -d, --daemon    デーモンモードで起動（デフォルト）
  -o, --once      単発実行
  -c, --config    設定ファイルを指定
  -h, --help      このヘルプを表示

環境変数:
  IGNITE_WATCHER_CONFIG    設定ファイルのパス

使用例:
  # デーモンモードで起動
  ./scripts/utils/github_watcher.sh

  # 単発実行
  ./scripts/utils/github_watcher.sh --once

  # バックグラウンドで起動
  ./scripts/utils/github_watcher.sh &

  # 設定ファイルを指定
  ./scripts/utils/github_watcher.sh -c /path/to/config.yaml

設定ファイル:
  config/github-watcher.yaml を編集して監視対象リポジトリを設定してください。
  詳細は docs/github-watcher.md を参照してください。
EOF
}

# =============================================================================
# メイン
# =============================================================================

main() {
    local mode="daemon"
    local config_file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--daemon)
                mode="daemon"
                shift
                ;;
            -o|--once)
                mode="once"
                shift
                ;;
            -c|--config)
                config_file="$2"
                export IGNITE_WATCHER_CONFIG="$config_file"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    # 設定読み込み
    load_config

    # ステート初期化
    init_state

    # watcher_common.sh の初期化（シグナルtrap登録、PIDファイル作成）
    # 注意: load_config/init_state の後に呼ぶ（設定値が必要なため）
    _WATCHER_NAME="github_watcher"
    _WATCHER_CONFIG_FILE="${IGNITE_WATCHER_CONFIG:-${IGNITE_CONFIG_DIR}/${DEFAULT_CONFIG_FILE}}"
    _watcher_setup_traps

    # 実行モード
    case "$mode" in
        daemon)
            run_daemon
            ;;
        once)
            run_once
            ;;
    esac
}

main "$@"

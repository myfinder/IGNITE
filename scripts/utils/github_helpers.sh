#!/bin/bash
# GitHub API 共通ヘルパー関数（curl+jq）
# Bot Token取得（キャッシュ + リトライ機構）、API/認証/git操作ヘルパーを提供

# 多重読み込み防止
if [[ -n "${_GITHUB_HELPERS_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_GITHUB_HELPERS_LOADED=1

# SCRIPT_DIR が未設定なら呼び出し元から推定
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# core.sh から設定・カラー・ログ関数を取得
source "${SCRIPT_DIR}/../lib/core.sh"
[[ -n "${WORKSPACE_DIR:-}" ]] && setup_workspace_config "$WORKSPACE_DIR"

# =============================================================================
# Bot Token 取得（キャッシュ + リトライ機構付き）
# =============================================================================

BOT_TOKEN_MAX_RETRIES="${BOT_TOKEN_MAX_RETRIES:-3}"
BOT_TOKEN_RETRY_DELAY="${BOT_TOKEN_RETRY_DELAY:-2}"
BOT_TOKEN_CACHE_TTL="${BOT_TOKEN_CACHE_TTL:-3300}"  # 55分

_get_cache_dir() {
    if [[ -n "${WORKSPACE_DIR:-}" ]]; then
        echo "${IGNITE_RUNTIME_DIR}/state"
    elif [[ -n "${IGNITE_WORKSPACE_DIR:-}" ]]; then
        echo "${IGNITE_WORKSPACE_DIR}/.ignite/state"
    else
        log_error "_get_cache_dir: WORKSPACE_DIR も IGNITE_WORKSPACE_DIR も未設定です"
        return 1
    fi
}

get_cached_bot_token() {
    local repo="$1"
    local cache_dir
    cache_dir=$(_get_cache_dir)
    local cache_key
    cache_key=$(echo "$repo" | tr '/' '_')
    local cache_file="$cache_dir/.bot_token_${cache_key}"

    mkdir -p "$cache_dir"
    chmod 700 "$cache_dir" 2>/dev/null || true

    if [[ -f "$cache_file" ]]; then
        local cached_at now remaining
        cached_at=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)
        now=$(date +%s)
        remaining=$((BOT_TOKEN_CACHE_TTL - (now - cached_at)))

        if (( remaining > 0 )); then
            local cached_token
            cached_token=$(cat "$cache_file" 2>/dev/null)
            if [[ "$cached_token" == ghs_* ]]; then
                log_info "キャッシュからBot Tokenを使用 (残り: ${remaining}秒)"
                echo "$cached_token"
                return 0
            fi
        else
            rm -f "$cache_file"
        fi
    fi

    local token
    token=$(_get_bot_token_internal "$repo") || true

    if [[ -n "$token" ]] && [[ "$token" == ghs_* ]]; then
        ( umask 077; echo "$token" > "$cache_file" )
        log_info "Bot Tokenを新規取得しキャッシュ (TTL: ${BOT_TOKEN_CACHE_TTL}秒)"
        echo "$token"
        return 0
    fi

    echo ""
    return 1
}

_get_bot_token_internal() {
    local repo="${1:-}"
    local retry_count=0
    local token=""
    local last_error=""
    local token_script="${SCRIPT_DIR}/get_github_app_token.sh"
    local repo_option=""
    local stderr_tmp
    stderr_tmp=$(mktemp)

    if [[ -n "$repo" ]]; then
        repo_option="--repo $repo"
    fi

    while [[ $retry_count -lt $BOT_TOKEN_MAX_RETRIES ]]; do
        if [[ -n "${IGNITE_CONFIG_DIR:-}" ]]; then
            token=$(IGNITE_GITHUB_CONFIG="${IGNITE_CONFIG_DIR}/github-app.yaml" "$token_script" $repo_option 2>"$stderr_tmp")
        else
            token=$("$token_script" $repo_option 2>"$stderr_tmp")
        fi
        local exit_code=$?

        if [[ $exit_code -eq 0 ]] && [[ -n "$token" ]] && [[ "$token" == ghs_* ]]; then
            rm -f "$stderr_tmp"
            echo "$token"
            return 0
        fi

        last_error=$(cat "$stderr_tmp" 2>/dev/null)
        [[ -z "$last_error" ]] && last_error="$token"
        case $exit_code in
            64) log_warn "Bot Token: 引数エラー (EX_USAGE)"; break ;;
            69) log_warn "Bot Token: 前提コマンド未インストール (EX_UNAVAILABLE)"; break ;;
            78) log_warn "Bot Token: 設定ファイルエラー (EX_CONFIG)"; break ;;
            77) log_warn "Bot Token: 権限エラー (EX_NOPERM)"; break ;;
            73) log_warn "Bot Token: トークン生成失敗 (EX_CANTCREAT)" ;;
            75) log_warn "Bot Token: 一時的エラー (EX_TEMPFAIL)" ;;
            *)  log_warn "Bot Token: 不明なエラー (exit_code=$exit_code)" ;;
        esac

        retry_count=$((retry_count + 1))
        if [[ $retry_count -lt $BOT_TOKEN_MAX_RETRIES ]]; then
            log_warn "Bot Token取得リトライ (試行 $retry_count/$BOT_TOKEN_MAX_RETRIES)。${BOT_TOKEN_RETRY_DELAY}秒後..."
            sleep "$BOT_TOKEN_RETRY_DELAY"
        fi
    done

    rm -f "$stderr_tmp"
    log_warn "Bot Token取得失敗 (全${BOT_TOKEN_MAX_RETRIES}回の試行が失敗)"
    if [[ -n "$last_error" ]]; then
        log_warn "最後のエラー: $last_error"
    fi
    echo ""
    return 1
}

# 後方互換
get_bot_token() {
    get_cached_bot_token "$@"
}

# 認証トークン取得（優先順位: GitHub App > PAT）
get_auth_token() {
    local repo="${1:-}"
    AUTH_TOKEN_SOURCE=""

    local token=""
    if [[ -n "$repo" ]]; then
        token=$(get_cached_bot_token "$repo" 2>/dev/null) || true
        if [[ -n "$token" ]] && [[ "$token" == ghs_* ]]; then
            AUTH_TOKEN_SOURCE="github_app"
            echo "$token"
            return 0
        fi
    fi

    if [[ -n "${IGNITE_GITHUB_TOKEN:-}" ]]; then
        AUTH_TOKEN_SOURCE="pat"
        echo "${IGNITE_GITHUB_TOKEN}"
        return 0
    fi
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        AUTH_TOKEN_SOURCE="pat"
        echo "${GITHUB_TOKEN}"
        return 0
    fi
    if [[ -n "${GH_TOKEN:-}" ]]; then
        AUTH_TOKEN_SOURCE="pat"
        echo "${GH_TOKEN}"
        return 0
    fi
    if [[ -n "${GITHUB_PAT:-}" ]]; then
        AUTH_TOKEN_SOURCE="pat"
        echo "${GITHUB_PAT}"
        return 0
    fi

    return 1
}

_print_auth_error() {
    local repo_hint="${1:-}"
    log_error "認証トークンが見つかりません。GitHub App または PAT を設定してください。"
    if [[ -n "$repo_hint" ]]; then
        echo "  対象リポジトリ: $repo_hint" >&2
    fi
    echo "  GitHub App: ${IGNITE_CONFIG_DIR:-config}/github-app.yaml を設定" >&2
    echo "  PAT: export IGNITE_GITHUB_TOKEN=github_pat_xxx" >&2
    echo "  PAT: export GITHUB_TOKEN=github_pat_xxx" >&2
}

# =============================================================================
# GitHub URL/JSON ヘルパー
# =============================================================================

GITHUB_API_MAX_RETRIES="${GITHUB_API_MAX_RETRIES:-3}"
GITHUB_API_RETRY_DELAY="${GITHUB_API_RETRY_DELAY:-2}"
GITHUB_API_TIMEOUT="${GITHUB_API_TIMEOUT:-20}"

_normalize_host() {
    local host="$1"
    host="${host#https://}"
    host="${host#http://}"
    echo "$host"
}

get_github_hostname() {
    if [[ -n "${GITHUB_HOSTNAME:-}" ]]; then
        echo "$( _normalize_host "${GITHUB_HOSTNAME}" )"
        return 0
    fi
    if [[ -n "${GITHUB_BASE_URL:-}" ]]; then
        echo "$( _normalize_host "${GITHUB_BASE_URL}" )"
        return 0
    fi
    if [[ -n "${GITHUB_API_URL:-}" ]]; then
        echo "$( _normalize_host "${GITHUB_API_URL}" )"
        return 0
    fi
    echo "github.com"
}

get_github_base_url() {
    if [[ -n "${GITHUB_BASE_URL:-}" ]]; then
        echo "${GITHUB_BASE_URL%/}"
        return 0
    fi
    if [[ -n "${GITHUB_HOSTNAME:-}" ]]; then
        echo "https://$( _normalize_host "${GITHUB_HOSTNAME}" )"
        return 0
    fi
    echo "https://github.com"
}

get_github_api_base() {
    if [[ -n "${GITHUB_API_URL:-}" ]]; then
        echo "${GITHUB_API_URL%/}"
        return 0
    fi
    if [[ -n "${GITHUB_API_BASE:-}" ]]; then
        echo "${GITHUB_API_BASE%/}"
        return 0
    fi
    if [[ -n "${GITHUB_HOSTNAME:-}" ]]; then
        echo "https://$( _normalize_host "${GITHUB_HOSTNAME}" )/api/v3"
        return 0
    fi
    echo "https://api.github.com"
}

_jq_available() {
    command -v jq >/dev/null 2>&1
}

_require_jq_or_warn() {
    if _jq_available; then
        return 0
    fi
    log_warn "jq が未インストールです。インストールしてください: https://stedolan.github.io/jq/"
    return 1
}

_json_get() {
    local expr="$1"
    if _jq_available; then
        jq -r "$expr"
        return
    fi
    python3 - <<PY
import json,sys
data=json.load(sys.stdin)
expr="""$expr"""
def get(obj, path):
    cur=obj
    for part in path.strip('.').split('.'):
        if part.endswith(']') and '[' in part:
            key, idx = part[:-1].split('[')
            if key:
                cur=cur.get(key, []) if isinstance(cur, dict) else []
            cur=cur[int(idx)] if isinstance(cur, list) and len(cur)>int(idx) else None
        else:
            cur=cur.get(part) if isinstance(cur, dict) else None
        if cur is None:
            return None
    return cur
value=get(data, expr)
print("") if value is None else print(value)
PY
}

# =============================================================================
# GitHub API ヘルパー（curl+jq）
# =============================================================================

GITHUB_API_NOT_MODIFIED=0
GITHUB_API_STATUS=""
GITHUB_API_ETAG=""
GITHUB_API_LINK=""

_parse_header_value() {
    local header="$1"
    local file="$2"
    grep -i "^${header}:" "$file" | tail -1 | sed -E "s/^${header}:[[:space:]]*//I" | tr -d '\r'
}

github_api_request() {
    local repo="$1"
    local method="$2"
    local path_or_url="$3"
    local data="${4:-}"
    local etag_key="${5:-}"

    local auth_token
    if [[ -n "${GITHUB_AUTH_TOKEN_OVERRIDE:-}" ]]; then
        auth_token="$GITHUB_AUTH_TOKEN_OVERRIDE"
        AUTH_TOKEN_SOURCE="override"
    else
        auth_token=$(get_auth_token "$repo") || true
    fi
    if [[ -z "$auth_token" ]]; then
        _print_auth_error "$repo"
        return 1
    fi

    local api_base
    api_base=$(get_github_api_base)
    local url="$path_or_url"
    if [[ "$url" != http* ]]; then
        if [[ "$url" != /* ]]; then
            url="/${url}"
        fi
        url="${api_base}${url}"
    fi

    local cache_dir
    cache_dir=$(_get_cache_dir)
    local etag_file=""
    if [[ -n "$etag_key" ]]; then
        etag_file="$cache_dir/.etag_${etag_key}"
    fi

    local retry=0
    local headers_tmp
    local body_tmp
    headers_tmp=$(mktemp)
    body_tmp=$(mktemp)

    while [[ $retry -lt $GITHUB_API_MAX_RETRIES ]]; do
        GITHUB_API_NOT_MODIFIED=0
        GITHUB_API_STATUS=""
        GITHUB_API_ETAG=""
        GITHUB_API_LINK=""

        local -a curl_args=(
            -sS
            -D "$headers_tmp"
            -o "$body_tmp"
            -X "$method"
            --max-time "$GITHUB_API_TIMEOUT"
            -H "Accept: application/vnd.github+json"
            -H "X-GitHub-Api-Version: 2022-11-28"
            -H "Authorization: Bearer $auth_token"
        )

        if [[ -n "$etag_file" && -f "$etag_file" ]]; then
            local cached_etag
            cached_etag=$(cat "$etag_file" 2>/dev/null)
            [[ -n "$cached_etag" ]] && curl_args+=( -H "If-None-Match: $cached_etag" )
        fi

        if [[ -n "$data" ]]; then
            curl_args+=( -H "Content-Type: application/json" -d "$data" )
        fi

        curl "${curl_args[@]}" "$url" || true

        GITHUB_API_STATUS=$(awk 'NR==1 {print $2}' "$headers_tmp")
        GITHUB_API_ETAG=$(_parse_header_value "ETag" "$headers_tmp")
        GITHUB_API_LINK=$(_parse_header_value "Link" "$headers_tmp")

        local remaining
        remaining=$(_parse_header_value "X-RateLimit-Remaining" "$headers_tmp")
        local reset_at
        reset_at=$(_parse_header_value "X-RateLimit-Reset" "$headers_tmp")
        local retry_after
        retry_after=$(_parse_header_value "Retry-After" "$headers_tmp")

        if [[ "$GITHUB_API_STATUS" == "304" ]]; then
            GITHUB_API_NOT_MODIFIED=1
            rm -f "$headers_tmp" "$body_tmp"
            return 0
        fi

        if [[ "$GITHUB_API_STATUS" =~ ^2 ]]; then
            if [[ -n "$etag_file" && -n "$GITHUB_API_ETAG" ]]; then
                ( umask 077; echo "$GITHUB_API_ETAG" > "$etag_file" )
            fi
            cat "$body_tmp"
            rm -f "$headers_tmp" "$body_tmp"
            return 0
        fi

        if [[ "$GITHUB_API_STATUS" == "429" || ( "$GITHUB_API_STATUS" == "403" && "$remaining" == "0" ) ]]; then
            local sleep_for=0
            if [[ -n "$retry_after" ]]; then
                sleep_for="$retry_after"
            elif [[ -n "$reset_at" ]]; then
                local now
                now=$(date +%s)
                sleep_for=$((reset_at - now))
                (( sleep_for < 1 )) && sleep_for=1
            else
                sleep_for=$((GITHUB_API_RETRY_DELAY * (retry + 1)))
            fi
            log_warn "GitHub API rate limit。${sleep_for}秒後に再試行します"
            sleep "$sleep_for"
            retry=$((retry + 1))
            continue
        fi

        if [[ "$GITHUB_API_STATUS" =~ ^5 ]]; then
            retry=$((retry + 1))
            log_warn "GitHub API 一時エラー (HTTP $GITHUB_API_STATUS)。再試行 ${retry}/${GITHUB_API_MAX_RETRIES}"
            sleep "$GITHUB_API_RETRY_DELAY"
            continue
        fi

        local body_err
        body_err=$(cat "$body_tmp" 2>/dev/null)
        log_error "GitHub API 失敗 (HTTP $GITHUB_API_STATUS)"
        [[ -n "$body_err" ]] && log_error "response: $body_err"
        rm -f "$headers_tmp" "$body_tmp"
        return 1
    done

    rm -f "$headers_tmp" "$body_tmp"
    log_error "GitHub API リトライ上限に達しました"
    return 1
}

github_api_get() {
    github_api_request "$1" "GET" "$2" "${3:-}" "${4:-}"
}

github_api_post() {
    github_api_request "$1" "POST" "$2" "${3:-}" "${4:-}"
}

github_api_patch() {
    github_api_request "$1" "PATCH" "$2" "${3:-}" "${4:-}"
}

github_api_paginate() {
    local repo="$1"
    local path="$2"
    if ! _require_jq_or_warn; then
        return 1
    fi

    local api_base
    api_base=$(get_github_api_base)
    local next_url="$path"
    local combined="[]"

    while [[ -n "$next_url" ]]; do
        local page
        page=$(github_api_get "$repo" "$next_url") || return 1
        combined=$(jq -s '.[0] + .[1]' <(printf '%s' "$combined") <(printf '%s' "$page"))

        local next_link
        next_link=$(echo "$GITHUB_API_LINK" | tr ',' '\n' | sed -n 's/.*<\([^>]*\)>; rel="next".*/\1/p')
        if [[ -n "$next_link" ]]; then
            if [[ "$next_link" == "${api_base}"* ]]; then
                next_url="${next_link#${api_base}}"
            else
                next_url="$next_link"
            fi
        else
            next_url=""
        fi
    done

    printf '%s' "$combined"
}

# =============================================================================
# Git操作ラッパー（認証エラー検出→Token更新→リトライ）
# =============================================================================

GIT_AUTH_MAX_RETRIES="${GIT_AUTH_MAX_RETRIES:-3}"
GIT_AUTH_RETRY_DELAY="${GIT_AUTH_RETRY_DELAY:-2}"

_get_repo_from_remote() {
    local url
    url=$(git remote get-url origin 2>/dev/null) || return 1
    if [[ "$url" =~ github\.com[:/]([^/]+/[^/.]+)(\.git)?$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

_build_repo_https_url() {
    local repo="$1"
    local base
    base=$(get_github_base_url)
    echo "${base}/${repo}.git"
}

_is_git_auth_error() {
    local stderr_content="$1"
    if echo "$stderr_content" | grep -qiE \
        "Authentication failed|could not read Username|HTTP 401|Invalid credentials|bad credentials|terminal prompts disabled"; then
        return 0
    fi
    return 1
}

_build_basic_auth() {
    local token="$1"
    printf 'x-access-token:%s' "$token" | base64 | tr -d '\n'
}

_get_git_host() {
    local url
    url=$(git remote get-url origin 2>/dev/null) || true
    if [[ "$url" =~ https?://([^/]+)/ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ "$url" =~ github\.com[:/] ]]; then
        echo "github.com"
        return 0
    fi
    echo "$(get_github_hostname)"
}

_git_with_extraheader() {
    local token="$1"
    shift
    local host
    host=$(_get_git_host)
    local basic
    basic=$(_build_basic_auth "$token")
    if [[ -n "$host" ]]; then
        git -c "http.https://${host}/.extraHeader=Authorization: Basic ${basic}" "$@"
    else
        git -c "http.extraHeader=Authorization: Basic ${basic}" "$@"
    fi
}

_git_with_askpass() {
    local token="$1"
    shift
    local askpass
    askpass=$(mktemp)
    cat > "$askpass" <<'EOF'
#!/bin/sh
echo "$GIT_PASSWORD"
EOF
    chmod 700 "$askpass"
    GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 GIT_USERNAME="x-access-token" GIT_PASSWORD="$token" \
        git "$@"
    local rc=$?
    rm -f "$askpass"
    return $rc
}

_invalidate_bot_token_cache() {
    local cache_dir
    cache_dir=$(_get_cache_dir)
    rm -f "$cache_dir"/.bot_token_* 2>/dev/null || true
    log_info "Bot Tokenキャッシュを無効化しました"
}

safe_git_push() {
    local retry_count=0
    local stderr_tmp
    stderr_tmp=$(mktemp)

    local repo=""
    repo=$(_get_repo_from_remote) || true

    while [[ $retry_count -lt $GIT_AUTH_MAX_RETRIES ]]; do
        local git_exit=0
        local fresh_token=""
        fresh_token=$(get_auth_token "$repo") || true
        local token_source="$AUTH_TOKEN_SOURCE"

        if [[ -z "$fresh_token" ]]; then
            _print_auth_error "$repo"
            rm -f "$stderr_tmp"
            return 1
        fi

        _git_with_extraheader "$fresh_token" push "$@" 2>"$stderr_tmp" || git_exit=$?
        if [[ $git_exit -ne 0 ]] && _is_git_auth_error "$(cat "$stderr_tmp" 2>/dev/null)"; then
            _git_with_askpass "$fresh_token" push "$@" 2>"$stderr_tmp" || git_exit=$?
        fi

        if [[ $git_exit -eq 0 ]]; then
            rm -f "$stderr_tmp"
            return 0
        fi

        local stderr_content
        stderr_content=$(cat "$stderr_tmp" 2>/dev/null)

        if [[ $git_exit -eq 128 ]] && _is_git_auth_error "$stderr_content"; then
            retry_count=$((retry_count + 1))
            log_warn "git push 認証エラーを検出 (試行 $retry_count/$GIT_AUTH_MAX_RETRIES)"
            log_warn "stderr: $stderr_content"
            if [[ "$token_source" == "github_app" ]]; then
                _invalidate_bot_token_cache
            fi
            if [[ $retry_count -lt $GIT_AUTH_MAX_RETRIES ]]; then
                log_warn "git push リトライ (${GIT_AUTH_RETRY_DELAY}秒後...)"
                sleep "$GIT_AUTH_RETRY_DELAY"
            fi
        else
            log_error "git push 失敗 (exit_code=$git_exit, 認証エラーではない)"
            [[ -n "$stderr_content" ]] && log_error "stderr: $stderr_content"
            rm -f "$stderr_tmp"
            return $git_exit
        fi
    done

    local final_stderr
    final_stderr=$(cat "$stderr_tmp" 2>/dev/null)
    rm -f "$stderr_tmp"
    log_error "git push 失敗 (全${GIT_AUTH_MAX_RETRIES}回リトライ失敗)"
    [[ -n "$final_stderr" ]] && log_error "stderr: $final_stderr"
    return 1
}

safe_git_fetch() {
    local retry_count=0
    local stderr_tmp
    stderr_tmp=$(mktemp)

    local repo=""
    repo=$(_get_repo_from_remote) || true

    while [[ $retry_count -lt $GIT_AUTH_MAX_RETRIES ]]; do
        local git_exit=0
        local fresh_token=""
        fresh_token=$(get_auth_token "$repo") || true
        local token_source="$AUTH_TOKEN_SOURCE"

        if [[ -z "$fresh_token" ]]; then
            _print_auth_error "$repo"
            rm -f "$stderr_tmp"
            return 1
        fi

        _git_with_extraheader "$fresh_token" fetch "$@" 2>"$stderr_tmp" || git_exit=$?
        if [[ $git_exit -ne 0 ]] && _is_git_auth_error "$(cat "$stderr_tmp" 2>/dev/null)"; then
            _git_with_askpass "$fresh_token" fetch "$@" 2>"$stderr_tmp" || git_exit=$?
        fi

        if [[ $git_exit -eq 0 ]]; then
            rm -f "$stderr_tmp"
            return 0
        fi

        local stderr_content
        stderr_content=$(cat "$stderr_tmp" 2>/dev/null)

        if [[ $git_exit -eq 128 ]] && _is_git_auth_error "$stderr_content"; then
            retry_count=$((retry_count + 1))
            log_warn "git fetch 認証エラーを検出 (試行 $retry_count/$GIT_AUTH_MAX_RETRIES)"
            log_warn "stderr: $stderr_content"
            if [[ "$token_source" == "github_app" ]]; then
                _invalidate_bot_token_cache
            fi
            if [[ $retry_count -lt $GIT_AUTH_MAX_RETRIES ]]; then
                log_warn "git fetch リトライ (${GIT_AUTH_RETRY_DELAY}秒後...)"
                sleep "$GIT_AUTH_RETRY_DELAY"
            fi
        else
            log_error "git fetch 失敗 (exit_code=$git_exit, 認証エラーではない)"
            [[ -n "$stderr_content" ]] && log_error "stderr: $stderr_content"
            rm -f "$stderr_tmp"
            return $git_exit
        fi
    done

    local final_stderr
    final_stderr=$(cat "$stderr_tmp" 2>/dev/null)
    rm -f "$stderr_tmp"
    log_error "git fetch 失敗 (全${GIT_AUTH_MAX_RETRIES}回リトライ失敗)"
    [[ -n "$final_stderr" ]] && log_error "stderr: $final_stderr"
    return 1
}

safe_git_pull() {
    local retry_count=0
    local stderr_tmp
    stderr_tmp=$(mktemp)

    local repo=""
    repo=$(_get_repo_from_remote) || true

    while [[ $retry_count -lt $GIT_AUTH_MAX_RETRIES ]]; do
        local git_exit=0
        local fresh_token=""
        fresh_token=$(get_auth_token "$repo") || true
        local token_source="$AUTH_TOKEN_SOURCE"

        if [[ -z "$fresh_token" ]]; then
            _print_auth_error "$repo"
            rm -f "$stderr_tmp"
            return 1
        fi

        _git_with_extraheader "$fresh_token" pull "$@" 2>"$stderr_tmp" || git_exit=$?
        if [[ $git_exit -ne 0 ]] && _is_git_auth_error "$(cat "$stderr_tmp" 2>/dev/null)"; then
            _git_with_askpass "$fresh_token" pull "$@" 2>"$stderr_tmp" || git_exit=$?
        fi

        if [[ $git_exit -eq 0 ]]; then
            rm -f "$stderr_tmp"
            return 0
        fi

        local stderr_content
        stderr_content=$(cat "$stderr_tmp" 2>/dev/null)

        if [[ $git_exit -eq 128 ]] && _is_git_auth_error "$stderr_content"; then
            retry_count=$((retry_count + 1))
            log_warn "git pull 認証エラーを検出 (試行 $retry_count/$GIT_AUTH_MAX_RETRIES)"
            log_warn "stderr: $stderr_content"
            if [[ "$token_source" == "github_app" ]]; then
                _invalidate_bot_token_cache
            fi
            if [[ $retry_count -lt $GIT_AUTH_MAX_RETRIES ]]; then
                log_warn "git pull リトライ (${GIT_AUTH_RETRY_DELAY}秒後...)"
                sleep "$GIT_AUTH_RETRY_DELAY"
            fi
        else
            log_error "git pull 失敗 (exit_code=$git_exit, 認証エラーではない)"
            [[ -n "$stderr_content" ]] && log_error "stderr: $stderr_content"
            rm -f "$stderr_tmp"
            return $git_exit
        fi
    done

    local final_stderr
    final_stderr=$(cat "$stderr_tmp" 2>/dev/null)
    rm -f "$stderr_tmp"
    log_error "git pull 失敗 (全${GIT_AUTH_MAX_RETRIES}回リトライ失敗)"
    [[ -n "$final_stderr" ]] && log_error "stderr: $final_stderr"
    return 1
}

safe_git_clone() {
    local repo="$1"
    local dest="$2"
    local branch="${3:-}"

    local clone_url
    clone_url=$(_build_repo_https_url "$repo")

    local retry_count=0
    local stderr_tmp
    stderr_tmp=$(mktemp)

    while [[ $retry_count -lt $GIT_AUTH_MAX_RETRIES ]]; do
        local git_exit=0
        local fresh_token=""
        fresh_token=$(get_auth_token "$repo") || true
        local token_source="$AUTH_TOKEN_SOURCE"

        if [[ -z "$fresh_token" ]]; then
            _print_auth_error "$repo"
            rm -f "$stderr_tmp"
            return 1
        fi

        if [[ -n "$branch" ]]; then
            _git_with_extraheader "$fresh_token" clone --branch "$branch" "$clone_url" "$dest" 2>"$stderr_tmp" || git_exit=$?
        else
            _git_with_extraheader "$fresh_token" clone "$clone_url" "$dest" 2>"$stderr_tmp" || git_exit=$?
        fi

        if [[ $git_exit -ne 0 ]] && _is_git_auth_error "$(cat "$stderr_tmp" 2>/dev/null)"; then
            if [[ -n "$branch" ]]; then
                _git_with_askpass "$fresh_token" clone --branch "$branch" "$clone_url" "$dest" 2>"$stderr_tmp" || git_exit=$?
            else
                _git_with_askpass "$fresh_token" clone "$clone_url" "$dest" 2>"$stderr_tmp" || git_exit=$?
            fi
        fi

        if [[ $git_exit -eq 0 ]]; then
            rm -f "$stderr_tmp"
            return 0
        fi

        local stderr_content
        stderr_content=$(cat "$stderr_tmp" 2>/dev/null)
        if [[ $git_exit -eq 128 ]] && _is_git_auth_error "$stderr_content"; then
            retry_count=$((retry_count + 1))
            log_warn "git clone 認証エラーを検出 (試行 $retry_count/$GIT_AUTH_MAX_RETRIES)"
            log_warn "stderr: $stderr_content"
            if [[ "$token_source" == "github_app" ]]; then
                _invalidate_bot_token_cache
            fi
            if [[ $retry_count -lt $GIT_AUTH_MAX_RETRIES ]]; then
                log_warn "git clone リトライ (${GIT_AUTH_RETRY_DELAY}秒後...)"
                sleep "$GIT_AUTH_RETRY_DELAY"
            fi
        else
            log_error "git clone 失敗 (exit_code=$git_exit, 認証エラーではない)"
            [[ -n "$stderr_content" ]] && log_error "stderr: $stderr_content"
            rm -f "$stderr_tmp"
            return $git_exit
        fi
    done

    local final_stderr
    final_stderr=$(cat "$stderr_tmp" 2>/dev/null)
    rm -f "$stderr_tmp"
    log_error "git clone 失敗 (全${GIT_AUTH_MAX_RETRIES}回リトライ失敗)"
    [[ -n "$final_stderr" ]] && log_error "stderr: $final_stderr"
    return 1
}

# =============================================================================
# _gh_api 互換ラッパー（必要最小限）
# =============================================================================

_gh_api() {
    local repo="$1"
    shift
    local cmd="$1"
    shift || true

    case "$cmd" in
        api)
            local path=""
            local body=""
            local paginate=false
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --paginate) paginate=true; shift ;;
                    -f)
                        if [[ "$2" =~ ^body= ]]; then
                            body="${2#body=}"
                        fi
                        shift 2
                        ;;
                    --silent) shift ;;
                    *)
                        if [[ -z "$path" ]]; then
                            path="$1"
                        fi
                        shift
                        ;;
                esac
            done
            if [[ -z "$path" ]]; then
                return 1
            fi
            if [[ "$paginate" == true ]]; then
                github_api_paginate "$repo" "$path"
                return $?
            fi
            if [[ -n "$body" ]]; then
                local payload
                if command -v jq >/dev/null 2>&1; then
                    payload=$(jq -n --arg body "$body" '{body:$body}')
                else
                    payload=$(python3 - <<PY
import json,sys
print(json.dumps({"body": sys.argv[1]}))
PY
"$body")
                fi
                github_api_post "$repo" "$path" "$payload"
            else
                github_api_get "$repo" "$path"
            fi
            ;;
        issue)
            local sub="$1"
            shift || true
            case "$sub" in
                view)
                    local issue_number="$1"
                    shift || true
                    local query=""
                    while [[ $# -gt 0 ]]; do
                        case "$1" in
                            -q) query="$2"; shift 2 ;;
                            --json) shift 2 ;;
                            --repo) shift 2 ;;
                            *) shift ;;
                        esac
                    done
                    local issue_json
                    issue_json=$(github_api_get "$repo" "/repos/${repo}/issues/${issue_number}" 2>/dev/null) || return 1
                    if [[ -n "$query" ]]; then
                        if ! command -v jq >/dev/null 2>&1; then
                            return 1
                        fi
                        echo "$issue_json" | jq -r "$query"
                    else
                        echo "$issue_json"
                    fi
                    ;;
                list)
                    local label="" state="open" search="" query=""
                    while [[ $# -gt 0 ]]; do
                        case "$1" in
                            --label) label="$2"; shift 2 ;;
                            --state) state="$2"; shift 2 ;;
                            --search) search="$2"; shift 2 ;;
                            --json) shift 2 ;;
                            -q) query="$2"; shift 2 ;;
                            --repo) shift 2 ;;
                            *) shift ;;
                        esac
                    done
                    if ! command -v jq >/dev/null 2>&1; then
                        return 1
                    fi
                    local q="repo:${repo} state:${state}"
                    [[ -n "$label" ]] && q+=" label:${label}"
                    [[ -n "$search" ]] && q+=" ${search}"
                    local q_encoded
                    q_encoded=$(python3 - <<PY
import urllib.parse,sys
print(urllib.parse.quote(sys.argv[1]))
PY
"$q")
                    local result
                    result=$(github_api_get "$repo" "/search/issues?q=${q_encoded}&per_page=30" 2>/dev/null) || return 1
                    if [[ -n "$query" ]]; then
                        echo "$result" | jq -r "$query"
                    else
                        echo "$result" | jq -c '.items'
                    fi
                    ;;
                create)
                    local title="" body="" label=""
                    while [[ $# -gt 0 ]]; do
                        case "$1" in
                            --title) title="$2"; shift 2 ;;
                            --body) body="$2"; shift 2 ;;
                            --label) label="$2"; shift 2 ;;
                            --repo) shift 2 ;;
                            *) shift ;;
                        esac
                    done
                    if ! command -v jq >/dev/null 2>&1; then
                        return 1
                    fi
                    local payload
                    if [[ -n "$label" ]]; then
                        payload=$(jq -n --arg title "$title" --arg body "$body" --arg label "$label" '{title:$title, body:$body, labels:[$label]}')
                    else
                        payload=$(jq -n --arg title "$title" --arg body "$body" '{title:$title, body:$body}')
                    fi
                    local issue_json
                    issue_json=$(github_api_post "$repo" "/repos/${repo}/issues" "$payload" 2>/dev/null) || return 1
                    echo "$issue_json" | jq -r '.html_url'
                    ;;
                edit)
                    local issue_number="$1"
                    shift || true
                    local body=""
                    while [[ $# -gt 0 ]]; do
                        case "$1" in
                            --body) body="$2"; shift 2 ;;
                            --repo) shift 2 ;;
                            *) shift ;;
                        esac
                    done
                    if ! command -v jq >/dev/null 2>&1; then
                        return 1
                    fi
                    local payload
                    payload=$(jq -n --arg body "$body" '{body:$body}')
                    github_api_patch "$repo" "/repos/${repo}/issues/${issue_number}" "$payload" >/dev/null
                    ;;
                close)
                    local issue_number="$1"
                    shift || true
                    if ! command -v jq >/dev/null 2>&1; then
                        return 1
                    fi
                    local payload
                    payload=$(jq -n '{state:"closed"}')
                    github_api_patch "$repo" "/repos/${repo}/issues/${issue_number}" "$payload" >/dev/null
                    ;;
                comment)
                    local issue_number="$1"
                    shift || true
                    local body=""
                    while [[ $# -gt 0 ]]; do
                        case "$1" in
                            --body) body="$2"; shift 2 ;;
                            --repo) shift 2 ;;
                            *) shift ;;
                        esac
                    done
                    local payload
                    if command -v jq >/dev/null 2>&1; then
                        payload=$(jq -n --arg body "$body" '{body:$body}')
                    else
                        payload=$(python3 - <<PY
import json,sys
print(json.dumps({"body": sys.argv[1]}))
PY
"$body")
                    fi
                    github_api_post "$repo" "/repos/${repo}/issues/${issue_number}/comments" "$payload" >/dev/null
                    ;;
                *)
                    log_error "_gh_api: unsupported issue subcommand $sub"
                    return 1
                    ;;
            esac
            ;;
        label)
            local sub="$1"
            shift || true
            case "$sub" in
                create)
                    local name="$1"
                    shift || true
                    local color="" description=""
                    while [[ $# -gt 0 ]]; do
                        case "$1" in
                            --color) color="$2"; shift 2 ;;
                            --description) description="$2"; shift 2 ;;
                            --repo) shift 2 ;;
                            *) shift ;;
                        esac
                    done
                    if ! command -v jq >/dev/null 2>&1; then
                        return 1
                    fi
                    local payload
                    payload=$(jq -n --arg name "$name" --arg color "$color" --arg description "$description" '{name:$name,color:$color,description:$description}')
                    github_api_post "$repo" "/repos/${repo}/labels" "$payload" >/dev/null
                    ;;
                *)
                    log_error "_gh_api: unsupported label subcommand $sub"
                    return 1
                    ;;
            esac
            ;;
        repo)
            local sub="$1"
            shift || true
            case "$sub" in
                view)
                    local query=""
                    while [[ $# -gt 0 ]]; do
                        case "$1" in
                            -q) query="$2"; shift 2 ;;
                            --json) shift 2 ;;
                            *) shift ;;
                        esac
                    done
                    local repo_json
                    repo_json=$(github_api_get "$repo" "/repos/${repo}" 2>/dev/null) || return 1
                    if [[ -n "$query" ]]; then
                        if ! command -v jq >/dev/null 2>&1; then
                            return 1
                        fi
                        echo "$repo_json" | jq -r "$query"
                    else
                        echo "$repo_json"
                    fi
                    ;;
                *)
                    log_error "_gh_api: unsupported repo subcommand $sub"
                    return 1
                    ;;
            esac
            ;;
        *)
            log_error "_gh_api: unsupported command $cmd"
            return 1
            ;;
    esac
}

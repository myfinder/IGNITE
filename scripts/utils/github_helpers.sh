#!/bin/bash
# GitHub API 共通ヘルパー関数
# Bot Token取得（キャッシュ + リトライ機構）、_gh_api() ラッパーを提供
#
# 使用方法（source で読み込み）:
#   source "${SCRIPT_DIR}/github_helpers.sh"
#
# 提供する関数:
#   get_cached_bot_token <repo>  - キャッシュ付きBot Token取得
#   _get_bot_token_internal <repo> - 内部Token取得（リトライ付き）
#   _get_cache_dir              - キャッシュディレクトリ解決
#   _gh_api <repo> <gh args...> - Bot Token自動適用のghラッパー
#   safe_git_push [git push args] - 認証エラー検出+Token更新+リトライ付きgit push
#   safe_git_fetch [git fetch args] - 認証エラー検出+Token更新+リトライ付きgit fetch

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
BOT_TOKEN_CACHE_TTL="${BOT_TOKEN_CACHE_TTL:-3300}"  # 55分（トークン有効期限1時間より余裕を持たせる）

_get_cache_dir() {
    if [[ -n "${WORKSPACE_DIR:-}" ]]; then
        echo "$WORKSPACE_DIR/state"
    elif [[ -n "${IGNITE_WORKSPACE_DIR:-}" ]]; then
        echo "$IGNITE_WORKSPACE_DIR/state"
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
        # stderr を tmpfile に分離し、stdout のみ token に格納
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

        # 失敗: exit codeに基づくログ出力（sysexits.h準拠）
        last_error=$(cat "$stderr_tmp" 2>/dev/null)
        [[ -z "$last_error" ]] && last_error="$token"
        case $exit_code in
            64) log_warn "Bot Token: 引数エラー (EX_USAGE)"; break ;;
            69) log_warn "Bot Token: gh CLI/gh-token未インストール (EX_UNAVAILABLE)"; break ;;
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

# 後方互換性のためのラッパー
get_bot_token() {
    get_cached_bot_token "$@"
}

# =============================================================================
# GitHub API ヘルパー（Bot Token自動適用）
# =============================================================================

# =============================================================================
# Git操作ラッパー（認証エラー検出→Token更新→リトライ）
# =============================================================================

GIT_AUTH_MAX_RETRIES="${GIT_AUTH_MAX_RETRIES:-3}"
GIT_AUTH_RETRY_DELAY="${GIT_AUTH_RETRY_DELAY:-2}"

# git remote URL からリポジトリ (owner/repo) を検出
_get_repo_from_remote() {
    local url
    url=$(git remote get-url origin 2>/dev/null) || return 1
    # https://github.com/owner/repo.git → owner/repo
    if [[ "$url" =~ github\.com[:/]([^/]+/[^/.]+)(\.git)?$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

# stderr内容から認証エラーかどうかを判定
_is_git_auth_error() {
    local stderr_content="$1"
    if echo "$stderr_content" | grep -qiE \
        "Authentication failed|could not read Username|HTTP 401|Invalid credentials|bad credentials|terminal prompts disabled"; then
        return 0
    fi
    return 1
}

# Bot Tokenキャッシュを無効化
_invalidate_bot_token_cache() {
    local cache_dir
    cache_dir=$(_get_cache_dir)
    rm -f "$cache_dir"/.bot_token_* 2>/dev/null || true
    log_info "Bot Tokenキャッシュを無効化しました"
}

# 安全なgit push（認証エラー検出→キャッシュ無効化→Token再取得→リトライ）
# 使用例:
#   safe_git_push                          # git push
#   safe_git_push -u origin branch_name    # git push -u origin branch_name
#   safe_git_push --force-with-lease       # git push --force-with-lease
safe_git_push() {
    local retry_count=0
    local stderr_tmp
    stderr_tmp=$(mktemp)

    local repo=""
    repo=$(_get_repo_from_remote) || true

    while [[ $retry_count -lt $GIT_AUTH_MAX_RETRIES ]]; do
        local git_exit=0

        # stale GH_TOKEN を回避: 新しい Bot Token を取得して上書き
        local fresh_token=""
        if [[ -n "$repo" ]]; then
            fresh_token=$(get_cached_bot_token "$repo" 2>/dev/null) || true
        fi

        if [[ -n "$fresh_token" ]] && [[ "$fresh_token" == ghs_* ]]; then
            GH_TOKEN="$fresh_token" git push "$@" 2>"$stderr_tmp" || git_exit=$?
        else
            # Bot Token取得不可: stale GH_TOKEN を除去して credential helper に委任
            env -u GH_TOKEN git push "$@" 2>"$stderr_tmp" || git_exit=$?
        fi

        if [[ $git_exit -eq 0 ]]; then
            rm -f "$stderr_tmp"
            return 0
        fi

        local stderr_content
        stderr_content=$(cat "$stderr_tmp" 2>/dev/null)

        # exit code 128 + 認証エラーパターンの場合のみリトライ
        if [[ $git_exit -eq 128 ]] && _is_git_auth_error "$stderr_content"; then
            retry_count=$((retry_count + 1))
            log_warn "git push 認証エラーを検出 (試行 $retry_count/$GIT_AUTH_MAX_RETRIES)"
            log_warn "stderr: $stderr_content"

            # キャッシュ無効化→次のループで get_cached_bot_token が新規取得する
            _invalidate_bot_token_cache

            if [[ $retry_count -lt $GIT_AUTH_MAX_RETRIES ]]; then
                log_warn "git push リトライ (${GIT_AUTH_RETRY_DELAY}秒後...)"
                sleep "$GIT_AUTH_RETRY_DELAY"
            fi
        else
            # 認証エラー以外（ネットワーク障害、リモート拒否等）: リトライせず即失敗
            log_error "git push 失敗 (exit_code=$git_exit, 認証エラーではない)"
            [[ -n "$stderr_content" ]] && log_error "stderr: $stderr_content"
            rm -f "$stderr_tmp"
            return $git_exit
        fi
    done

    # 全リトライ失敗: 最終フォールバック（stale GH_TOKEN を除去して OAuth token で試行）
    log_warn "git push: Bot Token認証リトライ失敗。GH_TOKEN除去でフォールバック..."
    local final_exit=0
    env -u GH_TOKEN git push "$@" 2>"$stderr_tmp" || final_exit=$?
    if [[ $final_exit -eq 0 ]]; then
        rm -f "$stderr_tmp"
        return 0
    fi

    local final_stderr
    final_stderr=$(cat "$stderr_tmp" 2>/dev/null)
    rm -f "$stderr_tmp"
    log_error "git push 失敗 (全${GIT_AUTH_MAX_RETRIES}回リトライ+フォールバック失敗)"
    [[ -n "$final_stderr" ]] && log_error "stderr: $final_stderr"
    return $final_exit
}

# 安全なgit fetch（認証エラー検出→キャッシュ無効化→Token再取得→リトライ）
# 使用例:
#   safe_git_fetch origin                  # git fetch origin
#   safe_git_fetch origin main             # git fetch origin main
safe_git_fetch() {
    local retry_count=0
    local stderr_tmp
    stderr_tmp=$(mktemp)

    local repo=""
    repo=$(_get_repo_from_remote) || true

    while [[ $retry_count -lt $GIT_AUTH_MAX_RETRIES ]]; do
        local git_exit=0

        local fresh_token=""
        if [[ -n "$repo" ]]; then
            fresh_token=$(get_cached_bot_token "$repo" 2>/dev/null) || true
        fi

        if [[ -n "$fresh_token" ]] && [[ "$fresh_token" == ghs_* ]]; then
            GH_TOKEN="$fresh_token" git fetch "$@" 2>"$stderr_tmp" || git_exit=$?
        else
            env -u GH_TOKEN git fetch "$@" 2>"$stderr_tmp" || git_exit=$?
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

            _invalidate_bot_token_cache

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

    log_warn "git fetch: Bot Token認証リトライ失敗。GH_TOKEN除去でフォールバック..."
    local final_exit=0
    env -u GH_TOKEN git fetch "$@" 2>"$stderr_tmp" || final_exit=$?
    if [[ $final_exit -eq 0 ]]; then
        rm -f "$stderr_tmp"
        return 0
    fi

    local final_stderr
    final_stderr=$(cat "$stderr_tmp" 2>/dev/null)
    rm -f "$stderr_tmp"
    log_error "git fetch 失敗 (全${GIT_AUTH_MAX_RETRIES}回リトライ+フォールバック失敗)"
    [[ -n "$final_stderr" ]] && log_error "stderr: $final_stderr"
    return $final_exit
}

# 安全なgit pull（safe_git_fetchと同パターン）
# 使用例:
#   safe_git_pull origin main              # git pull origin main
safe_git_pull() {
    local retry_count=0
    local stderr_tmp
    stderr_tmp=$(mktemp)

    local repo=""
    repo=$(_get_repo_from_remote) || true

    while [[ $retry_count -lt $GIT_AUTH_MAX_RETRIES ]]; do
        local git_exit=0

        local fresh_token=""
        if [[ -n "$repo" ]]; then
            fresh_token=$(get_cached_bot_token "$repo" 2>/dev/null) || true
        fi

        if [[ -n "$fresh_token" ]] && [[ "$fresh_token" == ghs_* ]]; then
            GH_TOKEN="$fresh_token" git pull "$@" 2>"$stderr_tmp" || git_exit=$?
        else
            env -u GH_TOKEN git pull "$@" 2>"$stderr_tmp" || git_exit=$?
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

            _invalidate_bot_token_cache

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

    log_warn "git pull: Bot Token認証リトライ失敗。GH_TOKEN除去でフォールバック..."
    local final_exit=0
    env -u GH_TOKEN git pull "$@" 2>"$stderr_tmp" || final_exit=$?
    if [[ $final_exit -eq 0 ]]; then
        rm -f "$stderr_tmp"
        return 0
    fi

    local final_stderr
    final_stderr=$(cat "$stderr_tmp" 2>/dev/null)
    rm -f "$stderr_tmp"
    log_error "git pull 失敗 (全${GIT_AUTH_MAX_RETRIES}回リトライ+フォールバック失敗)"
    [[ -n "$final_stderr" ]] && log_error "stderr: $final_stderr"
    return $final_exit
}

# =============================================================================
# GitHub API ヘルパー（Bot Token自動適用）
# =============================================================================

_GH_API_BOT_WARNED=""
_gh_api() {
    local repo="$1"
    shift

    local bot_token
    bot_token=$(get_cached_bot_token "$repo") || true

    if [[ -n "$bot_token" ]] && [[ "$bot_token" == ghs_* ]]; then
        GH_TOKEN="$bot_token" gh "$@"
    else
        if [[ -z "$_GH_API_BOT_WARNED" ]]; then
            log_warn "Bot Token取得失敗。ユーザートークンで実行します。"
            _GH_API_BOT_WARNED=1
        fi
        gh "$@"
    fi
}

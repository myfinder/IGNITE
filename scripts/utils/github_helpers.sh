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

# 多重読み込み防止
if [[ -n "${_GITHUB_HELPERS_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_GITHUB_HELPERS_LOADED=1

# SCRIPT_DIR が未設定なら呼び出し元から推定
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# IGNITE_CONFIG_DIR の解決順序:
# 1. 環境変数 IGNITE_CONFIG_DIR が設定済みならそのまま使用
# 2. WORKSPACE_DIR/.ignite/ が存在すればそれを使用（ワークスペース設定優先）
# 3. フォールバック: PROJECT_ROOT/config
if [[ -z "${IGNITE_CONFIG_DIR:-}" ]]; then
    if [[ -n "${WORKSPACE_DIR:-}" && -d "${WORKSPACE_DIR}/.ignite" ]]; then
        IGNITE_CONFIG_DIR="${WORKSPACE_DIR}/.ignite"
    else
        _GH_HELPERS_PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
        IGNITE_CONFIG_DIR="$_GH_HELPERS_PROJECT_ROOT/config"
    fi
fi

# =============================================================================
# ログ関数（呼び出し元で未定義の場合のみ定義）
# =============================================================================

if ! declare -f log_info &>/dev/null; then
    _GH_GREEN='\033[0;32m'
    _GH_BLUE='\033[0;34m'
    _GH_YELLOW='\033[1;33m'
    _GH_RED='\033[0;31m'
    _GH_NC='\033[0m'

    log_info() { echo -e "${_GH_BLUE}[INFO]${_GH_NC} $1" >&2; }
    log_success() { echo -e "${_GH_GREEN}[OK]${_GH_NC} $1" >&2; }
    log_warn() { echo -e "${_GH_YELLOW}[WARN]${_GH_NC} $1" >&2; }
    log_error() { echo -e "${_GH_RED}[ERROR]${_GH_NC} $1" >&2; }
fi

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
        echo "/tmp/ignite-token-cache"
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
        echo "$token" > "$cache_file"
        chmod 600 "$cache_file"
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

#!/bin/bash
# GitHub App Token 取得スクリプト
# GitHub REST API を使用して Installation Access Token を生成します
#
# Exit Codes (sysexits.h 準拠):
#   0              成功
#   64 EX_USAGE    引数エラー（--repo 未指定等）
#   69 EX_UNAVAILABLE  必須コマンド未インストール（curl/openssl）
#   73 EX_CANTCREAT    JWT 生成失敗 / Token 生成失敗
#   75 EX_TEMPFAIL     一時的エラー（API rate limit, ネットワーク）
#   77 EX_NOPERM       権限エラー（App 未インストール, Installation ID 取得失敗）
#   78 EX_CONFIG       設定ファイルエラー（未作成, 値未設定, Private Key 不在）
#
# stdout はトークン出力専用。エラーメッセージは全て stderr に出力。

set -e
set -u

# Exit code 定数 (sysexits.h)
readonly EX_USAGE=64
readonly EX_UNAVAILABLE=69
readonly EX_CANTCREAT=73
readonly EX_TEMPFAIL=75
readonly EX_NOPERM=77
readonly EX_CONFIG=78

# スクリプトのディレクトリを取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/core.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${WORKSPACE_DIR:-}" ]] && setup_workspace_config "$WORKSPACE_DIR"

# YAMLユーティリティ
source "${SCRIPT_DIR}/../lib/yaml_utils.sh"

# error/warn エイリアス（後方互換）
error() { log_error "$1"; }
warn() { log_warn "$1"; }

# エラー + 修正手順を表示（stderrに出力）
error_with_action() {
    local error_msg="$1"
    local action_msg="$2"
    error "$error_msg"
    echo "" >&2
    echo -e "$action_msg" >&2
}

# =============================================================================
# 前提条件チェック
# =============================================================================

check_prerequisites() {
    local has_error=false

    if ! command -v curl &> /dev/null; then
        error "curl がインストールされていません"
        echo "  インストール: https://curl.se/" >&2
        has_error=true
    fi

    if ! command -v openssl &> /dev/null; then
        error "openssl がインストールされていません"
        echo "  インストール: https://www.openssl.org/" >&2
        has_error=true
    fi

    if [[ "$has_error" == true ]]; then
        exit $EX_UNAVAILABLE
    fi
}

# =============================================================================
# 設定ファイル読み込み
# =============================================================================

load_config() {
    local config_file="${IGNITE_GITHUB_CONFIG:-${IGNITE_CONFIG_DIR}/github-app.yaml}"

    if [[ ! -f "$config_file" ]]; then
        error_with_action \
            "設定ファイルが見つかりません: $config_file" \
            "設定ファイルを作成してください:\n  cp config/github-app.yaml.example config/github-app.yaml\n\nまたは環境変数で指定:\n  export IGNITE_GITHUB_CONFIG=/path/to/github-app.yaml"
        exit $EX_CONFIG
    fi

    # YAMLから値を取得
    APP_ID=$(yaml_get "$config_file" 'app_id')
    PRIVATE_KEY_PATH=$(yaml_get "$config_file" 'private_key_path')

    # パス解決: 相対パスは .ignite/ ディレクトリ基準で解決
    PRIVATE_KEY_PATH="${PRIVATE_KEY_PATH/#\~/$HOME}"
    if [[ -n "$PRIVATE_KEY_PATH" ]] && [[ "$PRIVATE_KEY_PATH" != /* ]]; then
        PRIVATE_KEY_PATH="$(dirname "$config_file")/$PRIVATE_KEY_PATH"
    fi

    # 値の検証
    if [[ -z "$APP_ID" ]] || [[ "$APP_ID" == "YOUR_APP_ID" ]]; then
        error_with_action \
            "app_id が設定されていません" \
            "設定ファイル: $config_file"
        exit $EX_CONFIG
    fi

    if [[ -z "$PRIVATE_KEY_PATH" ]]; then
        error_with_action \
            "private_key_path が設定されていません" \
            "設定ファイル: $config_file"
        exit $EX_CONFIG
    fi

    if [[ ! -f "$PRIVATE_KEY_PATH" ]]; then
        error_with_action \
            "Private Key ファイルが見つかりません: $PRIVATE_KEY_PATH" \
            "Private Key を生成してください:\n  1. https://github.com/settings/apps にアクセス\n  2. 対象のAppを選択\n  3. 'Generate a private key' をクリック\n  4. ダウンロードした .pem ファイルを $PRIVATE_KEY_PATH に保存"
        exit $EX_CONFIG
    fi
}

# =============================================================================
# GitHub API ベースURL
# =============================================================================

_normalize_host() {
    local host="$1"
    host="${host#https://}"
    host="${host#http://}"
    echo "$host"
}

get_github_api_base() {
    if [[ -n "${GITHUB_API_URL:-}" ]]; then
        echo "${GITHUB_API_URL%/}"
        return
    fi
    if [[ -n "${GITHUB_API_BASE:-}" ]]; then
        echo "${GITHUB_API_BASE%/}"
        return
    fi
    if [[ -n "${GITHUB_HOSTNAME:-}" ]]; then
        echo "https://$( _normalize_host "${GITHUB_HOSTNAME}" )/api/v3"
        return
    fi
    if [[ -n "${GITHUB_BASE_URL:-}" ]]; then
        local host
        host=$( _normalize_host "${GITHUB_BASE_URL}" )
        echo "https://${host}/api/v3"
        return
    fi
    echo "https://api.github.com"
}

# =============================================================================
# JWT 生成
# =============================================================================

_b64url() {
    openssl base64 -A | tr '+/' '-_' | tr -d '='
}

generate_jwt() {
    local now
    now=$(date +%s)
    local iat=$((now - 60))
    local exp=$((now + 540))

    local header payload
    header=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | _b64url)
    payload=$(printf '%s' "{\"iat\":${iat},\"exp\":${exp},\"iss\":${APP_ID}}" | _b64url)

    local signature
    signature=$(printf '%s' "${header}.${payload}" | openssl dgst -sha256 -sign "$PRIVATE_KEY_PATH" | _b64url)

    if [[ -z "$signature" ]]; then
        return 1
    fi
    echo "${header}.${payload}.${signature}"
}

# =============================================================================
# API リクエスト
# =============================================================================

HTTP_STATUS=""

api_request() {
    local method="$1"
    local url="$2"
    local token="$3"
    local data="${4:-}"

    local headers_tmp body_tmp
    headers_tmp=$(mktemp)
    body_tmp=$(mktemp)

    local -a curl_args=(
        -sS
        -X "$method"
        -D "$headers_tmp"
        -o "$body_tmp"
        -H "Accept: application/vnd.github+json"
        -H "X-GitHub-Api-Version: 2022-11-28"
        -H "Authorization: Bearer $token"
    )

    if [[ -n "$data" ]]; then
        curl_args+=( -H "Content-Type: application/json" -d "$data" )
    fi

    curl "${curl_args[@]}" "$url" || true

    HTTP_STATUS=$(awk 'NR==1 {print $2}' "$headers_tmp")
    cat "$body_tmp"
    rm -f "$headers_tmp" "$body_tmp"
}

_json_get() {
    local expr="$1"
    if command -v jq >/dev/null 2>&1; then
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
# リポジトリから Installation ID を取得
# =============================================================================

get_installation_id_for_repo() {
    local repo="$1"
    local jwt_token
    jwt_token=$(generate_jwt) || {
        error "JWTトークンの生成に失敗しました"
        return $EX_CANTCREAT
    }

    local api_base
    api_base=$(get_github_api_base)
    local body
    body=$(api_request "GET" "${api_base}/repos/${repo}/installation" "$jwt_token")

    local installation_id
    installation_id=$(printf '%s' "$body" | _json_get '.id')

    if [[ -z "$installation_id" ]] || [[ "$installation_id" == "null" ]]; then
        case "$HTTP_STATUS" in
            401)
                error_with_action \
                    "認証エラー: JWT トークンが無効です (HTTP 401)" \
                    "確認事項:\n  - App ID が正しいか\n  - Private Key が正しいか（期限切れの可能性）"
                return $EX_CANTCREAT
                ;;
            403|404)
                error_with_action \
                    "リポジトリ ${repo} のInstallation IDを取得できませんでした (HTTP ${HTTP_STATUS})" \
                    "確認事項:\n  - GitHub Appがリポジトリにインストールされているか\n  - Organizationリポジトリの場合、Organizationにインストールされているか"
                return $EX_NOPERM
                ;;
            429)
                error "API rate limit に達しました (HTTP 429)。しばらく待ってから再実行してください"
                return $EX_TEMPFAIL
                ;;
            *)
                error_with_action \
                    "リポジトリ ${repo} のInstallation IDを取得できませんでした" \
                    "確認事項:\n  - GitHub Appがリポジトリにインストールされているか\n  - Organizationリポジトリの場合、Organizationにインストールされているか"
                return $EX_CANTCREAT
                ;;
        esac
    fi

    echo "$installation_id"
}

# =============================================================================
# トークン生成
# =============================================================================

generate_token() {
    local jwt_token
    jwt_token=$(generate_jwt) || {
        error "JWTトークンの生成に失敗しました"
        exit $EX_CANTCREAT
    }

    local api_base
    api_base=$(get_github_api_base)
    local body
    body=$(api_request "POST" "${api_base}/app/installations/${INSTALLATION_ID}/access_tokens" "$jwt_token" "{}")

    if [[ "$HTTP_STATUS" != "201" && "$HTTP_STATUS" != "200" ]]; then
        case "$HTTP_STATUS" in
            401)
                error "認証エラー: JWT トークンが無効です (HTTP 401)"
                exit $EX_CANTCREAT
                ;;
            403)
                error "権限エラー: Installation Access Token 生成に失敗しました (HTTP 403)"
                exit $EX_NOPERM
                ;;
            429)
                error "API rate limit に達しました (HTTP 429)。しばらく待ってから再実行してください"
                exit $EX_TEMPFAIL
                ;;
            *)
                error "トークンの生成に失敗しました (HTTP ${HTTP_STATUS})"
                exit $EX_CANTCREAT
                ;;
        esac
    fi

    local token
    token=$(printf '%s' "$body" | _json_get '.token')
    if [[ -z "$token" ]]; then
        error_with_action \
            "トークンの生成に失敗しました" \
            "以下を確認してください:\n  - App ID: $APP_ID\n  - Installation ID: $INSTALLATION_ID\n  - Private Key: $PRIVATE_KEY_PATH"
        exit $EX_CANTCREAT
    fi

    echo "$token"
}

# =============================================================================
# ヘルプ
# =============================================================================

show_help() {
    cat << 'HELPEOF'
GitHub App Token 取得スクリプト

使用方法:
  ./scripts/utils/get_github_app_token.sh --repo <owner/repo>

オプション:
  -r, --repo REPO    リポジトリ（owner/repo形式）【必須】
                     リポジトリからInstallation IDを動的に取得します
  -c, --check        前提条件のみチェック
  -h, --help         このヘルプを表示

環境変数:
  IGNITE_GITHUB_CONFIG    設定ファイルのパス（デフォルト: config/github-app.yaml）
  GITHUB_API_URL          GitHub API のベースURL（GHE対応）
  GITHUB_BASE_URL         GitHub Web のベースURL（GHE対応）
  GITHUB_HOSTNAME         GitHub ホスト名（GHE対応）

Exit Codes (sysexits.h 準拠):
  0   成功
  64  引数エラー（--repo 未指定等）
  69  必須コマンド未インストール（curl/openssl）
  73  JWT 生成失敗 / Token 生成失敗
  75  一時的エラー（API rate limit）
  77  権限エラー（App 未インストール等）
  78  設定ファイルエラー

出力:
  成功時: GitHub App Installation Access Token を stdout に出力
  失敗時: エラーメッセージを stderr に出力

使用例:
  # トークンを取得
  TOKEN=$(./scripts/utils/get_github_app_token.sh --repo myorg/myrepo)

  # Bot名義でIssueにコメント
  ./scripts/utils/comment_on_issue.sh 1 --repo myorg/myrepo --bot --body "Hello"

  # 前提条件のチェックのみ
  ./scripts/utils/get_github_app_token.sh --check
HELPEOF
}

# =============================================================================
# メイン
# =============================================================================

main() {
    local repo=""

    # 引数解析
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -c|--check)
                check_prerequisites
                load_config
                echo "前提条件OK: curl, openssl, 設定ファイル" >&2
                exit 0
                ;;
            -r|--repo)
                if [[ -z "${2:-}" ]]; then
                    error "--repo オプションにはリポジトリ名が必要です（例: owner/repo）"
                    exit $EX_USAGE
                fi
                repo="$2"
                shift 2
                ;;
            "")
                break
                ;;
            *)
                error "Unknown option: $1"
                show_help
                exit $EX_USAGE
                ;;
        esac
    done

    # --repo は必須
    if [[ -z "$repo" ]]; then
        error_with_action \
            "--repo オプションは必須です" \
            "使用方法:\n  ./scripts/utils/get_github_app_token.sh --repo owner/repo"
        exit $EX_USAGE
    fi

    check_prerequisites
    load_config

    # リポジトリからinstallation_idを動的取得
    INSTALLATION_ID=$(get_installation_id_for_repo "$repo") || exit $?

    generate_token
}

main "$@"

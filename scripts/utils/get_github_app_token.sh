#!/bin/bash
# GitHub App Token 取得スクリプト
# gh-token拡張を使用してInstallation Access Tokenを生成します
#
# Exit Codes (sysexits.h 準拠):
#   0              成功
#   64 EX_USAGE    引数エラー（--repo 未指定等）
#   69 EX_UNAVAILABLE  gh CLI / gh-token 拡張が未インストール
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
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# =============================================================================
# XDG パス解決（インストールモード vs 開発モード）
# =============================================================================

XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"

# インストールモード判定: ~/.config/ignite/.install_paths が存在するか
if [[ -z "${IGNITE_CONFIG_DIR:-}" ]]; then
    if [[ -f "$XDG_CONFIG_HOME/ignite/.install_paths" ]]; then
        # インストールモード: XDGパスを使用
        IGNITE_CONFIG_DIR="$XDG_CONFIG_HOME/ignite"
    else
        # 開発モード: PROJECT_ROOTを使用
        IGNITE_CONFIG_DIR="$PROJECT_ROOT/config"
    fi
fi

# YAMLユーティリティ
source "${SCRIPT_DIR}/../lib/yaml_utils.sh"

# カラー定義
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# エラー出力（stderrに出力）
error() { echo -e "${RED}Error: $1${NC}" >&2; }
warn() { echo -e "${YELLOW}Warning: $1${NC}" >&2; }

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

    # gh CLI チェック
    if ! command -v gh &> /dev/null; then
        error "gh CLI がインストールされていません"
        echo "  インストール: https://cli.github.com/" >&2
        has_error=true
    fi

    # gh-token 拡張チェック
    if ! gh extension list 2>/dev/null | grep -q "gh-token"; then
        error "gh-token 拡張がインストールされていません"
        echo "  インストール: gh extension install Link-/gh-token" >&2
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

    # チルダをホームディレクトリに展開
    PRIVATE_KEY_PATH="${PRIVATE_KEY_PATH/#\~/$HOME}"

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
# リポジトリからInstallation IDを取得
# =============================================================================

get_installation_id_for_repo() {
    local repo="$1"
    local jwt_token
    local installation_id
    local api_stderr
    local http_status

    # JWTトークンを生成（App認証用）
    # --jwt オプションでJWTを直接取得（--token-onlyはJWTモードでは使用不可）
    jwt_token=$(gh token generate \
        --app-id "$APP_ID" \
        --key "$PRIVATE_KEY_PATH" \
        --jwt 2>/dev/null) || true

    if [[ -z "$jwt_token" ]]; then
        error "JWTトークンの生成に失敗しました"
        return $EX_CANTCREAT
    fi

    # リポジトリのインストール情報を取得
    # JWT認証にはBearerヘッダーが必要（GH_TOKENはtokenタイプで送信されるため使用不可）
    # stderrをキャプチャしてHTTPステータスを判定
    api_stderr=$(mktemp)
    installation_id=$(gh api "/repos/${repo}/installation" \
        -H "Authorization: Bearer $jwt_token" \
        --jq '.id' 2>"$api_stderr") || true

    local api_err_content
    api_err_content=$(cat "$api_stderr" 2>/dev/null || true)
    rm -f "$api_stderr"

    if [[ -z "$installation_id" ]] || [[ "$installation_id" == "null" ]]; then
        # HTTPステータスコードでexit codeを振り分け
        http_status=""
        if [[ "$api_err_content" =~ HTTP\ ([0-9]+) ]]; then
            http_status="${BASH_REMATCH[1]}"
        fi

        case "$http_status" in
            401)
                error_with_action \
                    "認証エラー: JWT トークンが無効です (HTTP 401)" \
                    "確認事項:\n  - App ID が正しいか\n  - Private Key が正しいか（期限切れの可能性）"
                return $EX_CANTCREAT
                ;;
            403|404)
                error_with_action \
                    "リポジトリ ${repo} のInstallation IDを取得できませんでした (HTTP ${http_status})" \
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
    local result
    local token

    # gh-token 拡張でトークン生成
    result=$(gh token generate \
        --app-id "$APP_ID" \
        --installation-id "$INSTALLATION_ID" \
        --key "$PRIVATE_KEY_PATH" \
        2>/dev/null) || true

    if [[ -z "$result" ]]; then
        error_with_action \
            "トークンの生成に失敗しました" \
            "以下を確認してください:\n  - App ID: $APP_ID\n  - Installation ID: $INSTALLATION_ID\n  - Private Key: $PRIVATE_KEY_PATH"
        exit $EX_CANTCREAT
    fi

    # JSONからトークン値を抽出（jqがある場合）
    if command -v jq &> /dev/null; then
        token=$(echo "$result" | jq -r '.token // empty' 2>/dev/null)
        if [[ -n "$token" ]]; then
            echo "$token"
            return
        fi
    fi

    # jqがない場合やJSONでない場合はそのまま出力
    echo "$result"
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

Exit Codes (sysexits.h 準拠):
  0   成功
  64  引数エラー（--repo 未指定等）
  69  gh CLI / gh-token 拡張が未インストール
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
  GH_TOKEN="$TOKEN" gh issue comment 1 --repo myorg/myrepo --body "Hello"

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
                echo "前提条件OK: gh CLI, gh-token拡張, 設定ファイル" >&2
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

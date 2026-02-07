#!/bin/bash
# GitHub App Token 取得スクリプト
# gh-token拡張を使用してInstallation Access Tokenを生成します

set -e
set -u

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
        exit 1
    fi
}

# =============================================================================
# 設定ファイル読み込み
# =============================================================================

load_config() {
    local config_file="${IGNITE_GITHUB_CONFIG:-${IGNITE_CONFIG_DIR}/github-app.yaml}"

    if [[ ! -f "$config_file" ]]; then
        error "設定ファイルが見つかりません: $config_file"
        echo "" >&2
        echo "設定ファイルを作成してください:" >&2
        echo "  cp config/github-app.yaml.example config/github-app.yaml" >&2
        echo "" >&2
        echo "または環境変数で指定:" >&2
        echo "  export IGNITE_GITHUB_CONFIG=/path/to/github-app.yaml" >&2
        exit 1
    fi

    # YAMLから値を取得
    APP_ID=$(yaml_get "$config_file" 'app_id')
    PRIVATE_KEY_PATH=$(yaml_get "$config_file" 'private_key_path')

    # チルダをホームディレクトリに展開
    PRIVATE_KEY_PATH="${PRIVATE_KEY_PATH/#\~/$HOME}"

    # 値の検証
    if [[ -z "$APP_ID" ]] || [[ "$APP_ID" == "YOUR_APP_ID" ]]; then
        error "app_id が設定されていません"
        echo "  設定ファイル: $config_file" >&2
        exit 1
    fi

    if [[ -z "$PRIVATE_KEY_PATH" ]]; then
        error "private_key_path が設定されていません"
        echo "  設定ファイル: $config_file" >&2
        exit 1
    fi

    if [[ ! -f "$PRIVATE_KEY_PATH" ]]; then
        error "Private Key ファイルが見つかりません: $PRIVATE_KEY_PATH"
        echo "" >&2
        echo "Private Key を生成してください:" >&2
        echo "  1. https://github.com/settings/apps にアクセス" >&2
        echo "  2. 対象のAppを選択" >&2
        echo "  3. 'Generate a private key' をクリック" >&2
        echo "  4. ダウンロードした .pem ファイルを $PRIVATE_KEY_PATH に保存" >&2
        exit 1
    fi
}

# =============================================================================
# リポジトリからInstallation IDを取得
# =============================================================================

get_installation_id_for_repo() {
    local repo="$1"
    local jwt_token
    local installation_id

    # JWTトークンを生成（App認証用）
    # --jwt オプションでJWTを直接取得（--token-onlyはJWTモードでは使用不可）
    jwt_token=$(gh token generate \
        --app-id "$APP_ID" \
        --key "$PRIVATE_KEY_PATH" \
        --jwt 2>/dev/null)

    if [[ -z "$jwt_token" ]]; then
        error "JWTトークンの生成に失敗しました"
        return 1
    fi

    # リポジトリのインストール情報を取得
    # JWT認証にはBearerヘッダーが必要（GH_TOKENはtokenタイプで送信されるため使用不可）
    installation_id=$(gh api "/repos/${repo}/installation" \
        -H "Authorization: Bearer $jwt_token" \
        --jq '.id' 2>/dev/null)

    if [[ -z "$installation_id" ]] || [[ "$installation_id" == "null" ]]; then
        error "リポジトリ ${repo} のInstallation IDを取得できませんでした"
        echo "" >&2
        echo "確認事項:" >&2
        echo "  - GitHub Appがリポジトリにインストールされているか" >&2
        echo "  - Organizationリポジトリの場合、Organizationにインストールされているか" >&2
        return 1
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
        2>/dev/null)

    if [[ -z "$result" ]]; then
        error "トークンの生成に失敗しました"
        echo "" >&2
        echo "以下を確認してください:" >&2
        echo "  - App ID: $APP_ID" >&2
        echo "  - Installation ID: $INSTALLATION_ID" >&2
        echo "  - Private Key: $PRIVATE_KEY_PATH" >&2
        exit 1
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
    cat << 'EOF'
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

出力:
  成功時: GitHub App Installation Access Token を stdout に出力
  失敗時: エラーメッセージを stderr に出力し、終了コード 1 で終了

使用例:
  # トークンを取得
  TOKEN=$(./scripts/utils/get_github_app_token.sh --repo myorg/myrepo)

  # Bot名義でIssueにコメント
  GH_TOKEN="$TOKEN" gh issue comment 1 --repo myorg/myrepo --body "Hello"

  # 前提条件のチェックのみ
  ./scripts/utils/get_github_app_token.sh --check
EOF
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
                    exit 1
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
                exit 1
                ;;
        esac
    done

    # --repo は必須
    if [[ -z "$repo" ]]; then
        error "--repo オプションは必須です"
        echo "" >&2
        echo "使用方法:" >&2
        echo "  ./scripts/utils/get_github_app_token.sh --repo owner/repo" >&2
        exit 1
    fi

    check_prerequisites
    load_config

    # リポジトリからinstallation_idを動的取得
    INSTALLATION_ID=$(get_installation_id_for_repo "$repo")
    if [[ $? -ne 0 ]] || [[ -z "$INSTALLATION_ID" ]]; then
        exit 1
    fi

    generate_token
}

main "$@"

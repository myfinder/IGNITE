#!/bin/bash
# GitHub App Token 取得スクリプト
# gh-token拡張を使用してInstallation Access Tokenを生成します

set -e
set -u

# スクリプトのディレクトリを取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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
    local config_file="${IGNITE_GITHUB_CONFIG:-${PROJECT_ROOT}/config/github-app.yaml}"

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

    # YAMLから値を取得（grepとawkで簡易パース）
    # github_app: セクション配下の値を読み取る
    APP_ID=$(grep -E '^\s*app_id:' "$config_file" | head -1 | awk '{print $2}' | tr -d '"' | tr -d "'")
    INSTALLATION_ID=$(grep -E '^\s*installation_id:' "$config_file" | head -1 | awk '{print $2}' | tr -d '"' | tr -d "'")
    PRIVATE_KEY_PATH=$(grep -E '^\s*private_key_path:' "$config_file" | head -1 | awk '{print $2}' | tr -d '"' | tr -d "'")

    # チルダをホームディレクトリに展開
    PRIVATE_KEY_PATH="${PRIVATE_KEY_PATH/#\~/$HOME}"

    # 値の検証
    if [[ -z "$APP_ID" ]] || [[ "$APP_ID" == "YOUR_APP_ID" ]]; then
        error "app_id が設定されていません"
        echo "  設定ファイル: $config_file" >&2
        exit 1
    fi

    if [[ -z "$INSTALLATION_ID" ]] || [[ "$INSTALLATION_ID" == "YOUR_INSTALLATION_ID" ]]; then
        error "installation_id が設定されていません"
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
  ./scripts/utils/get_github_app_token.sh [オプション]

オプション:
  -h, --help    このヘルプを表示
  -c, --check   前提条件のみチェック

環境変数:
  IGNITE_GITHUB_CONFIG    設定ファイルのパス（デフォルト: config/github-app.yaml）

出力:
  成功時: GitHub App Installation Access Token を stdout に出力
  失敗時: エラーメッセージを stderr に出力し、終了コード 1 で終了

使用例:
  # トークンを取得
  TOKEN=$(./scripts/utils/get_github_app_token.sh)

  # Bot名義でIssueにコメント
  GH_TOKEN="$TOKEN" gh issue comment 1 --repo owner/repo --body "Hello"

  # 前提条件のチェックのみ
  ./scripts/utils/get_github_app_token.sh --check
EOF
}

# =============================================================================
# メイン
# =============================================================================

main() {
    case "${1:-}" in
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
        "")
            check_prerequisites
            load_config
            generate_token
            ;;
        *)
            error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"

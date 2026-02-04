#!/bin/bash
# IGNITE インストーラー
# XDG Base Directory Specification 準拠

set -e
set -u

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# カラー定義
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

print_info() { echo -e "${BLUE}$1${NC}"; }
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }
print_header() { echo -e "${BOLD}=== $1 ===${NC}"; }

# =============================================================================
# XDG パス定義
# =============================================================================

BIN_DIR="${IGNITE_BIN_DIR:-${XDG_BIN_HOME:-$HOME/.local/bin}}"
CONFIG_DIR="${IGNITE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/ignite}"
DATA_DIR="${IGNITE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/ignite}"

# インストールモードフラグ
FORCE=false
UPGRADE=false

# =============================================================================
# ヘルプ
# =============================================================================

show_help() {
    cat << EOF
IGNITE インストーラー v${VERSION}

使用方法:
  ./install.sh [オプション]

オプション:
  --bin-dir <path>     実行ファイルのインストール先 (デフォルト: ~/.local/bin)
  --config-dir <path>  設定ファイルのインストール先 (デフォルト: ~/.config/ignite)
  --data-dir <path>    データファイルのインストール先 (デフォルト: ~/.local/share/ignite)
  --upgrade            アップグレードモード (バイナリ・データは上書き、設定は保持)
  --force              既存ファイルをすべて上書き
  -h, --help           このヘルプを表示

環境変数:
  IGNITE_BIN_DIR       実行ファイルのインストール先
  IGNITE_CONFIG_DIR    設定ファイルのインストール先
  IGNITE_DATA_DIR      データファイルのインストール先
  XDG_BIN_HOME         XDG準拠の実行ファイルディレクトリ
  XDG_CONFIG_HOME      XDG準拠の設定ディレクトリ
  XDG_DATA_HOME        XDG準拠のデータディレクトリ

例:
  ./install.sh                         # 新規インストール
  ./install.sh --upgrade               # アップグレード (推奨)
  ./install.sh --force                 # すべて上書き
  ./install.sh --bin-dir /usr/local/bin
EOF
}

# =============================================================================
# 依存関係チェック
# =============================================================================

check_dependencies() {
    print_header "依存関係のチェック"

    local missing=()

    # 必須コマンド
    for cmd in tmux claude gh; do
        if command -v "$cmd" &> /dev/null; then
            print_success "$cmd が見つかりました"
        else
            print_error "$cmd が見つかりません"
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo ""
        print_warning "以下のコマンドをインストールしてください:"
        for cmd in "${missing[@]}"; do
            case "$cmd" in
                tmux)
                    echo "  - tmux: sudo apt install tmux (Ubuntu) / brew install tmux (macOS)"
                    ;;
                claude)
                    echo "  - claude: npm install -g @anthropic-ai/claude-code"
                    ;;
                gh)
                    echo "  - gh: https://cli.github.com/"
                    ;;
            esac
        done
        return 1
    fi

    return 0
}

# =============================================================================
# インストール処理
# =============================================================================

install_binary() {
    print_header "実行ファイルのインストール"

    mkdir -p "$BIN_DIR"

    local source_bin="$SCRIPT_DIR/bin/ignite"
    if [[ ! -f "$source_bin" ]]; then
        # 開発モード: scripts/ignite を使用
        source_bin="$SCRIPT_DIR/ignite"
    fi

    if [[ ! -f "$source_bin" ]]; then
        print_error "ignite 実行ファイルが見つかりません"
        return 1
    fi

    if [[ -f "$BIN_DIR/ignite" ]] && [[ "$FORCE" != "true" ]] && [[ "$UPGRADE" != "true" ]]; then
        print_warning "$BIN_DIR/ignite は既に存在します (--upgrade または --force で上書き)"
    else
        cp "$source_bin" "$BIN_DIR/ignite"
        chmod +x "$BIN_DIR/ignite"
        if [[ "$UPGRADE" == "true" ]]; then
            print_success "ignite を $BIN_DIR にアップグレードしました"
        else
            print_success "ignite を $BIN_DIR にインストールしました"
        fi
    fi
}

install_config() {
    print_header "設定ファイルのインストール"

    mkdir -p "$CONFIG_DIR"

    local source_config="$SCRIPT_DIR/config"
    if [[ ! -d "$source_config" ]]; then
        source_config="$SCRIPT_DIR/../config"
    fi

    if [[ ! -d "$source_config" ]]; then
        print_warning "設定ファイルディレクトリが見つかりません"
        return 0
    fi

    # 設定ファイルをコピー（既存ファイルは保持）
    for file in "$source_config"/*.yaml "$source_config"/*.yaml.example; do
        [[ -f "$file" ]] || continue
        local filename=$(basename "$file")
        local dest="$CONFIG_DIR/$filename"

        # .example ファイルは常にコピー
        if [[ "$filename" == *.example ]]; then
            cp "$file" "$dest"
            print_success "$filename をコピーしました"
            continue
        fi

        # 既存設定は保持（--upgrade でも --force 以外はスキップ）
        if [[ -f "$dest" ]] && [[ "$FORCE" != "true" ]]; then
            if [[ "$UPGRADE" == "true" ]]; then
                print_info "$filename は既に存在します (設定を保持)"
            else
                print_info "$filename は既に存在します (スキップ)"
            fi
        else
            cp "$file" "$dest"
            print_success "$filename をインストールしました"
        fi
    done
}

install_data() {
    print_header "データファイルのインストール"

    mkdir -p "$DATA_DIR"

    # instructions ディレクトリ
    local source_instructions="$SCRIPT_DIR/share/instructions"
    if [[ ! -d "$source_instructions" ]]; then
        source_instructions="$SCRIPT_DIR/../instructions"
    fi

    if [[ -d "$source_instructions" ]]; then
        mkdir -p "$DATA_DIR/instructions"
        cp -r "$source_instructions"/* "$DATA_DIR/instructions/"
        if [[ "$UPGRADE" == "true" ]]; then
            print_success "instructions を $DATA_DIR/instructions にアップグレードしました"
        else
            print_success "instructions を $DATA_DIR/instructions にインストールしました"
        fi
    fi

    # scripts/utils ディレクトリ
    local source_utils="$SCRIPT_DIR/share/scripts/utils"
    if [[ ! -d "$source_utils" ]]; then
        source_utils="$SCRIPT_DIR/utils"
        if [[ ! -d "$source_utils" ]]; then
            source_utils="$SCRIPT_DIR/../scripts/utils"
        fi
    fi

    if [[ -d "$source_utils" ]]; then
        mkdir -p "$DATA_DIR/scripts/utils"
        cp -r "$source_utils"/* "$DATA_DIR/scripts/utils/"
        chmod +x "$DATA_DIR/scripts/utils"/*.sh 2>/dev/null || true
        if [[ "$UPGRADE" == "true" ]]; then
            print_success "scripts/utils を $DATA_DIR/scripts/utils にアップグレードしました"
        else
            print_success "scripts/utils を $DATA_DIR/scripts/utils にインストールしました"
        fi
    fi
}

check_path() {
    print_header "PATH の確認"

    if [[ ":$PATH:" == *":$BIN_DIR:"* ]]; then
        print_success "$BIN_DIR は PATH に含まれています"
    else
        print_warning "$BIN_DIR が PATH に含まれていません"
        echo ""
        echo "以下を ~/.bashrc または ~/.zshrc に追加してください:"
        echo ""
        echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
        echo ""
    fi
}

write_config_paths() {
    # インストールパスを記録（ignite が参照するため）
    cat > "$CONFIG_DIR/.install_paths" << EOF
# IGNITE インストールパス (自動生成)
BIN_DIR="$BIN_DIR"
CONFIG_DIR="$CONFIG_DIR"
DATA_DIR="$DATA_DIR"
INSTALLED_VERSION="$VERSION"
INSTALLED_AT="$(date -Iseconds)"
EOF
    print_success "インストールパスを記録しました"
}

# =============================================================================
# メイン
# =============================================================================

main() {
    # 引数解析
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --bin-dir)
                BIN_DIR="$2"
                shift 2
                ;;
            --config-dir)
                CONFIG_DIR="$2"
                shift 2
                ;;
            --data-dir)
                DATA_DIR="$2"
                shift 2
                ;;
            --upgrade)
                UPGRADE=true
                shift
                ;;
            --force)
                FORCE=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                print_error "不明なオプション: $1"
                show_help
                exit 1
                ;;
        esac
    done

    echo ""
    print_header "IGNITE インストーラー v${VERSION}"
    echo ""
    echo "インストール先:"
    echo "  実行ファイル: $BIN_DIR"
    echo "  設定ファイル: $CONFIG_DIR"
    echo "  データ:       $DATA_DIR"
    echo ""

    # 依存関係チェック
    if ! check_dependencies; then
        echo ""
        print_error "依存関係が満たされていません"
        exit 1
    fi

    echo ""

    # インストール実行
    install_binary
    echo ""
    install_config
    echo ""
    install_data
    echo ""
    write_config_paths
    echo ""
    check_path

    echo ""
    if [[ "$UPGRADE" == "true" ]]; then
        print_header "アップグレード完了"
        echo ""
        print_success "IGNITE が正常にアップグレードされました！"
    else
        print_header "インストール完了"
        echo ""
        print_success "IGNITE が正常にインストールされました！"
    fi
    echo ""
    echo "使い方:"
    echo "  ignite start                    # システム起動"
    echo "  ignite start -w ~/my-workspace  # ワークスペース指定"
    echo "  ignite status                   # 状態確認"
    echo "  ignite --help                   # ヘルプ"
    echo ""
}

main "$@"

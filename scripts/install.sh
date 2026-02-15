#!/bin/bash
# IGNITE インストーラー
# XDG Base Directory Specification 準拠

set -e
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# バージョン取得: ビルド時に埋め込まれた値 → share/scripts/lib/core.sh → フォールバック
VERSION="__BUILD_VERSION__"
if [[ "$VERSION" == "__BUILD_VERSION__" ]]; then
    # ビルド前のソースから直接実行された場合
    local_core="$SCRIPT_DIR/share/scripts/lib/core.sh"
    if [[ ! -f "$local_core" ]]; then
        local_core="$SCRIPT_DIR/lib/core.sh"
    fi
    if [[ ! -f "$local_core" ]]; then
        local_core="$SCRIPT_DIR/../scripts/lib/core.sh"
    fi
    if [[ -f "$local_core" ]]; then
        VERSION=$(grep '^VERSION=' "$local_core" | head -1 | cut -d'"' -f2)
    fi
    VERSION="${VERSION:-0.0.0}"
fi

# カラー定義
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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
DATA_DIR="${IGNITE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/ignite}"
CONFIG_DIR="${IGNITE_CONFIG_DIR:-$DATA_DIR/config}"

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
  --config-dir <path>  設定ファイルのインストール先 (デフォルト: ~/.local/share/ignite/config)
  --data-dir <path>    データファイルのインストール先 (デフォルト: ~/.local/share/ignite)
  --upgrade            アップグレードモード (バイナリ・データは上書き、設定は保持)
  --force              既存ファイルをすべて上書き
  -h, --help           このヘルプを表示

環境変数:
  IGNITE_BIN_DIR       実行ファイルのインストール先
  IGNITE_CONFIG_DIR    設定ファイルのインストール先
  IGNITE_DATA_DIR      データファイルのインストール先
  XDG_BIN_HOME         XDG準拠の実行ファイルディレクトリ
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

    # system.yaml から CLI プロバイダーを簡易パース
    local cli_provider="opencode"
    local system_yaml="$CONFIG_DIR/system.yaml"
    if [[ -f "$system_yaml" ]]; then
        local _prov
        _prov=$(sed -n '/^cli:/,/^[^ ]/p' "$system_yaml" 2>/dev/null \
            | awk -F': ' '/^  provider:/{print $2; exit}' | sed 's/ *#.*//' | tr -d '"' | tr -d "'")
        [[ -n "$_prov" ]] && cli_provider="$_prov"
    fi

    # プロバイダーに応じた必須コマンドリスト
    local required_cmds="tmux gh"
    case "$cli_provider" in
        opencode) required_cmds="tmux opencode gh" ;;
        *)        required_cmds="tmux opencode gh" ;;
    esac

    for cmd in $required_cmds; do
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
                opencode)
                    echo "  - opencode: https://opencode.ai/"
                    ;;
                gh)
                    echo "  - gh: https://cli.github.com/"
                    ;;
            esac
        done
        return 1
    fi

    # オプション依存（なくても動作するが、機能が制限される）
    if command -v yq &>/dev/null; then
        print_success "yq が見つかりました"
    else
        print_warning "yq が見つかりません（オプション）"
        echo "  - yq: https://github.com/mikefarah/yq（v4.30以上推奨）"
        echo "  - YAML設定のネスト値・配列読み取りに使用します"
    fi

    return 0
}

# =============================================================================
# インストール処理
# =============================================================================

install_binary() {
    print_header "実行ファイルのインストール"

    mkdir -p "$BIN_DIR"

    if [[ -f "$BIN_DIR/ignite" ]] && [[ "$FORCE" != "true" ]] && [[ "$UPGRADE" != "true" ]]; then
        print_warning "$BIN_DIR/ignite は既に存在します (--upgrade または --force で上書き)"
    else
        # bin/ignite は薄いラッパー: 本体は DATA_DIR/scripts/ignite に委譲
        local source_bin="$SCRIPT_DIR/bin/ignite"
        if [[ -f "$source_bin" ]]; then
            cp "$source_bin" "$BIN_DIR/ignite"
        else
            # 開発モード: ラッパーを生成
            cat > "$BIN_DIR/ignite" << 'WRAPPER'
#!/bin/bash
# IGNITE launcher - delegates to the main script in DATA_DIR
DATA_DIR="${IGNITE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/ignite}"
exec "$DATA_DIR/scripts/ignite" "$@"
WRAPPER
        fi
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
        local filename
        filename=$(basename "$file")
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

    # characters ディレクトリ
    local source_characters="$SCRIPT_DIR/share/characters"
    if [[ ! -d "$source_characters" ]]; then
        source_characters="$SCRIPT_DIR/../characters"
    fi

    if [[ -d "$source_characters" ]]; then
        mkdir -p "$DATA_DIR/characters"
        cp -r "$source_characters"/* "$DATA_DIR/characters/"
        if [[ "$UPGRADE" == "true" ]]; then
            print_success "characters を $DATA_DIR/characters にアップグレードしました"
        else
            print_success "characters を $DATA_DIR/characters にインストールしました"
        fi
    fi

    # scripts/ignite 本体 + scripts/lib/ モジュール
    local source_scripts="$SCRIPT_DIR/share/scripts"
    if [[ ! -d "$source_scripts" ]]; then
        source_scripts="$SCRIPT_DIR/../scripts"
    fi

    # scripts/ignite 本体
    if [[ -f "$source_scripts/ignite" ]]; then
        mkdir -p "$DATA_DIR/scripts"
        cp "$source_scripts/ignite" "$DATA_DIR/scripts/ignite"
        chmod +x "$DATA_DIR/scripts/ignite"
        if [[ "$UPGRADE" == "true" ]]; then
            print_success "scripts/ignite を $DATA_DIR/scripts にアップグレードしました"
        else
            print_success "scripts/ignite を $DATA_DIR/scripts にインストールしました"
        fi
    fi

    # scripts/lib/ モジュール（.sh + .py）
    local source_lib="$source_scripts/lib"
    if [[ -d "$source_lib" ]]; then
        mkdir -p "$DATA_DIR/scripts/lib"
        cp "$source_lib"/*.sh "$DATA_DIR/scripts/lib/"
        cp "$source_lib"/*.py "$DATA_DIR/scripts/lib/" 2>/dev/null || true
        local count
        count=$(ls -1 "$DATA_DIR/scripts/lib"/*.sh "$DATA_DIR/scripts/lib"/*.py 2>/dev/null | wc -l)
        if [[ "$UPGRADE" == "true" ]]; then
            print_success "scripts/lib ($count モジュール) を $DATA_DIR/scripts/lib にアップグレードしました"
        else
            print_success "scripts/lib ($count モジュール) を $DATA_DIR/scripts/lib にインストールしました"
        fi
    fi

    # scripts/utils ディレクトリ
    local source_utils="$source_scripts/utils"
    if [[ ! -d "$source_utils" ]]; then
        source_utils="$SCRIPT_DIR/share/scripts/utils"
        if [[ ! -d "$source_utils" ]]; then
            source_utils="$SCRIPT_DIR/utils"
            if [[ ! -d "$source_utils" ]]; then
                source_utils="$SCRIPT_DIR/../scripts/utils"
            fi
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

    # scripts/schema.sql（メモリDB スキーマ）
    local source_schema="$source_scripts/schema.sql"
    if [[ -f "$source_schema" ]]; then
        cp "$source_schema" "$DATA_DIR/scripts/schema.sql"
        if [[ "$UPGRADE" == "true" ]]; then
            print_success "scripts/schema.sql を $DATA_DIR/scripts にアップグレードしました"
        else
            print_success "scripts/schema.sql を $DATA_DIR/scripts にインストールしました"
        fi
    fi

    # scripts/schema_migrate.sh（メモリDB マイグレーション）
    local source_schema_migrate="$source_scripts/schema_migrate.sh"
    if [[ -f "$source_schema_migrate" ]]; then
        cp "$source_schema_migrate" "$DATA_DIR/scripts/schema_migrate.sh"
        chmod +x "$DATA_DIR/scripts/schema_migrate.sh"
        if [[ "$UPGRADE" == "true" ]]; then
            print_success "scripts/schema_migrate.sh を $DATA_DIR/scripts にアップグレードしました"
        else
            print_success "scripts/schema_migrate.sh を $DATA_DIR/scripts にインストールしました"
        fi
    fi

    # templates ディレクトリ
    local source_templates="$SCRIPT_DIR/share/templates/systemd"
    if [[ ! -d "$source_templates" ]]; then
        source_templates="$SCRIPT_DIR/../templates/systemd"
    fi

    if [[ -d "$source_templates" ]]; then
        mkdir -p "$DATA_DIR/templates/systemd"
        cp "$source_templates"/*.service "$DATA_DIR/templates/systemd/"
        if [[ "$UPGRADE" == "true" ]]; then
            print_success "templates/systemd を $DATA_DIR/templates/systemd にアップグレードしました"
        else
            print_success "templates/systemd を $DATA_DIR/templates/systemd にインストールしました"
        fi
    fi

    # sqlite3 存在チェック
    if ! command -v sqlite3 &>/dev/null; then
        print_warning "sqlite3 が見つかりません。メモリ機能は無効になります。"
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
    cat > "$DATA_DIR/.install_paths" << EOF
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

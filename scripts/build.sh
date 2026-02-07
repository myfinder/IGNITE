#!/bin/bash
# IGNITE ビルドスクリプト
# 配布用アーカイブを生成

set -e
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# バージョン取得（lib/core.sh から）
VERSION=$(grep '^VERSION=' "$SCRIPT_DIR/lib/core.sh" | head -1 | cut -d'"' -f2)
if [[ -z "$VERSION" ]]; then
    VERSION="1.0.0"
fi

# OS検出（アーキテクチャは不要 - 純粋なBashスクリプトのため）
OS=$(uname -s | tr '[:upper:]' '[:lower:]')

# 出力設定
DIST_DIR="$PROJECT_ROOT/dist"
ARCHIVE_NAME="ignite-v${VERSION}-${OS}"
BUILD_DIR="$DIST_DIR/$ARCHIVE_NAME"

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

# sed_inplace - GNU/BSD 両対応の sed -i ラッパー（mktemp方式）
sed_inplace() {
    local pattern="$1"
    local file="$2"
    local tmp
    tmp="$(mktemp)"
    if sed "$pattern" "$file" > "$tmp"; then
        mv "$tmp" "$file"
    else
        rm -f "$tmp"
        return 1
    fi
}

# =============================================================================
# ヘルプ
# =============================================================================

show_help() {
    cat << EOF
IGNITE ビルドスクリプト

使用方法:
  ./scripts/build.sh [オプション]

オプション:
  --version <ver>  バージョン指定 (デフォルト: $VERSION)
  --output <dir>   出力ディレクトリ (デフォルト: ./dist)
  --clean          ビルド前にdistディレクトリをクリーン
  -h, --help       このヘルプを表示

出力:
  dist/ignite-v${VERSION}-${OS}.tar.gz

例:
  ./scripts/build.sh
  ./scripts/build.sh --version 1.1.0
  ./scripts/build.sh --clean
EOF
}

# =============================================================================
# ビルド処理
# =============================================================================

clean_dist() {
    print_header "クリーンアップ"
    if [[ -d "$DIST_DIR" ]]; then
        rm -rf "$DIST_DIR"
        print_success "dist ディレクトリを削除しました"
    fi
}

prepare_directories() {
    print_header "ディレクトリ準備"

    mkdir -p "$BUILD_DIR"/{bin,config,share/instructions,share/characters,share/scripts/utils,share/scripts/lib}
    print_success "ビルドディレクトリを作成しました: $BUILD_DIR"
}

copy_binary() {
    print_header "実行ファイルのコピー（ラッパー生成）"

    # bin/ignite は薄いラッパー: 本体は share/scripts/ignite に配置
    cat > "$BUILD_DIR/bin/ignite" << 'WRAPPER'
#!/bin/bash
# IGNITE launcher - delegates to the main script in DATA_DIR
DATA_DIR="${IGNITE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/ignite}"
exec "$DATA_DIR/scripts/ignite" "$@"
WRAPPER
    chmod +x "$BUILD_DIR/bin/ignite"
    print_success "ignite ラッパーを生成しました"
}

copy_main_script() {
    print_header "メインスクリプトのコピー"

    # scripts/ignite 本体
    cp "$SCRIPT_DIR/ignite" "$BUILD_DIR/share/scripts/ignite"
    chmod +x "$BUILD_DIR/share/scripts/ignite"
    print_success "scripts/ignite をコピーしました"

    # scripts/lib/ モジュール
    cp "$SCRIPT_DIR/lib"/*.sh "$BUILD_DIR/share/scripts/lib/"
    local count
    count=$(ls -1 "$BUILD_DIR/share/scripts/lib"/*.sh 2>/dev/null | wc -l)
    print_success "$count 個の lib モジュールをコピーしました"

    # scripts/schema.sql（メモリDB スキーマ）
    if [[ -f "$SCRIPT_DIR/schema.sql" ]]; then
        cp "$SCRIPT_DIR/schema.sql" "$BUILD_DIR/share/scripts/schema.sql"
        print_success "schema.sql をコピーしました"
    fi
}

copy_installers() {
    print_header "インストーラーのコピー"

    cp "$SCRIPT_DIR/install.sh" "$BUILD_DIR/install.sh"
    cp "$SCRIPT_DIR/uninstall.sh" "$BUILD_DIR/uninstall.sh"
    chmod +x "$BUILD_DIR/install.sh" "$BUILD_DIR/uninstall.sh"

    # __BUILD_VERSION__ プレースホルダーを実際のバージョンに置換
    sed_inplace "s/__BUILD_VERSION__/$VERSION/g" "$BUILD_DIR/install.sh"
    sed_inplace "s/__BUILD_VERSION__/$VERSION/g" "$BUILD_DIR/uninstall.sh"

    print_success "install.sh, uninstall.sh をコピーしました (VERSION=$VERSION)"
}

copy_config() {
    print_header "設定ファイルのコピー"

    local config_dir="$PROJECT_ROOT/config"

    # .example ファイルをコピー
    for file in "$config_dir"/*.yaml.example; do
        [[ -f "$file" ]] || continue
        cp "$file" "$BUILD_DIR/config/"
        print_success "$(basename "$file") をコピーしました"
    done

    # 公開可能な設定ファイルをコピー
    for file in pricing.yaml system.yaml characters.yaml; do
        if [[ -f "$config_dir/$file" ]]; then
            cp "$config_dir/$file" "$BUILD_DIR/config/"
            print_success "$file をコピーしました"
        fi
    done

    # 機密情報を含む可能性のあるファイルは .example のみ
    print_info "github-app.yaml, github-watcher.yaml は .example のみ含まれます"
}

copy_instructions() {
    print_header "instructions のコピー"

    cp -r "$PROJECT_ROOT/instructions"/* "$BUILD_DIR/share/instructions/"
    local count
    count=$(ls -1 "$BUILD_DIR/share/instructions"/*.md 2>/dev/null | wc -l)
    print_success "$count 個の instruction ファイルをコピーしました"
}

copy_characters() {
    print_header "characters のコピー"

    cp -r "$PROJECT_ROOT/characters"/* "$BUILD_DIR/share/characters/"
    local count
    count=$(ls -1 "$BUILD_DIR/share/characters"/*.md 2>/dev/null | wc -l)
    print_success "$count 個の character ファイルをコピーしました"
}

copy_utils() {
    print_header "ユーティリティスクリプトのコピー"

    cp "$SCRIPT_DIR/utils"/*.sh "$BUILD_DIR/share/scripts/utils/"
    chmod +x "$BUILD_DIR/share/scripts/utils"/*.sh
    local count
    count=$(ls -1 "$BUILD_DIR/share/scripts/utils"/*.sh 2>/dev/null | wc -l)
    print_success "$count 個のユーティリティスクリプトをコピーしました"
}

copy_readme() {
    print_header "README のコピー"

    # インストール用の簡易READMEを作成
    cat > "$BUILD_DIR/README.md" << 'EOF'
# IGNITE - Intelligent Generative Networked Interaction-driven Task Engine

## インストール

```bash
./install.sh
```

## アンインストール

```bash
./uninstall.sh
```

## 使い方

```bash
# システム起動
ignite start

# ワークスペース指定
ignite start -w ~/my-workspace

# 状態確認
ignite status

# 停止
ignite stop

# ヘルプ
ignite --help
```

## 詳細ドキュメント

https://github.com/myfinder/IGNITE
EOF
    print_success "README.md を作成しました"
}

create_archive() {
    print_header "アーカイブ作成"

    cd "$DIST_DIR"
    tar -czvf "${ARCHIVE_NAME}.tar.gz" "$ARCHIVE_NAME"
    print_success "${ARCHIVE_NAME}.tar.gz を作成しました"

    # チェックサム生成
    sha256sum "${ARCHIVE_NAME}.tar.gz" > "${ARCHIVE_NAME}.tar.gz.sha256"
    print_success "SHA256 チェックサムを生成しました"

    cd "$PROJECT_ROOT"
}

show_summary() {
    print_header "ビルド完了"

    local archive_path="$DIST_DIR/${ARCHIVE_NAME}.tar.gz"
    local archive_size
    archive_size=$(du -h "$archive_path" | cut -f1)

    echo ""
    echo "出力ファイル:"
    echo "  $archive_path ($archive_size)"
    echo "  $archive_path.sha256"
    echo ""
    echo "アーカイブ内容:"
    tar -tzf "$archive_path" | head -20
    local total
    total=$(tar -tzf "$archive_path" | wc -l)
    if [[ $total -gt 20 ]]; then
        echo "  ... 他 $((total - 20)) ファイル"
    fi
    echo ""
    print_success "ビルドが正常に完了しました"
}

# =============================================================================
# メイン
# =============================================================================

main() {
    local CLEAN=false

    # 引数解析
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version)
                VERSION="$2"
                ARCHIVE_NAME="ignite-v${VERSION}-${OS}"
                BUILD_DIR="$DIST_DIR/$ARCHIVE_NAME"
                shift 2
                ;;
            --output)
                DIST_DIR="$2"
                BUILD_DIR="$DIST_DIR/$ARCHIVE_NAME"
                shift 2
                ;;
            --clean)
                CLEAN=true
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
    print_header "IGNITE ビルド v${VERSION}"
    echo ""
    echo "OS: $OS"
    echo "Output: $DIST_DIR/${ARCHIVE_NAME}.tar.gz"
    echo ""

    # ビルド実行
    if [[ "$CLEAN" == "true" ]]; then
        clean_dist
        echo ""
    fi

    prepare_directories
    echo ""
    copy_binary
    echo ""
    copy_main_script
    echo ""
    copy_installers
    echo ""
    copy_config
    echo ""
    copy_instructions
    echo ""
    copy_characters
    echo ""
    copy_utils
    echo ""
    copy_readme
    echo ""
    create_archive
    echo ""
    show_summary
}

main "$@"

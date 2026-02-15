#!/bin/bash
# IGNITE アンインストーラー
# XDG Base Directory Specification 準拠

set -e
set -u

SCRIPT_DIR_TMP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="__BUILD_VERSION__"
if [[ "$VERSION" == "__BUILD_VERSION__" ]]; then
    local_core="$SCRIPT_DIR_TMP/share/scripts/lib/core.sh"
    if [[ ! -f "$local_core" ]]; then
        local_core="$SCRIPT_DIR_TMP/lib/core.sh"
    fi
    if [[ ! -f "$local_core" ]]; then
        local_core="$SCRIPT_DIR_TMP/../scripts/lib/core.sh"
    fi
    if [[ -f "$local_core" ]]; then
        VERSION=$(grep '^VERSION=' "$local_core" | head -1 | cut -d'"' -f2)
    fi
    VERSION="${VERSION:-0.0.0}"
fi
unset SCRIPT_DIR_TMP

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
DATA_DIR="${IGNITE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/ignite}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/ignite"

# =============================================================================
# ヘルプ
# =============================================================================

show_help() {
    cat << EOF
IGNITE アンインストーラー v${VERSION}

使用方法:
  ./uninstall.sh [オプション]

オプション:
  --all        キャッシュもすべて削除（ワークスペースは残す）
  --dry-run    削除せずに対象ファイルを表示
  -y, --yes    確認なしで実行
  -h, --help   このヘルプを表示

削除対象:
  デフォルト:
    - $BIN_DIR/ignite (実行ファイル)
    - $DATA_DIR (データ・設定ファイル)

  --all:
    + $CACHE_DIR (キャッシュ)

保持されるもの:
  - ワークスペースディレクトリ (常に残す)

例:
  ./uninstall.sh              # 基本的なアンインストール
  ./uninstall.sh --all        # キャッシュも削除
  ./uninstall.sh --dry-run    # 削除対象を確認
EOF
}

# =============================================================================
# アンインストール処理
# =============================================================================

uninstall_binary() {
    print_header "実行ファイルの削除"

    if [[ -f "$BIN_DIR/ignite" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            print_info "[DRY-RUN] 削除: $BIN_DIR/ignite"
        else
            rm "$BIN_DIR/ignite"
            print_success "$BIN_DIR/ignite を削除しました"
        fi
    else
        print_info "$BIN_DIR/ignite は存在しません"
    fi
}

uninstall_data() {
    print_header "データファイルの削除"

    if [[ -d "$DATA_DIR" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            print_info "[DRY-RUN] 削除: $DATA_DIR"
            find "$DATA_DIR" -type f | head -10 | while read f; do
                echo "  - $f"
            done
            local count
            count=$(find "$DATA_DIR" -type f | wc -l)
            if [[ $count -gt 10 ]]; then
                echo "  ... 他 $((count - 10)) ファイル"
            fi
        else
            rm -rf "$DATA_DIR"
            print_success "$DATA_DIR を削除しました"
        fi
    else
        print_info "$DATA_DIR は存在しません"
    fi
}

uninstall_cache() {
    print_header "キャッシュの削除"

    if [[ -d "$CACHE_DIR" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            print_info "[DRY-RUN] 削除: $CACHE_DIR"
        else
            rm -rf "$CACHE_DIR"
            print_success "$CACHE_DIR を削除しました"
        fi
    else
        print_info "$CACHE_DIR は存在しません"
    fi
}

confirm_uninstall() {
    if [[ "$YES" == "true" ]]; then
        return 0
    fi

    echo ""
    print_warning "以下のファイル/ディレクトリが削除されます:"
    echo ""
    echo "  - $BIN_DIR/ignite"
    echo "  - $DATA_DIR"
    if [[ "$ALL" == "true" ]]; then
        echo "  - $CACHE_DIR"
    fi
    echo ""

    read -p "続行しますか? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "キャンセルしました"
        exit 0
    fi
}

# =============================================================================
# メイン
# =============================================================================

main() {
    local ALL=false
    local DRY_RUN=false
    local YES=false

    # 引数解析
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)
                ALL=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -y|--yes)
                YES=true
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
    print_header "IGNITE アンインストーラー v${VERSION}"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo ""
        print_warning "DRY-RUN モード: 実際には削除しません"
    fi

    # 確認
    if [[ "$DRY_RUN" != "true" ]]; then
        confirm_uninstall
    fi

    echo ""

    # アンインストール実行
    uninstall_binary
    echo ""
    uninstall_data

    if [[ "$ALL" == "true" ]]; then
        echo ""
        uninstall_cache
    fi

    echo ""
    if [[ "$DRY_RUN" == "true" ]]; then
        print_header "DRY-RUN 完了"
        print_info "実際に削除するには --dry-run を外して再実行してください"
    else
        print_header "アンインストール完了"
        print_success "IGNITE が正常にアンインストールされました"
    fi
    echo ""
}

main "$@"

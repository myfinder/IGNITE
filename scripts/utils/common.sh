#!/bin/bash
# =============================================================================
# IGNITE 共通モジュール
# カラー定義、ログ関数、XDGパス解決などの共通機能を提供
# =============================================================================
#
# 使用方法:
#   source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
#
# 提供する機能:
#   - カラー定義 (GREEN, BLUE, YELLOW, RED, CYAN, BOLD, NC)
#   - ログ関数 (log_info, log_success, log_warn, log_error)
#   - XDGパス解決 (resolve_ignite_paths)
#   - 移植性のある sed -i (sed_inplace)
#
# =============================================================================

# =============================================================================
# カラー定義
# =============================================================================

# ターミナルがカラーをサポートしているか確認
if [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]]; then
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    YELLOW='\033[1;33m'
    RED='\033[0;31m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    # 非対話モードではカラーを無効化
    GREEN=''
    BLUE=''
    YELLOW=''
    RED=''
    CYAN=''
    BOLD=''
    NC=''
fi

# =============================================================================
# ログ関数
# =============================================================================

# タイムスタンプ付きログ出力
log_info() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${GREEN}[OK]${NC} $1"
}

log_warn() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${RED}[ERROR]${NC} $1" >&2
}

# シンプルなログ出力（タイムスタンプなし）
print_info() {
    echo -e "${BLUE}$1${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}" >&2
}

print_header() {
    echo -e "${BOLD}=== $1 ===${NC}"
}

# =============================================================================
# XDGパス解決
# =============================================================================

# IGNITE のパスを解決する
# インストールモード（~/.config/ignite/.install_paths が存在）と
# 開発モード（PROJECT_ROOT を使用）を自動判定
#
# 設定される変数:
#   IGNITE_CONFIG_DIR - 設定ファイルディレクトリ
#   IGNITE_DATA_DIR   - データディレクトリ
#   IGNITE_INSTALLED_MODE - true/false
#
# 引数:
#   $1 - PROJECT_ROOT (オプション、開発モード時のフォールバック)
#
resolve_ignite_paths() {
    local project_root="${1:-}"

    # XDG Base Directory paths
    XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
    XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"

    # 環境変数で既に設定されていればそれを使用
    if [[ -n "${IGNITE_CONFIG_DIR:-}" ]]; then
        IGNITE_INSTALLED_MODE=false
        return 0
    fi

    # インストールモード判定
    if [[ -f "$XDG_CONFIG_HOME/ignite/.install_paths" ]]; then
        # インストールモード: XDGパスを使用
        IGNITE_CONFIG_DIR="$XDG_CONFIG_HOME/ignite"
        IGNITE_DATA_DIR="$XDG_DATA_HOME/ignite"
        IGNITE_INSTALLED_MODE=true
    elif [[ -n "$project_root" ]]; then
        # 開発モード: PROJECT_ROOTを使用
        IGNITE_CONFIG_DIR="$project_root/config"
        IGNITE_DATA_DIR="$project_root"
        IGNITE_INSTALLED_MODE=false
    else
        # フォールバック: スクリプトの場所から推測
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" && pwd)"
        local guessed_root
        guessed_root="$(cd "$script_dir/../.." 2>/dev/null && pwd)" || guessed_root="$script_dir"
        IGNITE_CONFIG_DIR="$guessed_root/config"
        IGNITE_DATA_DIR="$guessed_root"
        IGNITE_INSTALLED_MODE=false
    fi

    export IGNITE_CONFIG_DIR
    export IGNITE_DATA_DIR
    export IGNITE_INSTALLED_MODE
}

# =============================================================================
# ユーティリティ関数
# =============================================================================

# 移植性のある sed -i 実装 (GNU sed / BSD sed 両対応)
# 使用方法: sed_inplace 'pattern' file
sed_inplace() {
    local pattern="$1"
    local file="$2"
    local tmp
    tmp=$(mktemp)
    if sed "$pattern" "$file" > "$tmp" && [[ -s "$tmp" || ! -s "$file" ]]; then
        mv "$tmp" "$file"
    else
        rm -f "$tmp"
        return 1
    fi
}

# 移植性のある date 減算 (GNU date / BSD date 両対応)
# 使用方法: date_subtract "24 hours" または date_subtract "3 minutes"
date_subtract() {
    local amount="$1"
    local value="${amount%% *}"
    local unit="${amount#* }"

    if date --version &>/dev/null 2>&1; then
        # GNU date
        date -d "$amount ago" -Iseconds 2>/dev/null
    else
        # BSD date (macOS)
        local flag
        case "$unit" in
            hour|hours) flag="-v-${value}H" ;;
            minute|minutes) flag="-v-${value}M" ;;
            day|days) flag="-v-${value}d" ;;
            *) return 1 ;;
        esac
        date "$flag" -Iseconds 2>/dev/null
    fi
}

# =============================================================================
# 初期化
# =============================================================================

# このファイルが source された時に自動的にパス解決を試みる
# ただし、既に IGNITE_CONFIG_DIR が設定されている場合はスキップ
if [[ -z "${IGNITE_COMMON_LOADED:-}" ]]; then
    IGNITE_COMMON_LOADED=true
    # パス解決は明示的に呼び出す必要がある場合はコメントアウト
    # resolve_ignite_paths
fi

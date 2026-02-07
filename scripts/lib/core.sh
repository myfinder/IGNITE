# shellcheck shell=bash
# lib/core.sh - 定数・カラー定義・出力ヘルパー
[[ -n "${__LIB_CORE_LOADED:-}" ]] && return; __LIB_CORE_LOADED=1

VERSION="0.2.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# =============================================================================
# XDG パス解決（インストールモード vs 開発モード）
# =============================================================================

# XDG Base Directory paths
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"

# インストールモード判定: ~/.config/ignite/.install_paths が存在するか
INSTALLED_MODE=false
if [[ -f "$XDG_CONFIG_HOME/ignite/.install_paths" ]]; then
    INSTALLED_MODE=true
fi

# パス解決
if [[ "$INSTALLED_MODE" == "true" ]]; then
    # インストールモード: XDGパスを使用
    IGNITE_CONFIG_DIR="$XDG_CONFIG_HOME/ignite"
    IGNITE_DATA_DIR="$XDG_DATA_HOME/ignite"
    IGNITE_INSTRUCTIONS_DIR="$IGNITE_DATA_DIR/instructions"
    IGNITE_SCRIPTS_DIR="$IGNITE_DATA_DIR/scripts"
    DEFAULT_WORKSPACE_DIR="$HOME/ignite-workspace"
else
    # 開発モード: PROJECT_ROOTを使用
    IGNITE_CONFIG_DIR="$PROJECT_ROOT/config"
    IGNITE_DATA_DIR="$PROJECT_ROOT"
    IGNITE_INSTRUCTIONS_DIR="$PROJECT_ROOT/instructions"
    IGNITE_SCRIPTS_DIR="$PROJECT_ROOT/scripts"
    DEFAULT_WORKSPACE_DIR="$PROJECT_ROOT/workspace"
fi

# セッション名とワークスペース（後でコマンドラインで上書き可能）
SESSION_NAME=""
WORKSPACE_DIR=""

# Sub-Leaders 定義
SUB_LEADERS=("strategist" "architect" "evaluator" "coordinator" "innovator")
SUB_LEADER_NAMES=("義賀リオ" "祢音ナナ" "衣結ノア" "通瀬アイナ" "恵那ツムギ")
LEADER_NAME="伊羽ユイ"

# デフォルト設定
DEFAULT_MODEL="claude-opus-4-6"
DEFAULT_WORKER_COUNT=8

# Claude セッションデータのパス（PROJECT_ROOT から動的に生成）
# Claude Code は /path/to/project を -path-to-project に変換してディレクトリ名にする
CLAUDE_PROJECTS_DIR="$HOME/.claude/projects/$(echo "$PROJECT_ROOT" | sed 's|/|-|g')"

# カラー定義（TTY検出 + NO_COLOR対応）
if [[ -n "${NO_COLOR:-}" ]] || ! [[ -t 1 ]] || [[ "${TERM:-}" == "dumb" ]]; then
    GREEN='' BLUE='' YELLOW='' RED='' CYAN='' BOLD='' NC=''
else
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    YELLOW='\033[1;33m'
    RED='\033[0;31m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
fi

# 共通出力関数
print_info() { echo -e "${BLUE}$1${NC}"; }
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}" >&2; }
print_header() { echo -e "${BOLD}${CYAN}=== $1 ===${NC}"; }

# タイムスタンプ付きログ関数（stderr出力）
log_info()    { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${BLUE}[INFO]${NC} $1" >&2; }
log_success() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${GREEN}[OK]${NC} $1" >&2; }
log_warn()    { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${YELLOW}[WARN]${NC} $1" >&2; }
log_error()   { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${RED}[ERROR]${NC} $1" >&2; }

# sed_inplace - GNU/BSD 両対応の sed -i ラッパー（mktemp方式）
# Usage: sed_inplace "pattern" "file"
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

# yaml_set_fields - YAMLファイルのトップレベルフィールドを安全に追記・上書き
# Usage: yaml_set_fields <file> <key1=value1> [key2=value2] ...
# 既存キーは削除後に追記、新規キーはそのまま追記（mktemp方式でBSD互換）
yaml_set_fields() {
    local file="$1"
    shift

    [[ -f "$file" ]] || return 1

    local tmp
    tmp="$(mktemp)"
    cp "$file" "$tmp"

    local key val
    for pair in "$@"; do
        key="${pair%%=*}"
        val="${pair#*=}"
        # 既存行を削除（mktemp方式）
        local tmp2
        tmp2="$(mktemp)"
        sed "/^${key}:/d" "$tmp" > "$tmp2" && mv "$tmp2" "$tmp" || rm -f "$tmp2"
        # 追記
        printf '%s: %s\n' "$key" "$val" >> "$tmp"
    done

    mv "$tmp" "$file"
}

# get_delay - delays セクションから遅延値を取得（数値バリデーション付き）
# Usage: get_delay <key> <default>
get_delay() {
    local key="$1" default="$2"
    local config_file="$IGNITE_CONFIG_DIR/system.yaml"
    local value
    value=$(sed -n '/^delays:/,/^[^ ]/p' "$config_file" 2>/dev/null | awk '/^  '"$key"':/{print $2; exit}')
    [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]] || value=""
    echo "${value:-$default}"
}

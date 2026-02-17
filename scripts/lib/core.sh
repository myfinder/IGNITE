# shellcheck shell=bash
# lib/core.sh - 定数・カラー定義・出力ヘルパー
[[ -n "${__LIB_CORE_LOADED:-}" ]] && return; __LIB_CORE_LOADED=1

VERSION="0.5.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# =============================================================================
# パス解決（PROJECT_ROOT ベース）
# =============================================================================

# 設定ディレクトリ解決:
# 1. 環境変数 IGNITE_CONFIG_DIR が設定済みならそのまま使用
# 2. フォールバック: PROJECT_ROOT/config
if [[ -z "${IGNITE_CONFIG_DIR:-}" ]]; then
    IGNITE_CONFIG_DIR="$PROJECT_ROOT/config"
fi
IGNITE_DATA_DIR="$PROJECT_ROOT"
IGNITE_INSTRUCTIONS_DIR="$PROJECT_ROOT/instructions"
IGNITE_CHARACTERS_DIR="$PROJECT_ROOT/characters"
IGNITE_SCRIPTS_DIR="$PROJECT_ROOT/scripts"
DEFAULT_WORKSPACE_DIR="$PROJECT_ROOT/workspace"
IGNITE_RUNTIME_DIR=""  # setup_workspace_config で設定

# セッション名とワークスペース（後でコマンドラインで上書き可能）
SESSION_NAME="${SESSION_NAME:-}"
WORKSPACE_DIR="${WORKSPACE_DIR:-}"

# Sub-Leaders 定義（ロール構成はコード固定、名前は characters.yaml から読み込み）
SUB_LEADERS=("strategist" "architect" "evaluator" "coordinator" "innovator")
LEADER_NAME="Leader"
SUB_LEADER_NAMES=("Strategist" "Architect" "Evaluator" "Coordinator" "Innovator")

# characters.yaml からキャラクター名を読み込み
_CHARACTERS_FILE="$IGNITE_CONFIG_DIR/characters.yaml"
if [[ -f "$_CHARACTERS_FILE" ]]; then
    _name=$(sed -n '/^leader:/,/^[^ ]/p' "$_CHARACTERS_FILE" 2>/dev/null \
        | awk -F': ' '/^  name:/{print $2; exit}' | tr -d '"' | tr -d "'")
    [[ -n "$_name" ]] && LEADER_NAME="$_name"

    for _i in "${!SUB_LEADERS[@]}"; do
        _role="${SUB_LEADERS[$_i]}"
        _name=$(sed -n '/^sub_leaders:/,/^[^ ]/p' "$_CHARACTERS_FILE" 2>/dev/null \
            | awk -F': ' '/^  '"$_role"':/{print $2; exit}' | tr -d '"' | tr -d "'")
        [[ -n "$_name" ]] && SUB_LEADER_NAMES[$_i]="$_name"
    done
    unset _name _role _i
fi
unset _CHARACTERS_FILE

# デフォルト設定
DEFAULT_MODEL="openai/gpt-5.2-codex"
DEFAULT_WORKER_COUNT=3

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
# 第2引数でプレフィックスを任意指定可能（後方互換: 省略時はデフォルト値）
log_info()    { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${BLUE}[${2:-INFO}]${NC} $1" >&2; }
log_success() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${GREEN}[${2:-OK}]${NC} $1" >&2; }
log_warn()    { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${YELLOW}[${2:-WARN}]${NC} $1" >&2; }
log_error()   { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${RED}[${2:-ERROR}]${NC} $1" >&2; }

# 進捗表示の共通フォーマット
# 形式: stage=<stage> percent=<0-100> message=<message>
PROGRESS_STAGE_DEFAULT="working"
PROGRESS_PERCENT_DEFAULT="0"

# format_progress_message <stage> <percent> <message>
# stdout: stage=<stage> percent=<percent> message=<message>
format_progress_message() {
    local stage="${1:-$PROGRESS_STAGE_DEFAULT}"
    local percent="${2:-$PROGRESS_PERCENT_DEFAULT}"
    local message="${3:-}"
    printf 'stage=%s percent=%s message=%s\n' "$stage" "$percent" "$message"
}

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
    value=$(sed -n '/^delays:/,/^[^ ]/p' "$config_file" 2>/dev/null | awk -F': ' '/^  '"$key"':/{print $2; exit}')
    [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]] || value=""
    echo "${value:-$default}"
}

# get_config - 任意セクションから設定値を取得
# Usage: get_config <section> <key> <default>
get_config() {
    local section="$1" key="$2" default="$3"
    local config_file="$IGNITE_CONFIG_DIR/system.yaml"
    local value
    value=$(sed -n "/^${section}:/,/^[^ ]/p" "$config_file" 2>/dev/null \
        | awk -F': ' '/^  '"$key"':/{print $2; exit}' | sed 's/ *#.*//' | tr -d '"' | tr -d "'")
    echo "${value:-$default}"
}

# =============================================================================
# Workspace Config（.ignite/ 一本化）
# =============================================================================

# setup_workspace_config - .ignite/ を検出し IGNITE_CONFIG_DIR / IGNITE_RUNTIME_DIR を切り替え
# Usage: setup_workspace_config <workspace_dir>
# .ignite/ が存在する場合は全ランタイムディレクトリを .ignite/ 配下に統一
setup_workspace_config() {
    local ws_dir="${1:-$WORKSPACE_DIR}"
    local ignite_dir="${ws_dir}/.ignite"

    if [[ -d "$ignite_dir" ]]; then
        IGNITE_CONFIG_DIR="$ignite_dir"
        IGNITE_RUNTIME_DIR="$ignite_dir"
        log_info "ワークスペース設定を検出: $ignite_dir"

        # instructions: なければグローバルからコピー
        if [[ ! -d "$ignite_dir/instructions" ]]; then
            mkdir -p "$ignite_dir/instructions"
            cp "$IGNITE_INSTRUCTIONS_DIR"/*.md "$ignite_dir/instructions/" 2>/dev/null || true
        fi
        IGNITE_INSTRUCTIONS_DIR="$ignite_dir/instructions"

        # characters: なければグローバルからコピー
        if [[ ! -d "$ignite_dir/characters" ]]; then
            mkdir -p "$ignite_dir/characters"
            cp "$IGNITE_CHARACTERS_DIR"/*.md "$ignite_dir/characters/" 2>/dev/null || true
        fi
        IGNITE_CHARACTERS_DIR="$ignite_dir/characters"
    else
        # .ignite/ がない場合は WORKSPACE_DIR 直下（後方互換）
        IGNITE_RUNTIME_DIR="$ws_dir"
    fi
}

# resolve_config - IGNITE_CONFIG_DIR から設定ファイルを解決（1層）
# Usage: resolve_config <filename>
# Returns: 解決されたファイルのフルパス（stdout）
# Exit code: 0=見つかった, 1=見つからない
resolve_config() {
    local filename="$1"
    if [[ -f "${IGNITE_CONFIG_DIR}/${filename}" ]]; then
        echo "${IGNITE_CONFIG_DIR}/${filename}"
        return 0
    fi
    return 1
}

# system.yaml から読み込むグローバル設定
DEFAULT_MESSAGE_PRIORITY=$(get_config defaults message_priority "normal")

# CLI Provider 抽象化レイヤー
source "${SCRIPT_DIR}/cli_provider.sh"
cli_load_config

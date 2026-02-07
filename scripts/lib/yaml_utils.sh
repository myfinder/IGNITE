# shellcheck shell=bash
# lib/yaml_utils.sh - YAML読み取りユーティリティ（yqフォールバック付き）
[[ -n "${__LIB_YAML_UTILS_LOADED:-}" ]] && return; __LIB_YAML_UTILS_LOADED=1

# =============================================================================
# yq 利用可否の判定（起動時に1回だけ実行）
# =============================================================================

if command -v yq &>/dev/null; then
    _YQ_AVAILABLE=1
else
    _YQ_AVAILABLE=0
fi

# =============================================================================
# yaml_get <file> <key> [default]
#   トップレベルキーの値を取得する。
#   yq がある場合は yq、なければ grep+awk フォールバック。
#   値が空の場合は default を返す。常に exit 0。
# =============================================================================

yaml_get() {
    local file="$1"
    local key="$2"
    local default="${3:-}"
    local val=""

    if [[ "$_YQ_AVAILABLE" -eq 1 ]]; then
        val=$(yq -r ".${key} // \"\"" "$file" 2>/dev/null)
    else
        val=$(grep -E "^\\s*${key}:" "$file" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"' | tr -d "'")
    fi

    if [[ -z "$val" || "$val" == "null" ]]; then
        echo "$default"
    else
        echo "$val"
    fi
    return 0
}

# =============================================================================
# yaml_get_nested <file> <dotpath> [default]
#   ネストされたキーの値を取得する（例: .system.delays.leader_startup）。
#   yq 必須。未インストール時は default を返し stderr に警告。
# =============================================================================

yaml_get_nested() {
    local file="$1"
    local dotpath="$2"
    local default="${3:-}"
    local val=""

    if [[ "$_YQ_AVAILABLE" -eq 1 ]]; then
        val=$(yq -r "${dotpath} // \"\"" "$file" 2>/dev/null)
    else
        echo "[WARN] yaml_get_nested: yq が必要です (dotpath: ${dotpath})" >&2
        echo "$default"
        return 0
    fi

    if [[ -z "$val" || "$val" == "null" ]]; then
        echo "$default"
    else
        echo "$val"
    fi
    return 0
}

# =============================================================================
# yaml_get_list <file> <dotpath>
#   配列を1行1要素で標準出力する。
#   yq 必須。未インストール時は空出力 + stderr に警告。
# =============================================================================

yaml_get_list() {
    local file="$1"
    local dotpath="$2"

    if [[ "$_YQ_AVAILABLE" -eq 1 ]]; then
        yq -r "${dotpath}[]" "$file" 2>/dev/null || true
    else
        echo "[WARN] yaml_get_list: yq が必要です (dotpath: ${dotpath})" >&2
    fi
    return 0
}

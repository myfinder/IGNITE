# shellcheck shell=bash
# lib/config_validator.sh - 設定ファイルバリデーションライブラリ
[[ -n "${__LIB_CONFIG_VALIDATOR_LOADED:-}" ]] && return; __LIB_CONFIG_VALIDATOR_LOADED=1

# =============================================================================
# yq ガード
# =============================================================================

if ! command -v yq &>/dev/null; then
    echo "[WARN] config_validator: yq が未インストールのため検証をスキップします" >&2
    validate_system_yaml() { return 0; }
    validate_watcher_yaml() { return 0; }
    validate_github_app_yaml() { return 0; }
    validate_all_configs() { return 0; }
    return 0
fi

# =============================================================================
# エラー蓄積パターン
# =============================================================================

_VALIDATION_ERRORS=()
_VALIDATION_WARNINGS=()

# validation_error <file> <path> <msg> [fix_suggestion]
validation_error() {
    local file="$1" path="$2" msg="$3" fix="${4:-}"
    local entry
    entry="[ERROR] $(basename "$file"): ${path} - ${msg}"
    [[ -n "$fix" ]] && entry+=" (Fix: ${fix})"
    _VALIDATION_ERRORS+=("$entry")
}

# validation_warn <file> <path> <msg> [fix_suggestion]
validation_warn() {
    local file="$1" path="$2" msg="$3" fix="${4:-}"
    local entry
    entry="[WARN] $(basename "$file"): ${path} - ${msg}"
    [[ -n "$fix" ]] && entry+=" (Fix: ${fix})"
    _VALIDATION_WARNINGS+=("$entry")
}

# validation_report → 0=OK, 1=ERROR, 2=FILE_NOT_FOUND(内部用)
validation_report() {
    local has_error=0

    if [[ ${#_VALIDATION_WARNINGS[@]} -gt 0 ]]; then
        for w in "${_VALIDATION_WARNINGS[@]}"; do
            echo "$w" >&2
        done
    fi

    if [[ ${#_VALIDATION_ERRORS[@]} -gt 0 ]]; then
        for e in "${_VALIDATION_ERRORS[@]}"; do
            echo "$e" >&2
        done
        has_error=1
    fi

    local total=$(( ${#_VALIDATION_ERRORS[@]} + ${#_VALIDATION_WARNINGS[@]} ))
    if [[ $total -eq 0 ]]; then
        echo "[OK] 全設定ファイルの検証に成功しました" >&2
    else
        echo "[INFO] エラー: ${#_VALIDATION_ERRORS[@]} 件, 警告: ${#_VALIDATION_WARNINGS[@]} 件" >&2
    fi

    # リセット
    _VALIDATION_ERRORS=()
    _VALIDATION_WARNINGS=()

    return "$has_error"
}

# =============================================================================
# 汎用検証関数 6種
# =============================================================================

# validate_required <file> <yq_path>
validate_required() {
    local file="$1" path="$2"
    local val
    val=$(yq -r "${path} // \"__NULL__\"" "$file" 2>/dev/null)
    if [[ "$val" == "__NULL__" || "$val" == "null" || -z "$val" ]]; then
        validation_error "$file" "$path" "必須フィールドが未設定です" "値を設定してください"
        return 1
    fi
    return 0
}

# validate_type <file> <yq_path> <expected_type>
#   expected_type: str, int, bool, seq, map (または !!str, !!int 等の yq 形式)
validate_type() {
    local file="$1" path="$2" expected="$3"
    local actual
    actual=$(yq -r "${path} | type" "$file" 2>/dev/null)
    [[ -z "$actual" || "$actual" == "null" || "$actual" == "!!null" ]] && return 0  # 未設定は validate_required で捕捉

    # expected を正規化（ユーザ指定 → 内部表現）
    local mapped=""
    case "$expected" in
        str|string|'!!str')    mapped="string" ;;
        int|number|'!!int')    mapped="number" ;;
        float|'!!float')       mapped="number" ;;
        bool|boolean|'!!bool') mapped="boolean" ;;
        seq|array|'!!seq')     mapped="array" ;;
        map|object|'!!map')    mapped="object" ;;
        *)                     mapped="$expected" ;;
    esac

    # actual を正規化（yq 出力 !!str/!!int 等 → 内部表現）
    local actual_normalized=""
    case "$actual" in
        '!!str'|string)    actual_normalized="string" ;;
        '!!int'|number)    actual_normalized="number" ;;
        '!!float')         actual_normalized="number" ;;
        '!!bool'|boolean)  actual_normalized="boolean" ;;
        '!!seq'|array)     actual_normalized="array" ;;
        '!!map'|object)    actual_normalized="object" ;;
        '!!null')          return 0 ;;
        *)                 actual_normalized="$actual" ;;
    esac

    if [[ "$actual_normalized" != "$mapped" ]]; then
        validation_error "$file" "$path" "型が不正です: 期待=${mapped}, 実際=${actual_normalized}" "正しい型の値を設定してください"
        return 1
    fi
    return 0
}

# validate_range <file> <yq_path> <min> <max>
validate_range() {
    local file="$1" path="$2" min="$3" max="$4"
    local val
    val=$(yq -r "${path} // \"\"" "$file" 2>/dev/null)
    [[ -z "$val" || "$val" == "null" ]] && return 0

    if ! [[ "$val" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
        validation_error "$file" "$path" "数値ではありません: ${val}"
        return 1
    fi

    if (( $(echo "$val < $min" | bc -l 2>/dev/null || echo 0) )); then
        validation_error "$file" "$path" "値が範囲外です: ${val} < ${min}" "最小値 ${min} 以上を設定してください"
        return 1
    fi
    if (( $(echo "$val > $max" | bc -l 2>/dev/null || echo 0) )); then
        validation_error "$file" "$path" "値が範囲外です: ${val} > ${max}" "最大値 ${max} 以下を設定してください"
        return 1
    fi
    return 0
}

# validate_enum <file> <yq_path> <values...>
validate_enum() {
    local file="$1" path="$2"
    shift 2
    local val
    val=$(yq -r "${path} // \"\"" "$file" 2>/dev/null)
    [[ -z "$val" || "$val" == "null" ]] && return 0

    local allowed
    for allowed in "$@"; do
        [[ "$val" == "$allowed" ]] && return 0
    done

    validation_error "$file" "$path" "許可されていない値です: ${val}" "許可値: $*"
    return 1
}

# validate_file_exists <file> <yq_path>
validate_file_exists() {
    local file="$1" path="$2"
    local val
    val=$(yq -r "${path} // \"\"" "$file" 2>/dev/null)
    [[ -z "$val" || "$val" == "null" ]] && return 0

    # ~ を展開、相対パスは設定ファイルのディレクトリ基準で解決
    local expanded="${val/#\~/$HOME}"
    if [[ "$expanded" != /* ]]; then
        expanded="$(dirname "$file")/$expanded"
    fi
    if [[ ! -f "$expanded" ]]; then
        validation_warn "$file" "$path" "ファイルが見つかりません: ${val}" "パスを確認してください"
        return 1
    fi
    if [[ ! -r "$expanded" ]]; then
        validation_warn "$file" "$path" "読み取り権限がありません: ${val}" "chmod +r ${val}"
        return 1
    fi
    return 0
}

# validate_array_min <file> <yq_path> <min_count>
validate_array_min() {
    local file="$1" path="$2" min_count="$3"
    local count
    count=$(yq -r "${path} | length" "$file" 2>/dev/null)
    [[ -z "$count" || "$count" == "null" ]] && count=0

    if [[ "$count" -lt "$min_count" ]]; then
        validation_error "$file" "$path" "要素数が不足: ${count} < ${min_count}" "最低 ${min_count} 個の要素を設定してください"
        return 1
    fi
    return 0
}

# =============================================================================
# ファイル共通ガード
# =============================================================================

# _validate_file_guard <file> → 0=続行, 1=スキップ(正常), 2=エラー
_validate_file_guard() {
    local file="$1"

    if [[ ! -e "$file" ]]; then
        return 1  # ファイル不在 → スキップ
    fi
    if [[ ! -r "$file" ]]; then
        validation_error "$file" "(file)" "読み取り権限がありません" "chmod +r $(basename "$file")"
        return 2
    fi
    if [[ ! -s "$file" ]]; then
        validation_warn "$file" "(file)" "ファイルが空です"
        return 1
    fi
    return 0
}

# =============================================================================
# スキーマ関数: validate_system_yaml
# =============================================================================

validate_system_yaml() {
    local file="$1"
    _validate_file_guard "$file" || return 0

    echo "[INFO] 検証中: $(basename "$file")" >&2

    # delays セクション
    local delay_keys=(
        leader_startup leader_init
        agent_stabilize agent_retry_wait process_cleanup
        server_ready
    )
    for key in "${delay_keys[@]}"; do
        validate_required "$file" ".delays.${key}"
        validate_type     "$file" ".delays.${key}" int
        validate_range    "$file" ".delays.${key}" 0 120
    done

    # defaults セクション (3)
    validate_required "$file" ".defaults.message_priority"
    validate_enum     "$file" ".defaults.message_priority" normal high low
    validate_required "$file" ".defaults.task_timeout"
    validate_type     "$file" ".defaults.task_timeout" int
    validate_range    "$file" ".defaults.task_timeout" 30 3600
    validate_required "$file" ".defaults.worker_count"
    validate_type     "$file" ".defaults.worker_count" int
    validate_range    "$file" ".defaults.worker_count" 1 32
}

# =============================================================================
# スキーマ関数: validate_watcher_yaml
# =============================================================================

validate_watcher_yaml() {
    local file="$1"
    _validate_file_guard "$file" || return 0

    echo "[INFO] 検証中: $(basename "$file")" >&2

    # watcher セクション
    validate_required   "$file" ".watcher.repositories"
    validate_type       "$file" ".watcher.repositories" seq
    validate_array_min  "$file" ".watcher.repositories" 1
    validate_required   "$file" ".watcher.interval"
    validate_type       "$file" ".watcher.interval" int
    validate_range      "$file" ".watcher.interval" 10 3600

    # events
    validate_type "$file" ".watcher.events" map
    local event_keys=(issues issue_comments pull_requests pr_comments)
    for key in "${event_keys[@]}"; do
        validate_type "$file" ".watcher.events.${key}" bool
    done

    validate_type "$file" ".watcher.ignore_bot" bool

    # access_control
    validate_required "$file" ".access_control.enabled"
    validate_type     "$file" ".access_control.enabled" bool

    # enabled=true なら allowed_users 必須
    local ac_enabled
    ac_enabled=$(yq -r '.access_control.enabled // false' "$file" 2>/dev/null)
    if [[ "$ac_enabled" == "true" ]]; then
        validate_required  "$file" ".access_control.allowed_users"
        validate_type      "$file" ".access_control.allowed_users" seq
        validate_array_min "$file" ".access_control.allowed_users" 1
    fi

    # logging
    validate_enum "$file" ".logging.level" debug info warn error
}

# =============================================================================
# スキーマ関数: validate_github_app_yaml
# =============================================================================

validate_github_app_yaml() {
    local file="$1"
    _validate_file_guard "$file" || return 0

    echo "[INFO] 検証中: $(basename "$file")" >&2

    validate_required    "$file" ".github_app.app_id"
    validate_type        "$file" ".github_app.app_id" str
    validate_required    "$file" ".github_app.private_key_path"
    validate_file_exists "$file" ".github_app.private_key_path"
    validate_required    "$file" ".github_app.app_name"
    validate_type        "$file" ".github_app.app_name" str
}

# =============================================================================
# スキーマ関数: validate_workspace_config
# =============================================================================

# validate_workspace_config <workspace_dir>
# ワークスペース .ignite/ の構成を検証
# - github-app.yaml がワークスペースに存在する場合は警告
# - 設定ファイルの妥当性チェック
validate_workspace_config() {
    local workspace_dir="$1"
    local ignite_dir="${workspace_dir}/.ignite"

    [[ -d "$ignite_dir" ]] || return 0  # .ignite/ なしは正常

    echo "[INFO] 検証中: ワークスペース設定 ($ignite_dir)" >&2

    # credentials がワークスペースに存在する場合は警告
    if [[ -f "$ignite_dir/github-app.yaml" ]]; then
        validation_warn "$ignite_dir/github-app.yaml" "(file)" \
            "credentials がワークスペースに存在します。.gitignoreで除外済みですが、環境変数での管理も推奨します" \
            "rm $ignite_dir/github-app.yaml"
    fi

    # .gitignore の存在チェック
    if [[ ! -f "$ignite_dir/.gitignore" ]]; then
        validation_warn "$ignite_dir" ".gitignore" \
            ".gitignore がありません。ignite init で生成されます"
    fi

    # ワークスペース内の設定ファイルを個別検証
    [[ -f "$ignite_dir/system.yaml" ]] && validate_system_yaml "$ignite_dir/system.yaml" || true
    [[ -f "$ignite_dir/github-watcher.yaml" ]] && validate_watcher_yaml "$ignite_dir/github-watcher.yaml" || true

    return 0
}

# =============================================================================
# validate_all_configs <config_dir> <xdg_config_dir>
# =============================================================================

validate_all_configs() {
    local config_dir="$1"
    local xdg_config_dir="$2"

    # リセット
    _VALIDATION_ERRORS=()
    _VALIDATION_WARNINGS=()

    # config_dir の system.yaml は必須
    if [[ -d "$config_dir" ]]; then
        validate_system_yaml "${config_dir}/system.yaml" || true
    else
        validation_error "$config_dir" "(dir)" "設定ディレクトリが見つかりません"
    fi

    # XDG 設定はオプショナル（不在時スキップ）
    if [[ -d "$xdg_config_dir" ]]; then
        validate_watcher_yaml    "${xdg_config_dir}/github-watcher.yaml" || true
        validate_github_app_yaml "${xdg_config_dir}/github-app.yaml" || true
    fi

    validation_report
}

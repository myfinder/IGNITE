# shellcheck shell=bash
# lib/isolation.sh - コンテナ隔離 (Podman rootless) モジュール
# 1ワークスペース = 1常駐コンテナ。全エージェントが同一コンテナ内で動作。
[[ -n "${__LIB_ISOLATION_LOADED:-}" ]] && return; __LIB_ISOLATION_LOADED=1

# 内部変数（テストでオーバーライド可能）
_ISOLATION_RUNTIME="${_ISOLATION_RUNTIME:-podman}"

# =============================================================================
# _isolation_get_network_option - Podman バージョンに応じたネットワークオプションを返す
# Podman 4.0+ では pasta、それ以前は slirp4netns にフォールバック
# =============================================================================
_isolation_get_network_option() {
    # Podman 5.0+ は pasta をネイティブサポート
    # Podman 4.x は pasta 未サポートの場合あり（Debian bookworm 等）
    local version major
    version=$("$_ISOLATION_RUNTIME" --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+' | head -1)
    major="${version%%.*}"

    if [[ "${major:-0}" -ge 5 ]] && command -v pasta &>/dev/null; then
        echo "pasta"
    elif command -v slirp4netns &>/dev/null; then
        echo "slirp4netns"
    else
        echo "bridge"
    fi
}

# =============================================================================
# isolation_is_enabled - コンテナ隔離が有効か判定
# 注意: この関数は get_config() に依存するため、cli_load_config() 後に呼ぶこと。
# 呼び出し側は `isolation_is_enabled 2>/dev/null` パターンで使用する。
# cli_load_config 前に呼ばれた場合は get_config 未定義で false 扱いになる（安全側倒し）。
# デフォルト false（opt-in）: 明示的に enabled: true を設定した場合のみ有効。
# =============================================================================
isolation_is_enabled() {
    local enabled
    enabled="$(get_config isolation enabled 'false')" || return 1
    [[ "$enabled" == "true" ]]
}

# =============================================================================
# isolation_check_prerequisites - podman / rootless / OS チェック
# =============================================================================
isolation_check_prerequisites() {
    # Linux のみ対応
    if [[ "$(uname)" == "Darwin" ]]; then
        print_error "コンテナ隔離は Linux のみ対応しています（macOS 非対応）"
        print_info "isolation.enabled: false を設定して無効化できます"
        return 1
    fi

    # podman コマンド確認
    if ! command -v "$_ISOLATION_RUNTIME" &>/dev/null; then
        print_error "${_ISOLATION_RUNTIME} がインストールされていません"
        echo ""
        print_info "インストール手順:"
        echo "  Ubuntu/Debian: sudo apt install podman"
        echo "  Fedora/RHEL:   sudo dnf install podman"
        echo "  Arch:          sudo pacman -S podman"
        echo ""
        print_info "コンテナ隔離を無効にする場合:"
        echo "  config/system.yaml の isolation.enabled を false に設定"
        return 1
    fi

    # rootless 確認（podman info で rootless かチェック）
    if ! "$_ISOLATION_RUNTIME" info --format '{{.Host.Security.Rootless}}' 2>/dev/null | grep -q true; then
        log_warn "Podman rootless モードが検出されませんでした。rootless モードを推奨します"
    fi

    return 0
}

# =============================================================================
# isolation_get_container_name - ワークスペースパスから一意なコンテナ名を生成
# =============================================================================
isolation_get_container_name() {
    local workspace_dir="$1"
    # パスを正規化（末尾スラッシュ等でハッシュが変わるのを防止）
    workspace_dir="$(realpath -m "$workspace_dir" 2>/dev/null || echo "$workspace_dir")"
    local hash
    hash="$(echo "$workspace_dir" | md5sum | cut -c1-8)"
    echo "ignite-ws-${hash}"
}

# =============================================================================
# _isolation_copy_claude_config - ~/.claude/ と ~/.claude.json をコンテナ内にコピー
# バインドマウントの代わりにコピーすることで、複数コンテナ間の書き込み競合を防止
# =============================================================================
_isolation_copy_claude_config() {
    local container_name="$1"

    # ~/.claude/ ディレクトリをコピー
    if [[ -d "${HOME}/.claude" ]]; then
        "$_ISOLATION_RUNTIME" cp "${HOME}/.claude" "${container_name}:${HOME}/.claude" 2>/dev/null || {
            log_warn "Failed to copy ~/.claude/ into container"
        }
    fi

    # ~/.claude.json ファイルをコピー
    if [[ -f "${HOME}/.claude.json" ]]; then
        "$_ISOLATION_RUNTIME" cp "${HOME}/.claude.json" "${container_name}:${HOME}/.claude.json" 2>/dev/null || {
            log_warn "Failed to copy ~/.claude.json into container"
        }
    fi
}

# =============================================================================
# isolation_start_container - コンテナ起動
# =============================================================================
isolation_start_container() {
    local workspace_dir="$1"
    local runtime_dir="$2"
    local container_name
    container_name="$(isolation_get_container_name "$workspace_dir")"

    # 既存コンテナが動いていたらスキップ
    if "$_ISOLATION_RUNTIME" inspect --format '{{.State.Running}}' "$container_name" 2>/dev/null | grep -q true; then
        log_info "Container $container_name already running"
        echo "$container_name" > "${runtime_dir}/state/container_name"
        return 0
    fi

    # 停止済みコンテナがあれば削除
    "$_ISOLATION_RUNTIME" rm -f "$container_name" 2>/dev/null || true

    local memory cpus image
    memory="$(get_config isolation resource_memory '8g')"
    cpus="$(get_config isolation resource_cpus '4')"
    image="$(get_config isolation image 'ignite-agent:latest')"

    mkdir -p "${runtime_dir}/state"

    local env_file_args=()
    if [[ -f "${runtime_dir}/.env" ]]; then
        env_file_args=(--env-file "${runtime_dir}/.env")
    fi

    # マウント引数を動的構築（存在するディレクトリのみ）
    local mount_args=(
        -v "${workspace_dir}:${workspace_dir}:rw"
        -v "${runtime_dir}:${runtime_dir}:rw"
    )
    # オプショナルマウント: 存在する場合のみ追加
    local _opt_mounts_ro=(
        "${IGNITE_SCRIPTS_DIR}:${IGNITE_SCRIPTS_DIR}"
        "${HOME}/.anthropic:${HOME}/.anthropic"
        "${HOME}/.config/opencode:${HOME}/.config/opencode"
    )
    # 注意: ~/.claude/ と ~/.claude.json はバインドマウントしない（Issue #354）
    # 複数コンテナが同一ファイルを同時に読み書きすると JSON 破損が発生するため、
    # コンテナ起動後に podman cp でコピーする（書き込み競合の構造的解消）
    for _mount in "${_opt_mounts_ro[@]}"; do
        local _src="${_mount%%:*}"
        [[ -d "$_src" ]] && mount_args+=(-v "${_mount}:ro")
    done

    if ! "$_ISOLATION_RUNTIME" run -d \
        --name "$container_name" \
        --userns=keep-id \
        --security-opt no-new-privileges \
        --network="$(_isolation_get_network_option)" \
        --memory "$memory" \
        --cpus "$cpus" \
        "${env_file_args[@]}" \
        -e HOME="$HOME" \
        -e WORKSPACE_DIR="$workspace_dir" \
        -e IGNITE_RUNTIME_DIR="$runtime_dir" \
        "${mount_args[@]}" \
        -w "$workspace_dir" \
        "$image" \
        sleep infinity; then
        log_error "Container start failed: $container_name"
        return 1
    fi

    echo "$container_name" > "${runtime_dir}/state/container_name"

    # ~/.claude/ と ~/.claude.json をコンテナ内にコピー（バインドマウントの代替）
    # 各コンテナが独立したコピーを持つことで、書き込み競合を構造的に回避する
    _isolation_copy_claude_config "$container_name"

    log_info "Isolation container started: $container_name"
}

# =============================================================================
# isolation_exec - コンテナ内でコマンド実行
# =============================================================================
isolation_exec() {
    local runtime_dir="${IGNITE_RUNTIME_DIR:-}"
    local container_name
    container_name="$(cat "${runtime_dir}/state/container_name" 2>/dev/null)" || {
        log_error "Container name not found in state"
        return 1
    }
    "$_ISOLATION_RUNTIME" exec "$container_name" "$@"
}

# =============================================================================
# isolation_exec_with_env - 環境変数付きでコンテナ内コマンド実行
# env_args は -e KEY=VALUE の配列（空配列でも可: -- の前に何もなければスキップ）
# Usage: isolation_exec_with_env [-e K=V ...] -- command args...
# =============================================================================
isolation_exec_with_env() {
    local runtime_dir="${IGNITE_RUNTIME_DIR:-}"
    local container_name
    container_name="$(cat "${runtime_dir}/state/container_name" 2>/dev/null)" || {
        log_error "Container name not found in state"
        return 1
    }

    local env_args=()
    while [[ $# -gt 0 ]] && [[ "$1" != "--" ]]; do
        env_args+=("$1")
        shift
    done
    [[ "$1" == "--" ]] && shift

    "$_ISOLATION_RUNTIME" exec "${env_args[@]}" "$container_name" "$@"
}

# =============================================================================
# isolation_stop_container - コンテナ停止・削除
# 引数: runtime_dir のみ（workspace_dir は不要。start と非対称だが意図的設計）
# =============================================================================
isolation_stop_container() {
    local runtime_dir="${1:-$IGNITE_RUNTIME_DIR}"
    local stop_timeout="${2:-30}"
    local container_name
    container_name="$(cat "${runtime_dir}/state/container_name" 2>/dev/null)" || return 0
    "$_ISOLATION_RUNTIME" stop --time "$stop_timeout" "$container_name" 2>/dev/null || true
    "$_ISOLATION_RUNTIME" rm -f "$container_name" 2>/dev/null || true
    rm -f "${runtime_dir}/state/container_name"
    log_info "Isolation container stopped: $container_name"
}

# =============================================================================
# isolation_write_message_file - メッセージを一時ファイルに書き出しパスを返す
# =============================================================================
isolation_write_message_file() {
    local message="$1"
    local runtime_dir="${IGNITE_RUNTIME_DIR:-}"
    local tmp_dir="${runtime_dir}/tmp"
    mkdir -p "$tmp_dir"
    local msg_file
    msg_file="$(mktemp "${tmp_dir}/.msg_XXXXXXXXXX")"
    printf '%s' "$message" > "$msg_file"
    echo "$msg_file"
}

# =============================================================================
# isolation_is_container_running - コンテナ生存チェック
# =============================================================================
isolation_is_container_running() {
    local runtime_dir="${IGNITE_RUNTIME_DIR:-}"
    local container_name
    container_name="$(cat "${runtime_dir}/state/container_name" 2>/dev/null)" || return 1
    "$_ISOLATION_RUNTIME" inspect --format '{{.State.Running}}' "$container_name" 2>/dev/null | grep -q true
}

# =============================================================================
# isolation_restart_container - コンテナ再起動（stop + rm + start）
# =============================================================================
isolation_restart_container() {
    local workspace_dir="$1"
    local runtime_dir="$2"
    log_warn "Isolation container restart initiated"
    isolation_stop_container "$runtime_dir"
    isolation_start_container "$workspace_dir" "$runtime_dir"
}

# =============================================================================
# isolation_get_container_info - コンテナ情報取得（status 表示用）
# 出力: name|status|image|started_at
# =============================================================================
isolation_get_container_info() {
    local runtime_dir="${IGNITE_RUNTIME_DIR:-}"
    local container_name
    container_name="$(cat "${runtime_dir}/state/container_name" 2>/dev/null)" || {
        echo "none"
        return 1
    }
    "$_ISOLATION_RUNTIME" inspect --format \
        '{{.Name}}|{{.State.Status}}|{{.Config.Image}}|{{.State.StartedAt}}' \
        "$container_name" 2>/dev/null || echo "${container_name}|unknown|unknown|unknown"
}

# shellcheck shell=bash
# lib/cmd_container.sh - コンテナ関連コマンド（build-image 等）
[[ -n "${__LIB_CMD_CONTAINER_LOADED:-}" ]] && return; __LIB_CMD_CONTAINER_LOADED=1

# =============================================================================
# cmd_build_image - エージェント用コンテナイメージをビルド
# =============================================================================
cmd_build_image() {
    local cli_provider
    cli_provider="$(get_config cli provider 'claude')"
    local version="$VERSION"

    # Containerfile の検索順: IGNITE_DATA_DIR → スクリプト相対パス
    local containerfile=""
    if [[ -f "${IGNITE_DATA_DIR}/containers/Containerfile.agent" ]]; then
        containerfile="${IGNITE_DATA_DIR}/containers/Containerfile.agent"
    elif [[ -f "${SCRIPT_DIR}/../containers/Containerfile.agent" ]]; then
        containerfile="${SCRIPT_DIR}/../containers/Containerfile.agent"
    else
        print_error "Containerfile.agent が見つかりません"
        return 1
    fi

    local runtime="${_ISOLATION_RUNTIME:-podman}"

    print_header "コンテナイメージビルド"
    print_info "Containerfile: $containerfile"
    print_info "CLI Provider: $cli_provider"
    print_info "バージョン: v${version}"
    echo ""

    "$runtime" build \
        --build-arg "CLI_PROVIDER=$cli_provider" \
        -t "ignite-agent:v${version}" \
        -t "ignite-agent:latest" \
        -f "$containerfile" \
        "$(dirname "$containerfile")"

    local rc=$?
    if [[ $rc -eq 0 ]]; then
        print_success "イメージビルド完了: ignite-agent:v${version} / ignite-agent:latest"
    else
        print_error "イメージビルドに失敗しました (rc=$rc)"
        return 1
    fi
}

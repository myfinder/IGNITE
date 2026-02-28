# shellcheck shell=bash
# lib/cmd_container.sh - コンテナ関連コマンド（build-image 等）
[[ -n "${__LIB_CMD_CONTAINER_LOADED:-}" ]] && return; __LIB_CMD_CONTAINER_LOADED=1

# =============================================================================
# cmd_build_image - エージェント用コンテナイメージをビルド
# Usage: ignite build-image -w <workspace_dir>
# cmd_start 経由の自動ビルドでは _BUILD_IMAGE_INTERNAL=1 で呼ばれる（-w 不要）。
# =============================================================================
cmd_build_image() {
    local _internal="${_BUILD_IMAGE_INTERNAL:-}"

    # オプション解析（外部呼び出し時のみ）
    if [[ -z "$_internal" ]]; then
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -w|--workspace)
                    WORKSPACE_DIR="$2"
                    if [[ ! "$WORKSPACE_DIR" = /* ]]; then
                        WORKSPACE_DIR="$(pwd)/$WORKSPACE_DIR"
                    fi
                    shift 2
                    ;;
                -h|--help)
                    echo "Usage: ignite build-image -w <workspace_dir>"
                    echo ""
                    echo "ワークスペースの設定に基づいてエージェント用コンテナイメージをビルドします。"
                    echo ""
                    echo "Options:"
                    echo "  -w, --workspace <dir>  ワークスペースディレクトリ（必須）"
                    echo "  -h, --help             このヘルプを表示"
                    return 0
                    ;;
                *)
                    print_error "不正なオプション: $1"
                    echo "Usage: ignite build-image -w <workspace_dir>"
                    return 1
                    ;;
            esac
        done

        # -w 必須チェック
        if [[ -z "${WORKSPACE_DIR:-}" ]]; then
            print_error "ワークスペースの指定が必要です: ignite build-image -w <workspace_dir>"
            return 1
        fi
        if [[ ! -d "${WORKSPACE_DIR}/.ignite" ]]; then
            print_error "ワークスペースが初期化されていません: ${WORKSPACE_DIR}"
            print_info "先に ignite init -w ${WORKSPACE_DIR} を実行してください"
            return 1
        fi

        setup_workspace_config "$WORKSPACE_DIR"
        source "${LIB_DIR}/cli_provider.sh"
        cli_load_config
    fi

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

    # system.yaml の isolation.image からイメージ名を取得（:tag 部分を除去）
    local configured_image
    configured_image="$(get_config isolation image 'ignite-agent:latest')"
    local image_name="${configured_image%%:*}"

    print_header "コンテナイメージビルド"
    print_info "Containerfile: $containerfile"
    print_info "CLI Provider: $cli_provider"
    print_info "イメージ名: $image_name"
    print_info "Workspace: ${WORKSPACE_DIR:-N/A}"
    print_info "バージョン: v${version}"
    echo ""

    "$runtime" build \
        --build-arg "CLI_PROVIDER=$cli_provider" \
        -t "${image_name}:v${version}" \
        -t "${image_name}:latest" \
        -f "$containerfile" \
        "$(dirname "$containerfile")"

    local rc=$?
    if [[ $rc -eq 0 ]]; then
        print_success "イメージビルド完了: ${image_name}:v${version} / ${image_name}:latest"
    else
        print_error "イメージビルドに失敗しました (rc=$rc)"
        return 1
    fi
}

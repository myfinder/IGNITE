# shellcheck shell=bash
# lib/cmd_container.sh - コンテナ関連コマンド（build-image 等）
[[ -n "${__LIB_CMD_CONTAINER_LOADED:-}" ]] && return; __LIB_CMD_CONTAINER_LOADED=1

# =============================================================================
# _resolve_containerfile - Containerfile パスを検索順序に従って解決
# 引数: $1 = CLI -f で渡されたパス（省略可能）
# stdout: 解決されたパス
# return: 0=カスタム, 1=デフォルト, 2=見つからない
# =============================================================================
_resolve_containerfile() {
    local cli_path="${1:-}"

    # 1. CLI -f 直接指定（最優先）
    if [[ -n "$cli_path" ]]; then
        if [[ ! "$cli_path" = /* ]]; then
            cli_path="${WORKSPACE_DIR:-$(pwd)}/$cli_path"
        fi
        if [[ -f "$cli_path" ]]; then
            echo "$cli_path"
            return 0
        fi
        return 2
    fi

    # 2. system.yaml の isolation.containerfile
    local configured
    configured="$(get_config isolation containerfile '')"
    if [[ -n "$configured" ]]; then
        if [[ ! "$configured" = /* ]]; then
            configured="${WORKSPACE_DIR:-$(pwd)}/$configured"
        fi
        if [[ -f "$configured" ]]; then
            echo "$configured"
            return 0
        fi
        return 2
    fi

    # 3. .ignite/containers/Containerfile.agent（ワークスペースローカル）
    if [[ -f "${IGNITE_CONFIG_DIR}/containers/Containerfile.agent" ]]; then
        echo "${IGNITE_CONFIG_DIR}/containers/Containerfile.agent"
        return 0
    fi

    # 4. ${IGNITE_DATA_DIR}/containers/Containerfile.agent（インストール先）
    if [[ -f "${IGNITE_DATA_DIR}/containers/Containerfile.agent" ]]; then
        echo "${IGNITE_DATA_DIR}/containers/Containerfile.agent"
        return 1
    fi

    # 5. ${SCRIPT_DIR}/../containers/Containerfile.agent（開発時）
    if [[ -f "${SCRIPT_DIR}/../containers/Containerfile.agent" ]]; then
        echo "${SCRIPT_DIR}/../containers/Containerfile.agent"
        return 1
    fi

    return 2
}

# =============================================================================
# cmd_build_image - エージェント用コンテナイメージをビルド
# Usage: ignite build-image -w <workspace_dir> [-f <containerfile>]
# cmd_start 経由の自動ビルドでは _BUILD_IMAGE_INTERNAL=1 で呼ばれる（-w 不要）。
# =============================================================================
cmd_build_image() {
    local _internal="${_BUILD_IMAGE_INTERNAL:-}"
    local _cli_containerfile=""

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
                -f|--containerfile)
                    _cli_containerfile="$2"
                    shift 2
                    ;;
                -h|--help)
                    echo "Usage: ignite build-image -w <workspace_dir> [-f <containerfile>]"
                    echo ""
                    echo "ワークスペースの設定に基づいてエージェント用コンテナイメージをビルドします。"
                    echo ""
                    echo "Options:"
                    echo "  -w, --workspace <dir>       ワークスペースディレクトリ（必須）"
                    echo "  -f, --containerfile <path>  カスタム Containerfile パス"
                    echo "  -h, --help                  このヘルプを表示"
                    return 0
                    ;;
                *)
                    print_error "不正なオプション: $1"
                    echo "Usage: ignite build-image -w <workspace_dir> [-f <containerfile>]"
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

    # Containerfile を検索順序に従って解決
    local containerfile=""
    local _resolve_rc=0
    containerfile="$(_resolve_containerfile "$_cli_containerfile")" || _resolve_rc=$?

    if [[ $_resolve_rc -eq 2 ]]; then
        print_error "Containerfile.agent が見つかりません"
        return 1
    fi

    local is_custom=false
    [[ $_resolve_rc -eq 0 ]] && is_custom=true

    local runtime="${_ISOLATION_RUNTIME:-podman}"

    # system.yaml の isolation.image からイメージ名を取得（:tag 部分を除去）
    local configured_image
    configured_image="$(get_config isolation image 'ignite-agent:latest')"
    local image_name="${configured_image%%:*}"
    local configured_tag="${configured_image#*:}"

    # ビルドコンテキスト: カスタム→ワークスペースルート、デフォルト→Containerfile のディレクトリ
    local build_context
    if [[ "$is_custom" == true ]]; then
        build_context="${WORKSPACE_DIR}"
    else
        build_context="$(dirname "$containerfile")"
    fi

    print_header "コンテナイメージビルド"
    print_info "Containerfile: $containerfile"
    [[ "$is_custom" == true ]] && print_info "  (カスタム)"
    print_info "CLI Provider: $cli_provider"
    print_info "イメージ名: $image_name"
    print_info "ビルドコンテキスト: $build_context"
    print_info "Workspace: ${WORKSPACE_DIR:-N/A}"
    print_info "バージョン: v${version}"
    echo ""

    # タグリスト: v${version} + latest + (設定タグが異なる場合)
    local -a tag_args=( -t "${image_name}:v${version}" -t "${image_name}:latest" )
    if [[ -n "$configured_tag" ]] && [[ "$configured_tag" != "latest" ]] && [[ "$configured_tag" != "$configured_image" ]]; then
        tag_args+=( -t "${image_name}:${configured_tag}" )
    fi

    "$runtime" build \
        --build-arg "CLI_PROVIDER=$cli_provider" \
        "${tag_args[@]}" \
        -f "$containerfile" \
        "$build_context"

    local rc=$?
    if [[ $rc -eq 0 ]]; then
        local tag_msg="${image_name}:v${version} / ${image_name}:latest"
        if [[ -n "$configured_tag" ]] && [[ "$configured_tag" != "latest" ]] && [[ "$configured_tag" != "$configured_image" ]]; then
            tag_msg="${tag_msg} / ${image_name}:${configured_tag}"
        fi
        print_success "イメージビルド完了: ${tag_msg}"
    else
        print_error "イメージビルドに失敗しました (rc=$rc)"
        return 1
    fi
}

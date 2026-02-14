# shellcheck shell=bash
# lib/cmd_service.sh - serviceコマンド（systemd統合）
#
# systemd ユーザーサービスとして IGNITE を管理するためのコマンド群。
# テンプレートユニット ignite@.service を使用して複数ワークスペースの
# 独立管理をサポートする。

[[ -n "${__LIB_CMD_SERVICE_LOADED:-}" ]] && return; __LIB_CMD_SERVICE_LOADED=1

# =============================================================================
# systemd 前提チェック
# =============================================================================

_check_systemctl() {
    if ! command -v systemctl &>/dev/null; then
        print_error "systemctl が見つかりません。このシステムは systemd を使用していない可能性があります。"
        exit 1
    fi
}

# =============================================================================
# service コマンド（メインディスパッチ）
# =============================================================================

cmd_service() {
    local action="${1:-}"
    shift 2>/dev/null || true

    case "$action" in
        install)    _service_install "$@" ;;
        uninstall)  _service_uninstall "$@" ;;
        enable)     _service_enable "$@" ;;
        disable)    _service_disable "$@" ;;
        start)      _service_start "$@" ;;
        stop)       _service_stop "$@" ;;
        restart)    _service_restart "$@" ;;
        status)     _service_status "$@" ;;
        logs)       _service_logs "$@" ;;
        setup-env)  _service_setup_env "$@" ;;
        help|-h|--help) cmd_help service ;;
        *)
            cmd_help service
            if [[ -n "$action" ]]; then
                exit 1
            fi
            ;;
    esac
}

# =============================================================================
# install - ユニットファイルをインストール
# =============================================================================

_service_install() {
    _check_systemctl

    local unit_dir="$HOME/.config/systemd/user"
    local force=false

    # オプション解析
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes|-f|--force) force=true; shift ;;
            *) break ;;
        esac
    done

    # テンプレートユニットファイルの検索（複数パスフォールバック）
    local source_dir=""
    local search_dirs=(
        "${IGNITE_DATA_DIR:-}/templates/systemd"
        "${IGNITE_CONFIG_DIR:-}"
        "${PROJECT_ROOT:-}/templates/systemd"
    )

    for dir in "${search_dirs[@]}"; do
        if [[ -n "$dir" ]] && [[ -f "$dir/ignite@.service" ]]; then
            source_dir="$dir"
            break
        fi
    done

    if [[ -z "$source_dir" ]]; then
        print_error "テンプレートユニットファイル ignite@.service が見つかりません"
        print_info "以下のディレクトリを検索しました:"
        for dir in "${search_dirs[@]}"; do
            [[ -n "$dir" ]] && echo "  - $dir"
        done
        exit 1
    fi

    # 既存インストールの確認
    if [[ -f "$unit_dir/ignite@.service" ]]; then
        if diff -q "$source_dir/ignite@.service" "$unit_dir/ignite@.service" &>/dev/null; then
            print_success "ignite@.service は最新版です"
            return 0
        fi

        # 差分を表示
        print_warning "ignite@.service に変更があります:"
        echo ""
        diff -u "$unit_dir/ignite@.service" "$source_dir/ignite@.service" || true
        echo ""

        if [[ "$force" != true ]]; then
            if [[ -t 0 ]]; then
                read -p "ユニットファイルを更新しますか? (y/N): " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    print_warning "キャンセルしました"
                    return 0
                fi
            else
                print_error "非対話環境では --force オプションを使用してください"
                exit 1
            fi
        fi
    fi

    mkdir -p "$unit_dir"
    print_info "ユニットファイルをインストール中..."

    cp "$source_dir/ignite@.service" "$unit_dir/ignite@.service"
    print_success "ignite@.service をインストールしました"

    # watcher テンプレートがあればコピー
    if [[ -f "$source_dir/ignite-watcher@.service" ]]; then
        cp "$source_dir/ignite-watcher@.service" "$unit_dir/ignite-watcher@.service"
        print_success "ignite-watcher@.service をインストールしました"
    fi

    print_info "systemd daemon-reload を実行中..."
    systemctl --user daemon-reload
    print_success "daemon-reload 完了"

    echo ""
    print_header "インストール完了"
    echo ""
    echo "次のステップ:"
    echo -e "  1. 環境変数を設定: ${YELLOW}ignite service setup-env${NC}"
    echo -e "  2. サービスを有効化: ${YELLOW}ignite service enable <session>${NC}"
    echo -e "  3. linger 有効化: ${YELLOW}loginctl enable-linger $(whoami)${NC}"
}

# =============================================================================
# uninstall - ユニットファイルをアンインストール
# =============================================================================

_service_uninstall() {
    _check_systemctl

    local unit_dir="$HOME/.config/systemd/user"

    # 稼働中サービスの停止・無効化
    local active_units
    active_units=$(systemctl --user list-units --type=service --state=active --no-legend 2>/dev/null | awk '/ignite@/{print $1}' || true)

    if [[ -n "$active_units" ]]; then
        print_warning "稼働中のサービスを停止します..."
        while IFS= read -r unit; do
            systemctl --user stop "$unit" 2>/dev/null || true
            systemctl --user disable "$unit" 2>/dev/null || true
            print_success "停止・無効化: $unit"
        done <<< "$active_units"
    fi

    local removed=false
    for f in ignite@.service ignite-watcher@.service; do
        if [[ -f "$unit_dir/$f" ]]; then
            rm -f "$unit_dir/$f"
            print_success "$f を削除しました"
            removed=true
        fi
    done

    if [[ "$removed" == true ]]; then
        systemctl --user daemon-reload
        print_success "daemon-reload 完了"
    else
        print_warning "ユニットファイルが見つかりませんでした"
    fi

    print_success "アンインストール完了"
}

# =============================================================================
# enable / disable - サービスの有効化・無効化
# =============================================================================

_service_enable() {
    _check_systemctl

    local session="${1:-}"
    if [[ -z "$session" ]]; then
        print_error "セッション名を指定してください"
        echo "使用方法: ignite service enable <session>"
        exit 1
    fi

    systemctl --user enable "ignite@${session}.service"
    systemctl --user enable "ignite-watcher@${session}.service" 2>/dev/null || true
    print_success "ignite@${session} を有効化しました"

    # linger チェック
    if command -v loginctl &>/dev/null; then
        if ! loginctl show-user "$(whoami)" --property=Linger 2>/dev/null | grep -q "Linger=yes"; then
            echo ""
            print_warning "linger が有効になっていません。ログアウト後にサービスが停止します。"
            echo -e "有効化: ${YELLOW}loginctl enable-linger $(whoami)${NC}"
        fi
    fi
}

_service_disable() {
    _check_systemctl

    local session="${1:-}"
    if [[ -z "$session" ]]; then
        print_error "セッション名を指定してください"
        echo "使用方法: ignite service disable <session>"
        exit 1
    fi

    systemctl --user disable "ignite-watcher@${session}.service" 2>/dev/null || true
    systemctl --user disable "ignite@${session}.service"
    print_success "ignite@${session} を無効化しました"
}

# =============================================================================
# start / stop / restart - サービスの操作
# =============================================================================

_service_start() {
    _check_systemctl

    local session="${1:-}"
    if [[ -z "$session" ]]; then
        print_error "セッション名を指定してください"
        echo "使用方法: ignite service start <session>"
        exit 1
    fi

    systemctl --user start "ignite@${session}.service"
    print_success "ignite@${session} を開始しました"
}

_service_stop() {
    _check_systemctl

    local session="${1:-}"
    if [[ -z "$session" ]]; then
        print_error "セッション名を指定してください"
        echo "使用方法: ignite service stop <session>"
        exit 1
    fi

    systemctl --user stop "ignite@${session}.service"
    print_success "ignite@${session} を停止しました"
}

_service_restart() {
    _check_systemctl

    local session="${1:-}"
    if [[ -z "$session" ]]; then
        print_error "セッション名を指定してください"
        echo "使用方法: ignite service restart <session>"
        exit 1
    fi

    systemctl --user restart "ignite@${session}.service"
    print_success "ignite@${session} を再起動しました"
}

# =============================================================================
# status - サービス状態の表示
# =============================================================================

_service_status() {
    _check_systemctl

    local session="${1:-}"
    if [[ -z "$session" ]]; then
        # 全サービス一覧
        print_header "IGNITE サービス状態"
        echo ""
        systemctl --user list-units --type=service --no-legend 2>/dev/null | grep "ignite" || print_warning "稼働中の IGNITE サービスはありません"
        return
    fi

    systemctl --user status "ignite@${session}.service" 2>/dev/null || true
}

# =============================================================================
# logs - ジャーナルログの表示
# =============================================================================

_service_logs() {
    _check_systemctl

    local session="${1:-}"
    local follow=true

    # オプション解析
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-follow) follow=false; shift ;;
            *) session="$1"; shift ;;
        esac
    done

    if [[ -z "$session" ]]; then
        print_error "セッション名を指定してください"
        echo "使用方法: ignite service logs <session> [--no-follow]"
        exit 1
    fi

    if [[ "$follow" == true ]]; then
        journalctl --user-unit "ignite@${session}.service" --no-pager -f
    else
        journalctl --user-unit "ignite@${session}.service" --no-pager
    fi
}

# =============================================================================
# setup-env - 環境変数ファイルの対話的生成
# =============================================================================

_service_setup_env() {
    local env_file="${IGNITE_CONFIG_DIR}/env"
    local force=false

    # オプション解析
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes|-f|--force) force=true; shift ;;
            *) break ;;
        esac
    done

    mkdir -p "${IGNITE_CONFIG_DIR}"

    if [[ -f "$env_file" ]] && [[ "$force" != true ]]; then
        print_warning "既に $env_file が存在します"
        if [[ -t 0 ]]; then
            read -p "上書きしますか? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                print_warning "キャンセルしました"
                return 0
            fi
        else
            print_error "非対話環境では --force オプションを使用してください"
            exit 1
        fi
    fi

    # 最小テンプレート生成
    cat > "$env_file" <<ENVEOF
# IGNITE - systemd EnvironmentFile
# chmod 600 ${env_file}

PATH=${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin
HOME=${HOME}
TERM=xterm-256color

ANTHROPIC_API_KEY=your-api-key-here
CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1

XDG_CONFIG_HOME=${HOME}/.config
XDG_DATA_HOME=${HOME}/.local/share
ENVEOF

    print_header "IGNITE 環境変数セットアップ"
    echo ""
    print_success "パス設定を自動検出しました"

    # 対話モードで API キーを設定
    if [[ -t 0 ]]; then
        echo ""
        read -p "Anthropic API Key を入力してください（スキップ: Enter）: " -r api_key
        if [[ -n "$api_key" ]]; then
            # sed の特殊文字問題を回避するため pure bash で置換
            local tmpfile="${env_file}.tmp"
            while IFS= read -r line; do
                case "$line" in
                    ANTHROPIC_API_KEY=*) printf 'ANTHROPIC_API_KEY=%s\n' "$api_key" ;;
                    *) printf '%s\n' "$line" ;;
                esac
            done < "$env_file" > "$tmpfile" && mv "$tmpfile" "$env_file"
            print_success "API Key を設定しました"
        else
            print_warning "API Key はスキップしました（後で $env_file を編集してください）"
        fi
    fi

    # パーミッション設定
    chmod 600 "$env_file"
    print_success "パーミッションを 600 に設定しました"

    echo ""
    print_success "環境変数ファイルを作成しました: $env_file"
    echo -e "確認・編集: ${YELLOW}nano $env_file${NC}"
}

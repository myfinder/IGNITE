# shellcheck shell=bash
# lib/cmd_init.sh - initコマンド（ワークスペース設定の初期化）
[[ -n "${__LIB_CMD_INIT_LOADED:-}" ]] && return; __LIB_CMD_INIT_LOADED=1

# =============================================================================
# init コマンド - ワークスペース固有の .ignite/ 設定を初期化
# =============================================================================
cmd_init() {
    local target_dir=""
    local force=false
    local minimal=false
    local migrate=false

    # オプション解析
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -w|--workspace)
                target_dir="$2"
                shift 2
                ;;
            -f|--force)
                force=true
                shift
                ;;
            --minimal)
                minimal=true
                shift
                ;;
            --migrate)
                migrate=true
                shift
                ;;
            -h|--help)
                _cmd_init_help
                exit 0
                ;;
            -*)
                print_error "Unknown option: $1"
                _cmd_init_help
                exit 1
                ;;
            *)
                # 位置引数としてディレクトリを受け取る
                if [[ -z "$target_dir" ]]; then
                    target_dir="$1"
                fi
                shift
                ;;
        esac
    done

    # ディレクトリ解決
    if [[ -z "$target_dir" ]]; then
        target_dir="$(pwd)"
    fi
    # 相対パスを絶対パスに変換（存在しない場合は作成）
    if [[ ! "$target_dir" = /* ]]; then
        if [[ ! -d "$target_dir" ]]; then
            mkdir -p "$target_dir" || {
                print_error "ディレクトリを作成できません: $target_dir"
                exit 1
            }
        fi
        target_dir="$(cd "$target_dir" && pwd)"
    fi

    local ignite_dir="${target_dir}/.ignite"

    print_header "IGNITE ワークスペース初期化"
    echo ""
    echo -e "${BLUE}対象ディレクトリ:${NC} $target_dir"
    echo -e "${BLUE}.ignite ディレクトリ:${NC} $ignite_dir"
    echo ""

    # 既存チェック（--migrate 時は --force 不要で上書き許可）
    if [[ -d "$ignite_dir" ]] && [[ "$force" == false ]] && [[ "$migrate" == false ]]; then
        print_warning ".ignite/ ディレクトリは既に存在します: $ignite_dir"
        echo -e "上書きする場合は ${YELLOW}--force${NC} オプションを使用してください。"
        exit 1
    fi

    # .ignite/ ディレクトリ作成
    print_info ".ignite/ ディレクトリを作成中..."
    mkdir -p "$ignite_dir"

    # .gitignore 生成（.ignite/ 内 — credentials + 秘密鍵を保護）
    cat > "$ignite_dir/.gitignore" <<'GITIGNORE'
# IGNITE workspace config
# credentials・秘密鍵はコミットしない
github-app.yaml
*.pem

# ローカルのみの設定（必要に応じてコメント解除）
# system.yaml
# github-watcher.yaml
GITIGNORE
    print_success ".gitignore を生成しました（github-app.yaml, *.pem を除外）"

    # --migrate: ~/.config/ignite/ から .ignite/ へ移行
    if [[ "$migrate" == true ]]; then
        _cmd_init_migrate "$ignite_dir"
    else
        # テンプレート設定ファイルのコピー
        if [[ "$minimal" == true ]]; then
            # --minimal: system.yaml のみ
            _copy_config_template "system.yaml" "$ignite_dir"
        else
            # 通常: 全設定ファイルをコピー
            _copy_config_template "system.yaml" "$ignite_dir"
            _copy_config_template "characters.yaml" "$ignite_dir"
            _copy_config_template "pricing.yaml" "$ignite_dir"

            # github-watcher.yaml は example があればコピー
            if [[ -f "$IGNITE_CONFIG_DIR/github-watcher.yaml" ]]; then
                _copy_config_template "github-watcher.yaml" "$ignite_dir"
            elif [[ -f "$IGNITE_CONFIG_DIR/github-watcher.yaml.example" ]]; then
                cp "$IGNITE_CONFIG_DIR/github-watcher.yaml.example" "$ignite_dir/github-watcher.yaml"
                print_success "github-watcher.yaml をexampleからコピーしました"
            fi
        fi
    fi

    # .ignite/ パーミッション設定（credentials 保護）
    chmod 700 "$ignite_dir"
    print_success ".ignite/ パーミッションを 700 に設定しました"

    # 完了メッセージ
    echo ""
    print_header "初期化完了"
    echo ""
    echo "作成された構造:"
    echo "  ${target_dir}/"
    echo "  └── .ignite/"
    echo "      ├── .gitignore"
    echo "      ├── system.yaml"
    if [[ "$minimal" == false ]]; then
        echo "      ├── characters.yaml"
        echo "      └── pricing.yaml"
    else
        echo "      └── (minimal mode)"
    fi
    echo ""
    echo -e "${YELLOW}注意:${NC} github-app.yaml（credentials）は .ignite/.gitignore で"
    echo -e "自動的にGit追跡から除外されます（セキュリティ保護）。"
    echo ""
    echo "次のステップ:"
    echo -e "  1. 設定を編集: ${YELLOW}vi ${ignite_dir}/system.yaml${NC}"
    echo -e "  2. 起動: ${YELLOW}ignite start${NC}（CWDから .ignite/ を自動検出）"
}

# _cmd_init_migrate - ~/.config/ignite/ → .ignite/ へ設定を移行
# Usage: _cmd_init_migrate <dest_ignite_dir>
_cmd_init_migrate() {
    local dest_dir="$1"
    local legacy_dir="${HOME}/.config/ignite"

    if [[ ! -d "$legacy_dir" ]]; then
        print_warning "移行元ディレクトリが見つかりません: $legacy_dir"
        print_info "テンプレートから新規初期化します"
        _copy_config_template "system.yaml" "$dest_dir"
        return 0
    fi

    # 移行対象ファイル一覧
    print_header "移行対象ファイル"
    echo ""
    local files_to_migrate=()
    local file
    for file in "$legacy_dir"/*.yaml "$legacy_dir"/*.yaml.example; do
        [[ -f "$file" ]] || continue
        local filename
        filename=$(basename "$file")
        # .install_paths は移行しない
        [[ "$filename" == ".install_paths" ]] && continue
        # github-app.yaml は credentials のため移行しない（セキュリティ保護）
        if [[ "$filename" == "github-app.yaml" ]]; then
            print_warning "github-app.yaml はcredentialsのためスキップします（環境変数での管理を推奨）"
            continue
        fi
        files_to_migrate+=("$filename")
        echo -e "  ${BLUE}→${NC} $filename"
    done

    if [[ ${#files_to_migrate[@]} -eq 0 ]]; then
        print_warning "移行対象のファイルがありません"
        return 0
    fi

    echo ""
    echo -e "${YELLOW}移行元:${NC} $legacy_dir"
    echo -e "${YELLOW}移行先:${NC} $dest_dir"
    echo ""

    # 対話確認（非対話環境ではスキップ）
    if [[ -t 0 ]]; then
        read -p "上記ファイルを移行しますか? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "移行をキャンセルしました"
            return 0
        fi
    else
        print_info "非対話環境: 自動的に移行を実行します"
    fi

    # コピー実行
    for filename in "${files_to_migrate[@]}"; do
        cp "$legacy_dir/$filename" "$dest_dir/$filename"
        print_success "$filename を移行しました"
    done

    echo ""
    print_success "移行完了 (${#files_to_migrate[@]} ファイル)"
    echo ""
    echo -e "${YELLOW}注意:${NC} 元ディレクトリ ($legacy_dir) は自動削除されません。"
    echo -e "確認後に手動で削除してください: ${YELLOW}rm -rf $legacy_dir${NC}"
}

# _copy_config_template - テンプレート設定からワークスペースにコピー
# Usage: _copy_config_template <filename> <dest_dir>
_copy_config_template() {
    local filename="$1"
    local dest_dir="$2"

    if [[ -f "$IGNITE_CONFIG_DIR/$filename" ]]; then
        cp "$IGNITE_CONFIG_DIR/$filename" "$dest_dir/$filename"
        print_success "$filename をコピーしました"
    else
        print_warning "$filename がテンプレート設定に見つかりません（スキップ）"
    fi
}

# _cmd_init_help - init コマンドのヘルプ表示
_cmd_init_help() {
    echo "使用方法: ignite init [OPTIONS] [WORKSPACE_DIR]"
    echo ""
    echo "ワークスペース固有の .ignite/ 設定ディレクトリを初期化します。"
    echo "テンプレート設定をコピーし、プロジェクトごとにカスタマイズ可能にします。"
    echo ""
    echo "オプション:"
    echo "  -w, --workspace <dir>   初期化するディレクトリを指定"
    echo "  -f, --force             既存の .ignite/ を上書き"
    echo "  --minimal               system.yaml のみコピー（最小構成）"
    echo "  --migrate               ~/.config/ignite/ から設定を移行"
    echo "  -h, --help              この使い方を表示"
    echo ""
    echo "例:"
    echo "  ignite init                    # カレントディレクトリに初期化"
    echo "  ignite init /path/to/project   # 指定ディレクトリに初期化"
    echo "  ignite init --minimal          # 最小構成で初期化"
    echo "  ignite init --migrate          # グローバル設定から移行"
    echo "  ignite init -f                 # 既存設定を上書き"
    echo ""
    echo "設計:"
    echo "  - .ignite/ が唯一の設定ソースです"
    echo "  - github-app.yaml は .gitignore で自動除外されます"
    echo "  - *.pem（秘密鍵）も .gitignore で自動除外されます"
    echo "  - .ignite/ はリポジトリにコミット可能です（チーム共有用）"
}

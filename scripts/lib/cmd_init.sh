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
    local update_mode=""
    local backup_enabled=true
    local restore_path=""

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
            --update)
                update_mode="apply"
                if [[ -n "${2:-}" ]] && [[ "$2" =~ ^(check|apply|force)$ ]]; then
                    update_mode="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            --update=*)
                update_mode="${1#--update=}"
                shift
                ;;
            --backup)
                backup_enabled=true
                shift
                ;;
            --no-backup)
                backup_enabled=false
                shift
                ;;
            --restore)
                restore_path="$2"
                shift 2
                ;;
            --restore=*)
                restore_path="${1#--restore=}"
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

    if [[ -n "$update_mode" ]] && [[ "$migrate" == true ]]; then
        print_error "--update と --migrate は同時に指定できません"
        exit 1
    fi

    if [[ -n "$update_mode" ]]; then
        update_mode="$(sanitize_update_mode "$update_mode")" || exit 1
    fi

    if [[ -n "$restore_path" ]]; then
        _cmd_init_restore "$ignite_dir" "$restore_path" "$backup_enabled"
        exit 0
    fi

    # 既存チェック（--migrate 時は --force 不要で上書き許可）
    if [[ -d "$ignite_dir" ]] && [[ "$force" == false ]] && [[ "$migrate" == false ]] && [[ -z "$update_mode" ]]; then
        print_warning ".ignite/ ディレクトリは既に存在します: $ignite_dir"
        echo -e "上書きする場合は ${YELLOW}--force${NC} オプションを使用してください。"
        exit 1
    fi

    if [[ -n "$update_mode" ]]; then
        if [[ ! -d "$ignite_dir" ]]; then
            print_warning ".ignite/ が存在しないため、通常の init を実行します"
        else
            _cmd_init_update "$ignite_dir" "$update_mode" "$backup_enabled" "$minimal"
            return
        fi
    fi

    # .ignite/ ディレクトリ作成
    print_info ".ignite/ ディレクトリを作成中..."
    mkdir -p "$ignite_dir"

    # .ignite/.gitignore 生成（ランタイムデータ除外）
    cat > "$ignite_dir/.gitignore" <<'GITIGNORE'
# IGNITE runtime data (auto-generated, do not commit)
queue/
logs/
state/
context/
archive/
repos/
tmp/
dashboard.md
runtime.yaml
opencode_*.json

# secrets (never commit)
.env
*.pem
GITIGNORE
    print_success ".ignite/.gitignore を生成しました（ランタイムデータ・秘密鍵・.env を除外）"

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

            # github-watcher.yaml / github-app.yaml は .example からコピー
            _copy_example_config "github-watcher.yaml" "$ignite_dir"
            _copy_example_config "github-app.yaml" "$ignite_dir"
        fi
    fi

    # .env.example の生成（--minimal でも生成 — API キーは最小構成でも必要）
    cat > "$ignite_dir/.env.example" <<'ENVEOF'
# IGNITE 環境変数（.env にコピーして値を設定してください）
# cp .env.example .env && vi .env
#
# このファイル (.env.example) はコミット可能です。
# .env は .gitignore で自動的に除外されます。

# --- API Keys (OpenCode 使用時に必要) ---
# OPENAI_API_KEY=sk-...
# ANTHROPIC_API_KEY=sk-ant-...

# --- Ollama（ローカルLLM使用時） ---
# system.yaml で model: ollama/<model> を指定すると自動的に Ollama に接続します
# 事前に ollama serve を起動し、モデルを pull しておくこと（API Key は不要）
# デフォルト接続先: http://localhost:11434/v1（変更する場合のみ設定）
# OLLAMA_API_URL=http://localhost:11434/v1

# --- GitHub Token (GitHub App 未使用時のフォールバック) ---
# GH_TOKEN=ghp_...
ENVEOF
    print_success ".env.example を生成しました"

    # instructions/characters のコピー
    _copy_instructions "$ignite_dir"

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
        echo "      ├── github-watcher.yaml.example"
        echo "      ├── github-app.yaml.example"
    fi
    echo "      ├── .env.example"
    echo "      ├── instructions/"
    echo "      └── characters/"
    echo ""
    echo -e "${YELLOW}注意:${NC} ランタイムデータ（queue/, logs/, state/ 等）は .ignite/.gitignore で"
    echo -e "自動的にGit追跡から除外されます。"
    echo ""
    echo "次のステップ:"
    echo -e "  1. 設定を編集: ${YELLOW}vi ${ignite_dir}/system.yaml${NC}"
    echo -e "  2. 起動: ${YELLOW}ignite start${NC}（CWDから .ignite/ を自動検出）"
}

# =============================================================================
# update/restore helpers
# =============================================================================

sanitize_update_mode() {
    local mode
    mode=$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')
    case "$mode" in
        check|apply|force)
            echo "$mode"
            return 0
            ;;
        *)
            print_error "Unknown update mode: ${1:-<empty>} (check/apply/force)"
            return 1
            ;;
    esac
}

sanitize_restore_path() {
    local path="$1"
    if [[ -z "$path" ]]; then
        return 1
    fi
    if [[ ! "$path" = /* ]]; then
        path="$(cd "$path" 2>/dev/null && pwd)"
    fi
    [[ -n "$path" ]] || return 1
    echo "$path"
}

_init_generate_gitignore() {
    local dest_dir="$1"
    cat > "$dest_dir/.gitignore" <<'GITIGNORE'
# IGNITE runtime data (auto-generated, do not commit)
queue/
logs/
state/
context/
archive/
repos/
tmp/
dashboard.md
runtime.yaml
opencode_*.json

# secrets (never commit)
.env
*.pem
GITIGNORE
}

_init_generate_env_example() {
    local dest_dir="$1"
    cat > "$dest_dir/.env.example" <<'ENVEOF'
# IGNITE 環境変数（.env にコピーして値を設定してください）
# cp .env.example .env && vi .env
#
# このファイル (.env.example) はコミット可能です。
# .env は .gitignore で自動的に除外されます。

# --- API Keys (OpenCode 使用時に必要) ---
# OPENAI_API_KEY=sk-...
# ANTHROPIC_API_KEY=sk-ant-...

# --- Ollama（ローカルLLM使用時） ---
# system.yaml で model: ollama/<model> を指定すると自動的に Ollama に接続します
# 事前に ollama serve を起動し、モデルを pull しておくこと（API Key は不要）
# デフォルト接続先: http://localhost:11434/v1（変更する場合のみ設定）
# OLLAMA_API_URL=http://localhost:11434/v1

# --- GitHub Token (GitHub App 未使用時のフォールバック) ---
# GH_TOKEN=ghp_...
ENVEOF
}

_init_prepare_template_dir() {
    local dest_dir="$1"
    local minimal="$2"

    mkdir -p "$dest_dir"
    _init_generate_gitignore "$dest_dir"

    if [[ "$minimal" == true ]]; then
        _copy_config_template "system.yaml" "$dest_dir"
    else
        _copy_config_template "system.yaml" "$dest_dir"
        _copy_config_template "characters.yaml" "$dest_dir"
        _copy_example_config "github-watcher.yaml" "$dest_dir"
        _copy_example_config "github-app.yaml" "$dest_dir"
    fi

    _init_generate_env_example "$dest_dir"
    _copy_instructions "$dest_dir"
}

_init_collect_update_files() {
    local dir="$1"
    (cd "$dir" && find . -type f -print | sed 's|^\./||')
}

_init_backup_dir() {
    local ignite_dir="$1"
    local backup_dir="$2"

    print_info "バックアップを作成します: $backup_dir"
    cp -a "$ignite_dir" "$backup_dir"
}

_init_restore_from_backup() {
    local ignite_dir="$1"
    local backup_dir="$2"

    print_warning "バックアップから復元します: $backup_dir"
    rm -rf "$ignite_dir"
    cp -a "$backup_dir" "$ignite_dir"
}

_cmd_init_update() {
    local ignite_dir="$1"
    local update_mode="$2"
    local backup_enabled="$3"
    local minimal="$4"

    local tmp_dir
    tmp_dir=$(mktemp -d)

    _init_prepare_template_dir "$tmp_dir" "$minimal"

    local -a files=()
    local -a status=()
    local -a reason=()

    while IFS= read -r rel; do
        [[ -z "$rel" ]] && continue
        if [[ "$rel" == /* ]] || [[ "$rel" == *"../"* ]]; then
            print_warning "不正なパスをスキップ: $rel"
            continue
        fi
        local src="$tmp_dir/$rel"
        local dst="$ignite_dir/$rel"

        if [[ -f "$dst" ]]; then
            if cmp -s "$src" "$dst"; then
                files+=("$rel")
                status+=("same")
                reason+=("")
            else
                files+=("$rel")
                status+=("diff")
                reason+=("変更あり")
            fi
        else
            files+=("$rel")
            status+=("add")
            reason+=("新規")
        fi
    done < <(_init_collect_update_files "$tmp_dir")

    print_header "更新プレビュー"
    echo ""
    echo -e "${BLUE}mode:${NC} $update_mode"
    echo ""

    local idx=0
    local adds=0
    local diffs=0
    local sames=0
    while [[ $idx -lt ${#files[@]} ]]; do
        case "${status[$idx]}" in
            add)
                echo -e "  ${GREEN}+${NC} ${files[$idx]}"
                adds=$((adds + 1))
                ;;
            diff)
                echo -e "  ${YELLOW}!${NC} ${files[$idx]} (${reason[$idx]})"
                diffs=$((diffs + 1))
                ;;
            same)
                echo -e "  ${BLUE}=${NC} ${files[$idx]}"
                sames=$((sames + 1))
                ;;
        esac
        idx=$((idx + 1))
    done
    echo ""
    echo "summary: add=$adds diff=$diffs same=$sames"

    if [[ "$update_mode" == "check" ]]; then
        rm -rf "$tmp_dir"
        return 0
    fi

    if [[ "$update_mode" == "force" ]]; then
        print_warning "--update=force により差分ファイルを上書きします"
    fi

    local backup_dir=""
    if [[ "$backup_enabled" == true ]]; then
        backup_dir="${ignite_dir}.bak.$(date +%Y%m%d%H%M%S)"
        if ! _init_backup_dir "$ignite_dir" "$backup_dir"; then
            print_error "バックアップ作成に失敗しました"
            rm -rf "$tmp_dir"
            exit 1
        fi
    fi

    local failed=false
    idx=0
    while [[ $idx -lt ${#files[@]} ]]; do
        local rel="${files[$idx]}"
        local src="$tmp_dir/$rel"
        local dst="$ignite_dir/$rel"

        case "${status[$idx]}" in
            same)
                ;;
            add)
                mkdir -p "$(dirname "$dst")"
                cp "$src" "$dst" || failed=true
                ;;
            diff)
                if [[ "$update_mode" == "force" ]]; then
                    mkdir -p "$(dirname "$dst")"
                    cp "$src" "$dst" || failed=true
                else
                    print_warning "競合のためスキップ: $rel"
                fi
                ;;
        esac
        idx=$((idx + 1))
    done

    if [[ "$failed" == true ]]; then
        print_error "更新中にエラーが発生しました"
        if [[ -n "$backup_dir" ]]; then
            _init_restore_from_backup "$ignite_dir" "$backup_dir"
        fi
        rm -rf "$tmp_dir"
        exit 1
    fi

    chmod 700 "$ignite_dir"
    rm -rf "$tmp_dir"
    print_success "更新が完了しました"
}

_cmd_init_restore() {
    local ignite_dir="$1"
    local restore_path="$2"
    local backup_enabled="$3"

    if [[ -z "$restore_path" ]]; then
        print_error "--restore にバックアップパスを指定してください"
        exit 1
    fi

    restore_path="$(sanitize_restore_path "$restore_path")" || {
        print_error "バックアップパスが不正です"
        exit 1
    }

    if [[ ! -d "$restore_path" ]]; then
        print_error "バックアップディレクトリが見つかりません: $restore_path"
        exit 1
    fi

    if [[ ! -f "$restore_path/.gitignore" ]] && [[ ! -f "$restore_path/system.yaml" ]]; then
        print_warning "バックアップディレクトリに既知ファイルが見つかりません: $restore_path"
    fi

    local backup_dir=""
    if [[ -d "$ignite_dir" ]] && [[ "$backup_enabled" == true ]]; then
        backup_dir="${ignite_dir}.bak.$(date +%Y%m%d%H%M%S)"
        if ! _init_backup_dir "$ignite_dir" "$backup_dir"; then
            print_error "バックアップ作成に失敗しました"
            exit 1
        fi
    fi

    _init_restore_from_backup "$ignite_dir" "$restore_path" || {
        print_error "復元に失敗しました"
        exit 1
    }

    chmod 700 "$ignite_dir"
    print_success "復元が完了しました"
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

# _copy_instructions - instructions/characters をワークスペースにコピー
# Usage: _copy_instructions <dest_ignite_dir>
_copy_instructions() {
    local dest_dir="$1"

    # instructions のコピー
    if [[ -d "$IGNITE_INSTRUCTIONS_DIR" ]]; then
        mkdir -p "$dest_dir/instructions"
        cp "$IGNITE_INSTRUCTIONS_DIR"/*.md "$dest_dir/instructions/" 2>/dev/null || true
        print_success "instructions/ をコピーしました"
    else
        print_warning "instructions ディレクトリが見つかりません（スキップ）"
    fi

    # characters のコピー
    if [[ -d "$IGNITE_CHARACTERS_DIR" ]]; then
        mkdir -p "$dest_dir/characters"
        cp "$IGNITE_CHARACTERS_DIR"/*.md "$dest_dir/characters/" 2>/dev/null || true
        print_success "characters/ をコピーしました"
    else
        print_warning "characters ディレクトリが見つかりません（スキップ）"
    fi
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

# _copy_example_config - .example テンプレートからコピー
# Usage: _copy_example_config <filename> <dest_dir>
_copy_example_config() {
    local filename="$1"
    local dest_dir="$2"

    if [[ -f "$IGNITE_CONFIG_DIR/${filename}.example" ]]; then
        cp "$IGNITE_CONFIG_DIR/${filename}.example" "$dest_dir/${filename}.example"
        print_success "${filename}.example をコピーしました"
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
    echo "  --update[=check|apply|force]  既存 .ignite/ を安全に更新"
    echo "  --backup                更新前にバックアップを作成（デフォルト）"
    echo "  --no-backup             バックアップを作成しない"
    echo "  --restore <backup_dir>  バックアップから復元"
    echo "  -h, --help              この使い方を表示"
    echo ""
    echo "例:"
    echo "  ignite init                    # カレントディレクトリに初期化"
    echo "  ignite init /path/to/project   # 指定ディレクトリに初期化"
    echo "  ignite init --minimal          # 最小構成で初期化"
    echo "  ignite init --migrate          # グローバル設定から移行"
    echo "  ignite init --update=check     # 差分のみ表示"
    echo "  ignite init --update=apply     # 安全に更新（競合はスキップ）"
    echo "  ignite init --update=force     # 競合を上書き"
    echo "  ignite init -f                 # 既存設定を上書き"
    echo ""
    echo "設計:"
    echo "  - .ignite/ が唯一の設定ソースです"
    echo "  - github-app.yaml はコミット可能（app_id + pemパスのみ）"
    echo "  - *.pem（秘密鍵）は .gitignore で自動除外されます"
    echo "  - .ignite/ はリポジトリにコミット可能です（チーム共有用）"
}

# shellcheck shell=bash
# lib/cli_provider.sh - CLI Provider 抽象化レイヤー
# Claude Code / OpenCode 等の CLI ツールを切り替え可能にする
[[ -n "${__LIB_CLI_PROVIDER_LOADED:-}" ]] && return; __LIB_CLI_PROVIDER_LOADED=1

# グローバル変数（cli_load_config で設定される）
CLI_PROVIDER=""
CLI_MODEL=""
CLI_COMMAND=""

# =============================================================================
# cli_load_config - system.yaml の cli: セクション読み込み
# =============================================================================
cli_load_config() {
    local config_file="$IGNITE_CONFIG_DIR/system.yaml"

    CLI_PROVIDER=$(get_config cli provider "opencode")
    CLI_MODEL=$(get_config cli model "$DEFAULT_MODEL")

    case "$CLI_PROVIDER" in
        claude)
            CLI_COMMAND="claude"
            ;;
        opencode)
            CLI_COMMAND="opencode"
            ;;
        *)
            print_error "未対応の CLI プロバイダー: $CLI_PROVIDER (claude|opencode)"
            return 1
            ;;
    esac
}

# =============================================================================
# cli_build_launch_command - tmux send-keys に渡す起動コマンド文字列を生成
# =============================================================================
# Usage: cli_build_launch_command <workspace_dir> [extra_env] [gh_export]
cli_build_launch_command() {
    local workspace_dir="$1"
    local extra_env="${2:-}"
    local gh_export="${3:-}"

    # .env が存在すれば tmux ペイン内で source（親プロセスの env は tmux に継承されない）
    local env_source=""
    if [[ -f "${workspace_dir}/.ignite/.env" ]]; then
        env_source="set -a && source '${workspace_dir}/.ignite/.env' && set +a && "
    fi

    local cmd="${gh_export}${extra_env}${env_source}export WORKSPACE_DIR='${workspace_dir}' IGNITE_RUNTIME_DIR='${workspace_dir}/.ignite' && cd '${workspace_dir}' && "

    case "$CLI_PROVIDER" in
        claude)
            cmd+="CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 claude --model $CLI_MODEL --dangerously-skip-permissions --teammate-mode in-process"
            ;;
        opencode)
            cmd+="OPENCODE_CONFIG='.ignite/opencode.json' opencode"
            ;;
    esac

    echo "$cmd"
}

# =============================================================================
# cli_get_process_names - health_check 用プロセス名リストを返す
# =============================================================================
cli_get_process_names() {
    case "$CLI_PROVIDER" in
        claude)
            echo "claude node"
            ;;
        opencode)
            echo "opencode"
            ;;
    esac
}

# =============================================================================
# cli_needs_permission_accept - 起動後の権限確認ダイアログ通過が必要か
# =============================================================================
# Returns: 0 = 必要, 1 = 不要
cli_needs_permission_accept() {
    case "$CLI_PROVIDER" in
        claude)
            return 0
            ;;
        opencode)
            return 1
            ;;
    esac
}

# =============================================================================
# cli_get_submit_keys - tmux send-keys でプロンプトを確定送信するキーシーケンス
# =============================================================================
# Claude Code: "C-m" (通常の Enter キーイベント)
# OpenCode: Bubble Tea TUI は tmux の Enter/C-m を受け付けない
#           "-l" フラグ付きでリテラル CR ($'\r') を送る必要がある
# Usage: eval "tmux send-keys -t \$target $(cli_get_submit_keys)"
cli_get_submit_keys() {
    case "$CLI_PROVIDER" in
        claude)
            echo "C-m"
            ;;
        opencode)
            echo "-l $'\r'"
            ;;
    esac
}

# =============================================================================
# cli_needs_prompt_injection - tmux send-keys でプロンプトを送信する必要があるか
# =============================================================================
# Claude Code: TUI が send-keys を受け付けるので tmux 経由でプロンプト送信
# OpenCode: TUI が send-keys 非互換。opencode.json の instructions で対応
# Returns: 0 = 必要, 1 = 不要
cli_needs_prompt_injection() {
    case "$CLI_PROVIDER" in
        claude)
            return 0
            ;;
        opencode)
            return 1
            ;;
    esac
}

# =============================================================================
# cli_wait_tui_ready - TUI が入力を受け付ける状態になるまで待機
# =============================================================================
# Usage: cli_wait_tui_ready <tmux_target>
# Claude Code: プロンプト表示 (>) を待つ（最大 5 秒）
# OpenCode: Bubble Tea TUI 描画完了を待つ（最大 10 秒）
cli_wait_tui_ready() {
    local target="$1"
    local max_wait marker
    case "$CLI_PROVIDER" in
        claude)
            max_wait=5
            marker=">"
            ;;
        opencode)
            max_wait=10
            marker="Ask anything"
            ;;
    esac
    local i=0
    while [[ $i -lt $max_wait ]]; do
        local content
        content=$(tmux capture-pane -t "$target" -p 2>/dev/null || true)
        if [[ "$content" == *"$marker"* ]]; then
            return 0
        fi
        sleep 1
        ((i++))
    done
}

# =============================================================================
# cli_is_cost_tracking_supported - .jsonl コスト追跡が使えるか
# =============================================================================
# Returns: 0 = 対応, 1 = 非対応
cli_is_cost_tracking_supported() {
    case "$CLI_PROVIDER" in
        claude)
            return 0
            ;;
        opencode)
            return 1
            ;;
    esac
}

# =============================================================================
# cli_setup_project_config - プロバイダー固有のプロジェクト設定を生成
# =============================================================================
# Usage: cli_setup_project_config <workspace_dir> [instruction_files...]
# instruction_files: opencode の instructions に追加するファイルパス（可変長）
cli_setup_project_config() {
    local workspace_dir="$1"
    shift
    local instruction_files=("$@")

    case "$CLI_PROVIDER" in
        claude)
            # Claude Code は既存の設定をそのまま使用
            ;;
        opencode)
            local config_file="${workspace_dir}/.ignite/opencode.json"
            # .ignite/ がない場合はワークスペースルートにフォールバック
            if [[ ! -d "${workspace_dir}/.ignite" ]]; then
                config_file="${workspace_dir}/opencode.json"
            fi
            # 起動ごとに再生成（model や instructions が変わりうるため）

            # instructions JSON 配列を構築
            local instructions_json="[]"
            if [[ ${#instruction_files[@]} -gt 0 ]]; then
                instructions_json="["
                local first=true
                for f in "${instruction_files[@]}"; do
                    [[ -z "$f" ]] && continue
                    if [[ "$first" == true ]]; then
                        first=false
                    else
                        instructions_json+=","
                    fi
                    instructions_json+="\"$f\""
                done
                instructions_json+="]"
            fi

            # OpenCode 設定を生成（https://opencode.ai/docs/config/ 準拠）
            # permission: {"*": "allow"} で全ツールを自動承認（Claude の --dangerously-skip-permissions 相当）
            cat > "$config_file" <<OCEOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "$CLI_MODEL",
  "permission": {"*": "allow"},
  "instructions": $instructions_json
}
OCEOF
            log_info "opencode.json を生成しました: $config_file"
            ;;
    esac
}

# =============================================================================
# cli_get_env_vars - systemd EnvironmentFile に書く CLI 固有の環境変数
# =============================================================================
cli_get_env_vars() {
    case "$CLI_PROVIDER" in
        claude)
            echo "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1"
            ;;
        opencode)
            echo "OPENCODE_CONFIG=.ignite/opencode.json"
            # API Key は .ignite/.env から読み込み（cli_get_env_vars では出力しない）
            ;;
    esac
}

# =============================================================================
# cli_get_required_commands - インストール時の依存コマンドリストを返す
# =============================================================================
cli_get_required_commands() {
    case "$CLI_PROVIDER" in
        claude)
            echo "tmux claude gh"
            ;;
        opencode)
            echo "tmux opencode gh"
            ;;
    esac
}

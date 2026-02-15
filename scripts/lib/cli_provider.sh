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

    # モデル名バリデーション（英数字, ハイフン, ドット, スラッシュ, アンダースコア, コロンのみ許可）
    if [[ ! "$CLI_MODEL" =~ ^[a-zA-Z0-9/:._-]+$ ]]; then
        print_error "不正な model 名: $CLI_MODEL（使用可能: 英数字, /, :, ., _, -）"
        return 1
    fi

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
# Usage: cli_build_launch_command <workspace_dir> [extra_env] [gh_export] [role]
cli_build_launch_command() {
    local workspace_dir="$1"
    local extra_env="${2:-}"
    local gh_export="${3:-}"
    local role="${4:-}"

    # .env が存在すれば tmux ペイン内で source（親プロセスの env は tmux に継承されない）
    local env_source=""
    if [[ -f "${workspace_dir}/.ignite/.env" ]]; then
        env_source="set -a && source '${workspace_dir}/.ignite/.env' && set +a && "
    fi

    local cmd="${gh_export}${extra_env}${env_source}export WORKSPACE_DIR='${workspace_dir}' IGNITE_RUNTIME_DIR='${workspace_dir}/.ignite' && cd '${workspace_dir}' && "

    case "$CLI_PROVIDER" in
        claude)
            cmd+="CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 claude --model '${CLI_MODEL}' --dangerously-skip-permissions --teammate-mode in-process"
            ;;
        opencode)
            # ロール別の opencode.json を参照（未指定時は leader）
            local config_name="opencode_${role:-leader}.json"
            cmd+="OPENCODE_CONFIG='.ignite/${config_name}' opencode"
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
            echo "opencode node"
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
# Usage: cli_setup_project_config <workspace_dir> <role> [instruction_files...]
# role: エージェントロール名（opencode_{role}.json のファイル名に使用）
# instruction_files: opencode の instructions に追加するファイルパス（可変長）
cli_setup_project_config() {
    local workspace_dir="$1"
    local role="$2"
    shift 2 || true
    local instruction_files=()

    if [[ -z "$role" || "$role" == /* || "$role" == *.md ]]; then
        instruction_files=("$role" "$@")
        role="leader"
    else
        instruction_files=("$@")
    fi

    case "$CLI_PROVIDER" in
        claude)
            # Claude Code は既存の設定をそのまま使用
            ;;
        opencode)
            local config_file="${workspace_dir}/.ignite/opencode_${role}.json"
            # .ignite/ がない場合はワークスペースルートにフォールバック
            if [[ ! -d "${workspace_dir}/.ignite" ]]; then
                config_file="${workspace_dir}/opencode_${role}.json"
            fi
            # 起動ごとに再生成（model や instructions が変わりうるため）

            # instructions JSON 配列を構築
            local instructions_json="[]"
            if [[ ${#instruction_files[@]} -gt 0 ]]; then
                local _items=""
                local first=true
                for f in "${instruction_files[@]}"; do
                    [[ -z "$f" ]] && continue
                    # パス内の \ と " をエスケープ
                    local escaped_f="${f//\\/\\\\}"
                    escaped_f="${escaped_f//\"/\\\"}"
                    if [[ "$first" == true ]]; then
                        first=false
                    else
                        _items+=","
                    fi
                    _items+="\"$escaped_f\""
                done
                if [[ "$first" == false ]]; then
                    instructions_json="[${_items}]"
                fi
            fi

            # Ollama プロバイダー設定を構築（model が ollama/ で始まる場合）
            local provider_json=""
            if [[ "$CLI_MODEL" == ollama/* ]]; then
                local ollama_url="${OLLAMA_API_URL:-http://localhost:11434/v1}"
                local ollama_model="${CLI_MODEL#ollama/}"
                # JSON インジェクション防止: " と \ をエスケープ
                ollama_url="${ollama_url//\\/\\\\}"
                ollama_url="${ollama_url//\"/\\\"}"
                ollama_model="${ollama_model//\\/\\\\}"
                ollama_model="${ollama_model//\"/\\\"}"
                provider_json=',
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "'"$ollama_url"'"
      },
      "models": {
        "'"$ollama_model"'": {
          "tools": true
        }
      }
    }
  }'
            fi

            # OpenCode 設定を生成（https://opencode.ai/docs/config/ 準拠）
            # permission: {"*": "allow"} で全ツールを自動承認（Claude の --dangerously-skip-permissions 相当）
            cat > "$config_file" <<OCEOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "$CLI_MODEL",
  "permission": {"*": "allow"},
  "instructions": $instructions_json${provider_json}
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

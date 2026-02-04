#!/bin/bash
# キュー監視・自動処理スクリプト
# キューに新しいメッセージが来たら、対応するエージェントに処理を指示

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# カラー定義
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${BLUE}[QUEUE]${NC} $1"; }
log_success() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${GREEN}[QUEUE]${NC} $1"; }
log_warn() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${YELLOW}[QUEUE]${NC} $1"; }
log_error() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${RED}[QUEUE]${NC} $1"; }

# 設定
WORKSPACE_DIR="${WORKSPACE_DIR:-$PROJECT_ROOT/workspace}"
POLL_INTERVAL="${QUEUE_POLL_INTERVAL:-10}"
TMUX_SESSION="${IGNITE_TMUX_SESSION:-}"

# 処理済みファイルを追跡
declare -A PROCESSED_FILES

# =============================================================================
# tmux セッションへのメッセージ送信
# =============================================================================

send_to_agent() {
    local agent="$1"
    local message="$2"
    local pane_index

    if [[ -z "$TMUX_SESSION" ]]; then
        log_error "TMUX_SESSION が設定されていません"
        return 1
    fi

    # エージェント名からペインインデックスを決定
    # IGNITE のペイン構成: 0=Leader, 1-8=Sub-agents/IGNITIANs
    case "$agent" in
        leader) pane_index=0 ;;
        strategist) pane_index=1 ;;
        *)
            # IGNITIAN の場合は名前からインデックスを推測
            if [[ "$agent" =~ ^ignitian-([0-9]+)$ ]]; then
                local num=${BASH_REMATCH[1]}
                pane_index=$((num + 1))
            else
                log_warn "未知のエージェント: $agent"
                return 1
            fi
            ;;
    esac

    # tmux でメッセージを送信（ペイン指定）
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        # ペインにメッセージを送信
        # 形式: session:window.pane (window は省略すると現在のウィンドウ)
        local target="${TMUX_SESSION}:1.${pane_index}"

        # メッセージを送信してからEnter（C-m）を送信
        # 少し間を置いてから送信することで確実に入力される
        if tmux send-keys -t "$target" "$message" 2>/dev/null; then
            sleep 0.3
            tmux send-keys -t "$target" C-m 2>/dev/null
            log_success "エージェント $agent (pane $pane_index) にメッセージを送信しました"
            return 0
        else
            log_warn "ペイン $pane_index への送信に失敗しました（ペインが存在しない可能性）"
            return 1
        fi
    else
        log_error "tmux セッションが見つかりません: $TMUX_SESSION"
        return 1
    fi
}

# =============================================================================
# メッセージ処理
# =============================================================================

process_message() {
    local file="$1"
    local queue_name="$2"

    # ファイル名から情報を取得
    local filename=$(basename "$file")

    # YAMLからタイプを読み取り
    local msg_type=$(grep -E '^type:' "$file" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')

    log_info "新規メッセージ検知: $filename (type: $msg_type)"

    # メッセージタイプに応じた処理指示を生成
    local instruction=""
    case "$msg_type" in
        github_task)
            local trigger=$(grep -E '^\s*trigger:' "$file" | head -1 | awk '{print $2}' | tr -d '"')
            local repo=$(grep -E '^\s*repository:' "$file" | head -1 | awk '{print $2}' | tr -d '"')
            local issue_num=$(grep -E '^\s*issue_number:' "$file" | head -1 | awk '{print $2}' | tr -d '"')
            instruction="新しいGitHubタスクが来ました。$file を読んで処理してください。リポジトリ: $repo, Issue/PR: #$issue_num, トリガー: $trigger"
            ;;
        github_event)
            local event_type=$(grep -E '^\s*event_type:' "$file" | head -1 | awk '{print $2}' | tr -d '"')
            instruction="新しいGitHubイベントが来ました。$file を読んで必要に応じて対応してください。イベントタイプ: $event_type"
            ;;
        task)
            instruction="新しいタスクが来ました。$file を読んで処理してください。"
            ;;
        *)
            instruction="新しいメッセージが来ました。$file を読んで処理してください。"
            ;;
    esac

    # エージェントに送信
    send_to_agent "$queue_name" "$instruction"
}

# =============================================================================
# キュー監視
# =============================================================================

scan_queue() {
    local queue_dir="$1"
    local queue_name="$2"

    if [[ ! -d "$queue_dir" ]]; then
        return
    fi

    # 新しいYAMLファイルを検索（processedディレクトリは除く）
    for file in "$queue_dir"/*.yaml; do
        [[ -f "$file" ]] || continue

        local filepath="$file"

        # 既に処理済みならスキップ
        if [[ -n "${PROCESSED_FILES[$filepath]:-}" ]]; then
            continue
        fi

        # statusがpendingのものだけ処理
        local status=$(grep -E '^status:' "$file" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')
        if [[ "$status" != "pending" ]]; then
            PROCESSED_FILES[$filepath]=1
            continue
        fi

        # 処理
        process_message "$file" "$queue_name"
        PROCESSED_FILES[$filepath]=1

        # statusをprocessingに更新
        sed -i 's/^status: pending/status: processing/' "$file" 2>/dev/null || true
    done
}

monitor_queues() {
    log_info "キュー監視を開始します（間隔: ${POLL_INTERVAL}秒）"

    while true; do
        # Leader キュー
        scan_queue "$WORKSPACE_DIR/queue/leader" "leader"

        # Strategist キュー
        scan_queue "$WORKSPACE_DIR/queue/strategist" "strategist"

        # IGNITIAN キュー（複数）
        for ignitian_dir in "$WORKSPACE_DIR/queue/ignitian-"*; do
            if [[ -d "$ignitian_dir" ]]; then
                local ignitian_name=$(basename "$ignitian_dir")
                scan_queue "$ignitian_dir" "$ignitian_name"
            fi
        done

        sleep "$POLL_INTERVAL"
    done
}

# =============================================================================
# inotifywait を使った効率的な監視（利用可能な場合）
# =============================================================================

monitor_with_inotify() {
    if ! command -v inotifywait &> /dev/null; then
        log_warn "inotifywait が見つかりません。ポーリングモードで起動します"
        monitor_queues
        return
    fi

    log_info "inotify モードでキュー監視を開始します"

    # 監視対象ディレクトリを収集
    local watch_dirs=()
    [[ -d "$WORKSPACE_DIR/queue/leader" ]] && watch_dirs+=("$WORKSPACE_DIR/queue/leader")
    [[ -d "$WORKSPACE_DIR/queue/strategist" ]] && watch_dirs+=("$WORKSPACE_DIR/queue/strategist")
    for ignitian_dir in "$WORKSPACE_DIR/queue/ignitian-"*; do
        [[ -d "$ignitian_dir" ]] && watch_dirs+=("$ignitian_dir")
    done

    if [[ ${#watch_dirs[@]} -eq 0 ]]; then
        log_error "監視対象のキューディレクトリがありません"
        exit 1
    fi

    # inotifywait でファイル作成を監視
    inotifywait -m -e create -e moved_to --format '%w%f' "${watch_dirs[@]}" 2>/dev/null | while read filepath; do
        if [[ "$filepath" == *.yaml ]]; then
            # ディレクトリ名からキュー名を取得
            local queue_dir=$(dirname "$filepath")
            local queue_name=$(basename "$queue_dir")

            # 少し待ってファイルが完全に書き込まれるのを待つ
            sleep 0.5

            # statusがpendingか確認
            local status=$(grep -E '^status:' "$filepath" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')
            if [[ "$status" == "pending" ]]; then
                process_message "$filepath" "$queue_name"
                sed -i 's/^status: pending/status: processing/' "$filepath" 2>/dev/null || true
            fi
        fi
    done
}

# =============================================================================
# ヘルプ
# =============================================================================

show_help() {
    cat << 'EOF'
キュー監視スクリプト

使用方法:
  ./scripts/utils/queue_monitor.sh [オプション]

オプション:
  -s, --session <name>  tmux セッション名（必須）
  -i, --interval <sec>  ポーリング間隔（デフォルト: 10秒）
  --inotify             inotify モードを使用（利用可能な場合）
  -h, --help            このヘルプを表示

環境変数:
  IGNITE_TMUX_SESSION   tmux セッション名
  QUEUE_POLL_INTERVAL   ポーリング間隔（秒）
  WORKSPACE_DIR         ワークスペースディレクトリ

例:
  # tmux セッション指定で起動
  ./scripts/utils/queue_monitor.sh -s ignite-1234

  # inotify モードで起動
  ./scripts/utils/queue_monitor.sh -s ignite-1234 --inotify
EOF
}

# =============================================================================
# メイン
# =============================================================================

main() {
    local use_inotify=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -s|--session)
                TMUX_SESSION="$2"
                shift 2
                ;;
            -i|--interval)
                POLL_INTERVAL="$2"
                shift 2
                ;;
            --inotify)
                use_inotify=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "不明なオプション: $1"
                show_help
                exit 1
                ;;
        esac
    done

    if [[ -z "$TMUX_SESSION" ]]; then
        log_error "tmux セッション名が指定されていません"
        echo "  -s または --session オプションで指定してください"
        echo "  または IGNITE_TMUX_SESSION 環境変数を設定してください"
        exit 1
    fi

    # tmux セッションの存在確認
    if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        log_error "tmux セッションが見つかりません: $TMUX_SESSION"
        exit 1
    fi

    log_info "tmux セッション: $TMUX_SESSION"

    if [[ "$use_inotify" == true ]]; then
        monitor_with_inotify
    else
        monitor_queues
    fi
}

main "$@"

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

# =============================================================================
# 関数名: send_to_agent
# 目的: 指定されたエージェントのtmuxペインにメッセージを送信する
# 引数:
#   $1 - エージェント名（例: "leader", "strategist", "ignitian-1"）
#   $2 - 送信するメッセージ文字列
# 戻り値: 0=成功, 1=失敗
# 注意:
#   - TMUX_SESSION 環境変数が設定されている必要がある
#   - ペインインデックスはIGNITEの固定レイアウトに基づく
# =============================================================================
send_to_agent() {
    local agent="$1"
    local message="$2"
    local pane_index

    if [[ -z "$TMUX_SESSION" ]]; then
        log_error "TMUX_SESSION が設定されていません"
        return 1
    fi

    # =========================================================================
    # ペインインデックス計算ロジック
    # =========================================================================
    # IGNITEのtmuxレイアウト:
    #   ペイン 0: Leader (伊羽ユイ)
    #   ペイン 1: Strategist (義賀リオ)
    #   ペイン 2: Architect (祢音ナナ)
    #   ペイン 3: Evaluator (衣結ノア)
    #   ペイン 4: Coordinator (通瀬アイナ)
    #   ペイン 5: Innovator (恵那ツムギ)
    #   ペイン 6+: IGNITIANs (ワーカー)
    #
    # IGNITIANのペイン番号計算:
    #   ignitian-0 → ペイン 6 (0 + 6)
    #   ignitian-1 → ペイン 7 (1 + 6)
    #   ignitian-N → ペイン N+6
    # =========================================================================
    case "$agent" in
        leader) pane_index=0 ;;
        strategist) pane_index=1 ;;
        architect) pane_index=2 ;;
        evaluator) pane_index=3 ;;
        coordinator) pane_index=4 ;;
        innovator) pane_index=5 ;;
        *)
            # IGNITIAN の場合は名前からインデックスを推測
            # ignitian-N または ignitian_N 形式に対応
            if [[ "$agent" =~ ^ignitian[-_]([0-9]+)$ ]]; then
                local num=${BASH_REMATCH[1]}
                pane_index=$((num + 6))  # Sub-Leaders(6) + IGNITIAN番号
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

        # Sub-Leaders キュー
        scan_queue "$WORKSPACE_DIR/queue/strategist" "strategist"
        scan_queue "$WORKSPACE_DIR/queue/architect" "architect"
        scan_queue "$WORKSPACE_DIR/queue/evaluator" "evaluator"
        scan_queue "$WORKSPACE_DIR/queue/coordinator" "coordinator"
        scan_queue "$WORKSPACE_DIR/queue/innovator" "innovator"

        # IGNITIAN キュー（ignitians/ ディレクトリ方式）
        # ファイル名 ignitian_N.yaml または ignitian_N_xxx.yaml からIGNITIAN番号を抽出
        if [[ -d "$WORKSPACE_DIR/queue/ignitians" ]]; then
            for file in "$WORKSPACE_DIR/queue/ignitians"/ignitian_*.yaml; do
                [[ -f "$file" ]] || continue
                local filepath="$file"
                local filename=$(basename "$file")

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

                # ファイル名からIGNITIAN番号を抽出 (ignitian_N.yaml or ignitian_N_xxx.yaml)
                if [[ "$filename" =~ ^ignitian_([0-9]+) ]]; then
                    local ignitian_num=${BASH_REMATCH[1]}
                    process_message "$file" "ignitian_${ignitian_num}"
                    PROCESSED_FILES[$filepath]=1
                    sed -i 's/^status: pending/status: processing/' "$file" 2>/dev/null || true
                fi
            done
        fi

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
    [[ -d "$WORKSPACE_DIR/queue/architect" ]] && watch_dirs+=("$WORKSPACE_DIR/queue/architect")
    [[ -d "$WORKSPACE_DIR/queue/evaluator" ]] && watch_dirs+=("$WORKSPACE_DIR/queue/evaluator")
    [[ -d "$WORKSPACE_DIR/queue/coordinator" ]] && watch_dirs+=("$WORKSPACE_DIR/queue/coordinator")
    [[ -d "$WORKSPACE_DIR/queue/innovator" ]] && watch_dirs+=("$WORKSPACE_DIR/queue/innovator")
    # IGNITIAN キュー（ignitians/ ディレクトリ方式）
    [[ -d "$WORKSPACE_DIR/queue/ignitians" ]] && watch_dirs+=("$WORKSPACE_DIR/queue/ignitians")

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
            local filename=$(basename "$filepath")

            # ignitians/ ディレクトリの場合はファイル名からIGNITIAN番号を抽出
            if [[ "$queue_name" == "ignitians" ]]; then
                if [[ "$filename" =~ ^ignitian_([0-9]+) ]]; then
                    queue_name="ignitian_${BASH_REMATCH[1]}"
                else
                    continue  # IGNITIAN形式でないファイルはスキップ
                fi
            fi

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

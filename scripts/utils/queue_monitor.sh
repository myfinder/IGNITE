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

# ログ出力（すべて標準エラー出力に出力して、コマンド置換で混入しないようにする）
log_info() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${BLUE}[QUEUE]${NC} $1" >&2; }
log_success() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${GREEN}[QUEUE]${NC} $1" >&2; }
log_warn() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${YELLOW}[QUEUE]${NC} $1" >&2; }
log_error() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${RED}[QUEUE]${NC} $1" >&2; }

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
    # IGNITIANのペイン番号計算（IDは1始まり）:
    #   ignitian-1 → ペイン 6 (1 + 5)
    #   ignitian-2 → ペイン 7 (2 + 5)
    #   ignitian-N → ペイン N+5
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
                pane_index=$((num + 5))  # Sub-Leaders(0-5) + IGNITIAN番号(1始まり) = 5 + num
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
        local target="${TMUX_SESSION}:ignite.${pane_index}"

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

# PROCESSED_FILES のクリーンアップ（存在しないファイルのエントリを削除）
cleanup_processed_files() {
    local removed=0
    for filepath in "${!PROCESSED_FILES[@]}"; do
        if [[ ! -f "$filepath" ]]; then
            unset 'PROCESSED_FILES[$filepath]'
            ((removed++)) || true
        fi
    done
    if [[ $removed -gt 0 ]]; then
        log_info "PROCESSED_FILES クリーンアップ: ${removed}件削除（残: ${#PROCESSED_FILES[@]}件）"
    fi
}

# ファイル名を {type}_{timestamp}.yaml パターンに正規化
# 正規化が不要な場合はそのままのパスを返す
normalize_filename() {
    local file="$1"
    local filename=$(basename "$file")
    local dir=$(dirname "$file")

    # {任意の文字列}_{数字16桁}.yaml パターンに一致すれば正規化不要
    if [[ "$filename" =~ ^.+_[0-9]{16}\.yaml$ ]]; then
        echo "$file"
        return
    fi

    # YAMLから type と timestamp を読み取り
    local msg_type=$(grep -E '^type:' "$file" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')
    if [[ -z "$msg_type" ]]; then
        # type フィールドがない場合はファイル名からベスト・エフォートで推測
        msg_type="${filename%.yaml}"
    fi

    # YAML timestamp からエポックマイクロ秒を算出（元の時系列順を保持）
    local yaml_ts=$(grep -E '^timestamp:' "$file" 2>/dev/null | head -1 | sed 's/^timestamp: *"\?\([^"]*\)"\?/\1/')
    local epoch_usec=""
    if [[ -n "$yaml_ts" ]]; then
        local epoch_sec=$(date -d "$yaml_ts" +%s 2>/dev/null)
        if [[ -n "$epoch_sec" ]]; then
            # マイクロ秒部分はファイルのハッシュから生成（ユニーク性確保）
            local micro=$(echo "${file}${yaml_ts}" | md5sum | tr -dc '0-9' | head -c 6)
            epoch_usec="${epoch_sec}${micro}"
        fi
    fi
    # フォールバック: 現在時刻ベース
    if [[ -z "$epoch_usec" ]]; then
        epoch_usec=$(date +%s%6N)
    fi

    # 衝突回避: 同名ファイルが存在する場合は連番サフィックス
    local new_path="${dir}/${msg_type}_${epoch_usec}.yaml"
    if [[ -f "$new_path" ]]; then
        local suffix=1
        while [[ -f "${dir}/${msg_type}_${epoch_usec}_${suffix}.yaml" ]]; do
            ((suffix++))
        done
        new_path="${dir}/${msg_type}_${epoch_usec}_${suffix}.yaml"
    fi

    local from=$(grep -E '^from:' "$file" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')
    local to=$(grep -E '^to:' "$file" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')
    log_warn "ファイル名を正規化: ${filename} → $(basename "$new_path") (from: ${from:-unknown}, to: ${to:-unknown})"

    mv "$file" "$new_path" 2>/dev/null || { echo "$file"; return; }
    echo "$new_path"
}

scan_queue() {
    local queue_dir="$1"
    local queue_name="$2"

    if [[ ! -d "$queue_dir" ]]; then
        return
    fi

    # 新しいYAMLファイルを検索（processedディレクトリは除く）
    for file in "$queue_dir"/*.yaml; do
        [[ -f "$file" ]] || continue

        # ファイル名が {type}_{timestamp}.yaml パターンに一致しない場合は正規化
        file=$(normalize_filename "$file")
        [[ -f "$file" ]] || continue

        local filepath="$file"

        # 既に処理済みならスキップ
        if [[ -n "${PROCESSED_FILES[$filepath]:-}" ]]; then
            continue
        fi

        # statusを読み取り、挙動を分岐
        local status=$(grep -E '^status:' "$file" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')
        case "$status" in
            queued)
                # 正常 — そのまま処理
                ;;
            processing)
                # queue_monitor自身が設定した送信済みマーク — スキップ
                PROCESSED_FILES[$filepath]=1
                continue
                ;;
            *)
                # プロトコル違反 — 自動修正して処理
                local from=$(grep -E '^from:' "$file" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')
                local to=$(grep -E '^to:' "$file" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')
                log_warn "プロトコル違反を自動修正: $(basename "$file") (from: ${from:-unknown}, to: ${to:-unknown}) — status: '${status:-なし}' → 'queued' に修正"
                if grep -qE '^status:' "$file" 2>/dev/null; then
                    sed -i "s/^status:.*/status: queued/" "$file" 2>/dev/null || true
                else
                    echo "status: queued" >> "$file"
                fi
                ;;
        esac

        # 処理
        process_message "$file" "$queue_name"
        PROCESSED_FILES[$filepath]=1

        # statusをprocessingに更新
        sed -i 's/^status: queued/status: processing/' "$file" 2>/dev/null || true
    done
}

monitor_queues() {
    log_info "キュー監視を開始します（間隔: ${POLL_INTERVAL}秒）"
    local poll_count=0

    while true; do
        # Leader キュー
        scan_queue "$WORKSPACE_DIR/queue/leader" "leader"

        # Sub-Leaders キュー
        scan_queue "$WORKSPACE_DIR/queue/strategist" "strategist"
        scan_queue "$WORKSPACE_DIR/queue/architect" "architect"
        scan_queue "$WORKSPACE_DIR/queue/evaluator" "evaluator"
        scan_queue "$WORKSPACE_DIR/queue/coordinator" "coordinator"
        scan_queue "$WORKSPACE_DIR/queue/innovator" "innovator"

        # IGNITIAN キュー（個別ディレクトリ方式 - Sub-Leadersと同じパターン）
        for ignitian_dir in "$WORKSPACE_DIR/queue"/ignitian[_-]*; do
            [[ -d "$ignitian_dir" ]] || continue
            local dirname=$(basename "$ignitian_dir")
            scan_queue "$ignitian_dir" "$dirname"
        done

        # 定期的なメモリクリーンアップ（100ポーリングごと）
        ((poll_count++)) || true
        if (( poll_count % 100 == 0 )); then
            cleanup_processed_files
        fi

        sleep "$POLL_INTERVAL"
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
  -h, --help            このヘルプを表示

環境変数:
  IGNITE_TMUX_SESSION   tmux セッション名
  QUEUE_POLL_INTERVAL   ポーリング間隔（秒）
  WORKSPACE_DIR         ワークスペースディレクトリ

例:
  # tmux セッション指定で起動
  ./scripts/utils/queue_monitor.sh -s ignite-1234
EOF
}

# =============================================================================
# メイン
# =============================================================================

main() {
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

    monitor_queues
}

main "$@"

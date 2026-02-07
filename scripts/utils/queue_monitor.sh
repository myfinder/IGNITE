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
# 日次レポート連携
# =============================================================================

_get_report_cache_dir() {
    if [[ -n "${WORKSPACE_DIR:-}" ]]; then
        echo "$WORKSPACE_DIR/state"
    else
        echo "/tmp/ignite-token-cache"
    fi
}

_trigger_daily_report() {
    local repo="$1"
    local issue_num="${2:-}"
    local trigger="${3:-}"

    local daily_report_script="${SCRIPT_DIR}/daily_report.sh"
    if [[ ! -x "$daily_report_script" ]]; then
        return 0
    fi

    # Issue を確保（なければ作成）
    local report_issue
    report_issue=$(WORKSPACE_DIR="$WORKSPACE_DIR" "$daily_report_script" ensure --repo "$repo" 2>/dev/null) || {
        log_warn "日次レポート Issue の確保に失敗しました ($repo)"
        return 0
    }

    if [[ -z "$report_issue" ]]; then
        return 0
    fi

    # 作業開始コメントを追加
    local comment_body
    comment_body="### Task Started

- **Issue/PR:** #${issue_num}
- **Trigger:** ${trigger}
- **Time:** $(date '+%Y-%m-%d %H:%M:%S %Z')"

    WORKSPACE_DIR="$WORKSPACE_DIR" "$daily_report_script" comment \
        --repo "$repo" \
        --issue "$report_issue" \
        --body "$comment_body" 2>/dev/null || {
        log_warn "日次レポートへのコメント追加に失敗しました ($repo)"
    }
}

_report_progress() {
    local file="$1"

    local daily_report_script="${SCRIPT_DIR}/daily_report.sh"
    if [[ ! -x "$daily_report_script" ]]; then
        return 0
    fi

    # progress_update から情報を抽出
    local summary
    summary=$(grep -E '^\s+summary:' "$file" | head -1 | sed 's/^.*summary: *//; s/^"//; s/"$//')
    local tasks_completed
    tasks_completed=$(grep -E '^\s+tasks_completed:' "$file" | head -1 | awk '{print $2}')
    local tasks_total
    tasks_total=$(grep -E '^\s+tasks_total:' "$file" | head -1 | awk '{print $2}')
    local issue_id
    issue_id=$(grep -E '^\s+issue_id:' "$file" | head -1 | awk '{print $2}' | tr -d '"')

    # report_issues.json から当日の全リポジトリを取得してコメント
    local cache_dir
    cache_dir=$(_get_report_cache_dir)
    local cache_file="$cache_dir/report_issues.json"
    [[ -f "$cache_file" ]] || return 0

    local today
    today=$(date +%Y-%m-%d)

    local repos
    repos=$(jq -r --arg date "$today" 'to_entries[] | select(.value[$date] != null) | .key' "$cache_file" 2>/dev/null)
    [[ -n "$repos" ]] || return 0

    local comment_body
    comment_body="### Progress Update

- **Issue:** ${issue_id}
- **Tasks:** ${tasks_completed:-?}/${tasks_total:-?} completed
- **Summary:** ${summary:-N/A}
- **Time:** $(date '+%Y-%m-%d %H:%M:%S %Z')"

    while IFS= read -r repo; do
        [[ -z "$repo" ]] && continue
        local report_issue
        report_issue=$(jq -r --arg repo "$repo" --arg date "$today" '.[$repo][$date] // empty' "$cache_file" 2>/dev/null)
        [[ -n "$report_issue" ]] || continue

        WORKSPACE_DIR="$WORKSPACE_DIR" "$daily_report_script" comment \
            --repo "$repo" \
            --issue "$report_issue" \
            --body "$comment_body" 2>/dev/null || true
    done <<< "$repos"
}

_report_evaluation() {
    local file="$1"

    local daily_report_script="${SCRIPT_DIR}/daily_report.sh"
    if [[ ! -x "$daily_report_script" ]]; then
        return 0
    fi

    local issue_number
    issue_number=$(grep -E '^\s+issue_number:' "$file" | head -1 | awk '{print $2}' | tr -d '"')
    local verdict
    verdict=$(grep -E '^\s+verdict:' "$file" | head -1 | awk '{print $2}' | tr -d '"')
    local score
    score=$(grep -E '^\s+score:' "$file" | head -1 | awk '{print $2}' | tr -d '"')
    local title
    title=$(grep -E '^\s+title:' "$file" | head -1 | sed 's/^.*title: *//; s/^"//; s/"$//')

    local cache_dir
    cache_dir=$(_get_report_cache_dir)
    local cache_file="$cache_dir/report_issues.json"
    [[ -f "$cache_file" ]] || return 0

    local today
    today=$(date +%Y-%m-%d)

    local repos
    repos=$(jq -r --arg date "$today" 'to_entries[] | select(.value[$date] != null) | .key' "$cache_file" 2>/dev/null)
    [[ -n "$repos" ]] || return 0

    local verdict_emoji
    case "$verdict" in
        approve) verdict_emoji="✅" ;;
        reject|needs_revision) verdict_emoji="❌" ;;
        *) verdict_emoji="📋" ;;
    esac

    local comment_body
    comment_body="### Evaluation Result

- **Issue:** #${issue_number:-?}
- **Title:** ${title:-N/A}
- **Verdict:** ${verdict_emoji} ${verdict:-N/A}
- **Score:** ${score:-N/A}
- **Time:** $(date '+%Y-%m-%d %H:%M:%S %Z')"

    while IFS= read -r repo; do
        [[ -z "$repo" ]] && continue
        local report_issue
        report_issue=$(jq -r --arg repo "$repo" --arg date "$today" '.[$repo][$date] // empty' "$cache_file" 2>/dev/null)
        [[ -n "$report_issue" ]] || continue

        WORKSPACE_DIR="$WORKSPACE_DIR" "$daily_report_script" comment \
            --repo "$repo" \
            --issue "$report_issue" \
            --body "$comment_body" 2>/dev/null || true
    done <<< "$repos"
}

# =============================================================================
# メッセージ処理
# =============================================================================

process_message() {
    local file="$1"
    local queue_name="$2"

    # ファイル名から情報を取得
    local filename
    filename=$(basename "$file")

    # YAMLからタイプを読み取り
    local msg_type
    msg_type=$(grep -E '^type:' "$file" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')

    log_info "新規メッセージ検知: $filename (type: $msg_type)"

    # メッセージタイプに応じた処理指示を生成
    local instruction=""
    case "$msg_type" in
        github_task)
            local trigger
            trigger=$(grep -E '^\s*trigger:' "$file" | head -1 | awk '{print $2}' | tr -d '"')
            local repo
            repo=$(grep -E '^\s*repository:' "$file" | head -1 | awk '{print $2}' | tr -d '"')
            local issue_num
            issue_num=$(grep -E '^\s*issue_number:' "$file" | head -1 | awk '{print $2}' | tr -d '"')
            instruction="新しいGitHubタスクが来ました。$file を読んで処理してください。リポジトリ: $repo, Issue/PR: #$issue_num, トリガー: $trigger"
            # 日次レポートに作業開始を記録（バックグラウンド）
            if [[ -n "$repo" ]]; then
                _trigger_daily_report "$repo" "$issue_num" "$trigger" &
            fi
            ;;
        github_event)
            local event_type
            event_type=$(grep -E '^\s*event_type:' "$file" | head -1 | awk '{print $2}' | tr -d '"')
            instruction="新しいGitHubイベントが来ました。$file を読んで必要に応じて対応してください。イベントタイプ: $event_type"
            ;;
        progress_update)
            instruction="進捗報告が来ました。$file を読んで確認してください。"
            # 日次レポートに進捗を記録（バックグラウンド）
            _report_progress "$file" &
            ;;
        evaluation_result)
            local eval_verdict
            eval_verdict=$(grep -E '^\s+verdict:' "$file" | head -1 | awk '{print $2}' | tr -d '"')
            instruction="評価結果が来ました。$file を読んで確認してください。判定: $eval_verdict"
            # 日次レポートに評価結果を記録（バックグラウンド）
            _report_evaluation "$file" &
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

# ファイル名を {type}_{timestamp}.yaml パターンに正規化
# 正規化が不要な場合はそのままのパスを返す
normalize_filename() {
    local file="$1"
    local filename
    filename=$(basename "$file")
    local dir
    dir=$(dirname "$file")

    # {任意の文字列}_{数字16桁}.yaml パターンに一致すれば正規化不要
    if [[ "$filename" =~ ^.+_[0-9]{16}\.yaml$ ]]; then
        echo "$file"
        return
    fi

    # YAMLから type と timestamp を読み取り
    local msg_type
    msg_type=$(grep -E '^type:' "$file" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')
    if [[ -z "$msg_type" ]]; then
        # type フィールドがない場合はファイル名からベスト・エフォートで推測
        msg_type="${filename%.yaml}"
    fi

    # YAML timestamp からエポックマイクロ秒を算出（元の時系列順を保持）
    local yaml_ts
    yaml_ts=$(grep -E '^timestamp:' "$file" 2>/dev/null | head -1 | sed 's/^timestamp: *"\?\([^"]*\)"\?/\1/')
    local epoch_usec=""
    if [[ -n "$yaml_ts" ]]; then
        local epoch_sec
        epoch_sec=$(date -d "$yaml_ts" +%s 2>/dev/null)
        if [[ -n "$epoch_sec" ]]; then
            # マイクロ秒部分はファイルのハッシュから生成（ユニーク性確保）
            local micro
            micro=$(echo "${file}${yaml_ts}" | md5sum | tr -dc '0-9' | head -c 6)
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

    local from
    from=$(grep -E '^from:' "$file" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')
    local to
    to=$(grep -E '^to:' "$file" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')
    log_warn "ファイル名を正規化: ${filename} → $(basename "$new_path") (from: ${from:-unknown}, to: ${to:-unknown})"

    mv "$file" "$new_path" 2>/dev/null || { echo "$file"; return; }
    echo "$new_path"
}

scan_queue() {
    local queue_dir="$1"
    local queue_name="$2"

    [[ -d "$queue_dir" ]] || return

    # processed/ ディレクトリを確保（処理済みファイルの移動先）
    mkdir -p "$queue_dir/processed"

    # キューディレクトリ直下の .yaml ファイル = 未処理メッセージ
    for file in "$queue_dir"/*.yaml; do
        [[ -f "$file" ]] || continue

        # ファイル名が {type}_{timestamp}.yaml パターンに一致しない場合は正規化
        file=$(normalize_filename "$file")
        [[ -f "$file" ]] || continue

        local filename
        filename=$(basename "$file")
        local dest="$queue_dir/processed/$filename"

        # at-most-once 配信: 先に processed/ へ移動し、成功した場合のみ処理
        mv "$file" "$dest" 2>/dev/null || continue

        # 処理（processed/ 内のパスを渡す）
        process_message "$dest" "$queue_name"
    done
}

monitor_queues() {
    log_info "キュー監視を開始します（間隔: ${POLL_INTERVAL}秒）"

    while true; do
        # tmuxセッション生存チェック
        if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
            log_warn "tmux セッション '$TMUX_SESSION' が消滅しました。監視を終了します"
            exit 0
        fi

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
            local dirname
            dirname=$(basename "$ignitian_dir")
            scan_queue "$ignitian_dir" "$dirname"
        done

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

    # グレースフル停止用の trap
    trap 'log_info "シグナル受信: 停止します"; exit 0' SIGTERM SIGINT
    trap 'log_info "キュー監視を終了しました"' EXIT

    log_info "tmux セッション: $TMUX_SESSION"

    monitor_queues
}

main "$@"

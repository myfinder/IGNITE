# shellcheck shell=bash
# =============================================================================
# health_check.sh - 3層階層型ヘルスチェックライブラリ
# =============================================================================
# エージェントの状態を3層で判定し統合ステータスを返す。
#
# 提供関数:
#   check_layer1         - プロセス存在チェック (alive|missing|wrong_process)
#   check_layer2         - エージェント識別チェック (identified|unidentified)
#   check_layer3         - アクティビティチェック (active|idle|stale|starting)
#   classify_health      - 3層統合判定 (healthy|starting|idle|stale|crashed|missing)
#   check_agent_health   - 単一エージェント用ラッパー
#   get_all_agents_health - 全エージェント状態取得
#   format_health_status - ステータス文字列のカラー表示
#
# 使用方法:
#   source scripts/lib/health_check.sh
# =============================================================================

[[ -n "${__LIB_HEALTH_CHECK_LOADED:-}" ]] && return; __LIB_HEALTH_CHECK_LOADED=1

# 閾値定数
readonly IDLE_THRESHOLD=300   # 5分
readonly STALE_THRESHOLD=900  # 15分

# カラー定義（未定義時のみ設定）
: "${GREEN:=\033[0;32m}"
: "${YELLOW:=\033[1;33m}"
: "${RED:=\033[0;31m}"
: "${CYAN:=\033[0;36m}"
: "${NC:=\033[0m}"

# =============================================================================
# Layer 1: プロセス存在チェック
# =============================================================================

# check_layer1 <pane_pid> <pane_cmd>
# 戻り値(stdout): alive | missing | wrong_process
check_layer1() {
    local pane_pid="$1"
    local pane_cmd="$2"

    # PID存在確認
    if ! kill -0 "$pane_pid" 2>/dev/null; then
        echo "missing"
        return
    fi

    # プロセス種別判定
    case "$pane_cmd" in
        claude|node)
            echo "alive"
            ;;
        bash|zsh|sh)
            echo "alive"
            ;;
        *)
            echo "wrong_process"
            ;;
    esac
}

# =============================================================================
# Layer 2: エージェント識別チェック
# =============================================================================

# check_layer2 <session> <pane_index> <expected_name>
# 戻り値(stdout): identified | unidentified
check_layer2() {
    local session="$1"
    local pane_index="$2"
    local expected_name="$3"

    local agent_name
    agent_name=$(tmux show-options -t "${session}:${pane_index}" -v @agent_name 2>/dev/null || true)

    if [[ "$agent_name" == "$expected_name" ]]; then
        echo "identified"
    else
        echo "unidentified"
    fi
}

# =============================================================================
# Layer 3: アクティビティチェック
# =============================================================================

# check_layer3 <session> <pane_index> <pane_activity> <pane_created>
# 戻り値(stdout): active | idle | stale | starting
check_layer3() {
    local session="$1"
    local pane_index="$2"
    local pane_activity="$3"
    local pane_created="$4"

    local now
    now=$(date +%s)

    # starting判定: 作成30秒以内
    local age=$(( now - pane_created ))
    if [[ $age -le 30 ]]; then
        local output
        output=$(tmux capture-pane -t "${session}:${pane_index}" -p -S -5 2>/dev/null || true)
        if [[ -z "$output" ]] || ! echo "$output" | grep -qE '(起動完了|ready|initialized|started)'; then
            echo "starting"
            return
        fi
    fi

    # 最終アクティビティからの経過時間
    local last_activity="$pane_activity"

    # capture-paneで最後5行を取得し、活動を補完
    local captured
    captured=$(tmux capture-pane -t "${session}:${pane_index}" -p -S -5 2>/dev/null || true)
    if [[ -z "$captured" ]]; then
        # 出力が空の場合はpane_activityを使用
        :
    fi

    local elapsed=$(( now - last_activity ))

    if [[ $elapsed -lt $IDLE_THRESHOLD ]]; then
        echo "active"
    elif [[ $elapsed -lt $STALE_THRESHOLD ]]; then
        echo "idle"
    else
        echo "stale"
    fi
}

# =============================================================================
# 3層統合判定
# =============================================================================

# classify_health <layer1> <layer2> <layer3>
# 戻り値(stdout): healthy | starting | idle | stale | crashed | missing
classify_health() {
    local layer1="$1"
    local layer2="$2"
    local layer3="$3"

    # Layer 1 判定
    if [[ "$layer1" == "missing" ]]; then
        echo "missing"
        return
    fi

    if [[ "$layer1" == "wrong_process" ]]; then
        echo "crashed"
        return
    fi

    # Layer 3 ステータス（Layer 1 = alive）
    case "$layer3" in
        starting)
            echo "starting"
            ;;
        active)
            if [[ "$layer2" == "identified" ]]; then
                echo "healthy"
            else
                echo "starting"
            fi
            ;;
        idle)
            echo "idle"
            ;;
        stale)
            echo "stale"
            ;;
        *)
            echo "stale"
            ;;
    esac
}

# =============================================================================
# 単一エージェント用ラッパー
# =============================================================================

# check_agent_health <session> <pane_index> <expected_name>
# 戻り値(stdout): health_status
check_agent_health() {
    local session="$1"
    local pane_index="$2"
    local expected_name="$3"

    # tmux list-panes でペイン情報を取得
    local pane_info
    pane_info=$(tmux list-panes -t "${session}" \
        -F '#{pane_index} #{pane_pid} #{pane_current_command} #{pane_activity} #{pane_start_time}' \
        2>/dev/null | awk -v idx="$pane_index" '$1 == idx {print}')

    if [[ -z "$pane_info" ]]; then
        echo "missing"
        return
    fi

    local _idx _pid _cmd _activity _created
    read -r _idx _pid _cmd _activity _created <<< "$pane_info"

    local l1 l2 l3
    l1=$(check_layer1 "$_pid" "$_cmd")
    l2=$(check_layer2 "$session" "$pane_index" "$expected_name")
    l3=$(check_layer3 "$session" "$pane_index" "$_activity" "$_created")

    classify_health "$l1" "$l2" "$l3"
}

# =============================================================================
# 全エージェント状態取得
# =============================================================================

# get_all_agents_health <session>
# 戻り値(stdout): "pane_index:agent_name:status" 形式を1行ずつ出力
get_all_agents_health() {
    local session="$1"

    # 方式C: tmux list-panes 一括取得 + ループ判定
    local pane_data
    pane_data=$(tmux list-panes -t "${session}" \
        -F '#{pane_index} #{pane_pid} #{pane_current_command} #{pane_activity} #{pane_start_time}' \
        2>/dev/null || true)

    if [[ -z "$pane_data" ]]; then
        return
    fi

    while IFS= read -r line; do
        local idx pid cmd activity created
        read -r idx pid cmd activity created <<< "$line"

        # @agent_name を取得
        local agent_name
        agent_name=$(tmux show-options -t "${session}:${idx}" -v @agent_name 2>/dev/null || echo "unknown")
        [[ -z "$agent_name" ]] && agent_name="unknown"

        local l1 l2 l3 status
        l1=$(check_layer1 "$pid" "$cmd")
        l2=$(check_layer2 "$session" "$idx" "$agent_name")
        l3=$(check_layer3 "$session" "$idx" "$activity" "$created")
        status=$(classify_health "$l1" "$l2" "$l3")

        echo "${idx}:${agent_name}:${status}"
    done <<< "$pane_data"
}

# =============================================================================
# ステータスカラー表示
# =============================================================================

# format_health_status <status>
# 戻り値(stdout): カラー付きステータス文字列
format_health_status() {
    local status="$1"

    case "$status" in
        healthy)
            echo -e "${GREEN}✓ healthy${NC}"
            ;;
        starting)
            echo -e "${YELLOW}⟳ starting${NC}"
            ;;
        idle)
            echo -e "${CYAN}⏸ idle${NC}"
            ;;
        stale)
            echo -e "${YELLOW}⚠ stale${NC}"
            ;;
        crashed)
            echo -e "${RED}✗ crashed${NC}"
            ;;
        missing)
            echo -e "${RED}✗ missing${NC}"
            ;;
        *)
            echo -e "? ${status}"
            ;;
    esac
}

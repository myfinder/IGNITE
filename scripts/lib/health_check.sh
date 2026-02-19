# shellcheck shell=bash
# =============================================================================
# health_check.sh - ヘルスチェックライブラリ（ヘッドレス専用）
# =============================================================================
# エージェントの状態をセッション ID ファイルで判定する。
#
# 提供関数:
#   check_agent_health   - 単一エージェント用ヘルスチェック
#   get_all_agents_health - 全エージェント状態取得
#   format_health_status - ステータス文字列のカラー表示
#   get_agents_health_json - JSON エクスポート
#
# 使用方法:
#   source scripts/lib/health_check.sh
# =============================================================================

[[ -n "${__LIB_HEALTH_CHECK_LOADED:-}" ]] && return; __LIB_HEALTH_CHECK_LOADED=1

# =============================================================================
# 単一エージェント用ヘルスチェック
# =============================================================================

# check_agent_health <session> <pane_index> <expected_name>
# 戻り値(stdout): health_status
check_agent_health() {
    local session="$1"
    local pane_index="$2"
    local expected_name="$3"

    local state_dir="$IGNITE_RUNTIME_DIR/state"

    # 統一ロジック: セッション ID ファイルの存在で判定
    local session_id
    session_id=$(cat "${state_dir}/.agent_session_${pane_index}" 2>/dev/null || true)
    if [[ -z "$session_id" ]]; then
        echo "missing"
        return
    fi

    # PID ファイルがあればプロセス生存チェック（init 失敗検出）
    local pid_file="${state_dir}/.agent_pid_${pane_index}"
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null || true)
        if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
            echo "stale"
            return
        fi
    fi

    local agent_name
    agent_name=$(cat "${state_dir}/.agent_name_${pane_index}" 2>/dev/null || true)
    if [[ -n "$agent_name" ]]; then
        echo "healthy"
    else
        echo "starting"
    fi
}

# =============================================================================
# 全エージェント状態取得
# =============================================================================

# get_all_agents_health <session>
# 戻り値(stdout): "pane_index:agent_name:status" 形式を1行ずつ出力
get_all_agents_health() {
    local session="$1"

    local state_dir="$IGNITE_RUNTIME_DIR/state"
    for session_file in "$state_dir"/.agent_session_*; do
        [[ -f "$session_file" ]] || continue
        local idx
        idx=$(basename "$session_file" | sed 's/^\.agent_session_//')
        local agent_name
        agent_name=$(cat "${state_dir}/.agent_name_${idx}" 2>/dev/null || echo "unknown")
        [[ -z "$agent_name" ]] && agent_name="unknown"

        local status
        status=$(check_agent_health "$session" "$idx" "$agent_name")
        echo "${idx}:${agent_name}:${status}"
    done
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

# =============================================================================
# JSONエクスポート
# =============================================================================

# get_agents_health_json <session>
# 戻り値(stdout): エージェント状態JSON配列
get_agents_health_json() {
    local session="$1"
    local lines
    lines=$(get_all_agents_health "$session" 2>/dev/null || true)
    if [[ -z "$lines" ]]; then
        echo "[]"
        return
    fi

    HEALTH_LINES="$lines" python3 - <<'PY'
import json
import os

agents = []
data = os.environ.get("HEALTH_LINES", "")
for raw in data.splitlines():
    line = raw.strip()
    if not line:
        continue
    parts = line.split(':', 2)
    if len(parts) != 3:
        continue
    pane, name, status = parts
    try:
        pane_id = int(pane)
    except ValueError:
        pane_id = None
    agents.append({"pane": pane_id, "name": name, "status": status})

print(json.dumps(agents, ensure_ascii=False))
PY
}

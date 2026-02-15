#!/bin/bash
# Memory Context 取得ツール
# チームメモリを3層フィルタリングで取得し、YAML block scalar形式で出力する。
# task_assignment の team_memory_context フィールドに埋め込み可能。
#
# 使用方法:
#   ./scripts/utils/memory_context.sh --repo OWNER/REPO [options]
#
# オプション:
#   --repo OWNER/REPO     対象リポジトリ（必須）
#   --issue NUMBER        Issue番号（任意）
#   --task-id TASK_ID     タスクID（任意、Layer 0 用）
#   --max-chars NUMBER    総出力文字数上限（デフォルト: 4000）
#   --content-limit NUMBER  各メモリのcontent切り詰め文字数（デフォルト: 300）

set -e
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/core.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${WORKSPACE_DIR:-}" ]] && setup_workspace_config "$WORKSPACE_DIR"

# =============================================================================
# データベースパス解決
# =============================================================================

_get_db_path() {
    if [[ -n "${WORKSPACE_DIR:-}" ]]; then
        echo "$IGNITE_RUNTIME_DIR/state/memory.db"
    elif [[ -n "${IGNITE_WORKSPACE_DIR:-}" ]]; then
        echo "$IGNITE_WORKSPACE_DIR/.ignite/state/memory.db"
    else
        log_error "WORKSPACE_DIR または IGNITE_WORKSPACE_DIR が未設定です"
        return 1
    fi
}

# =============================================================================
# 入力バリデーション
# =============================================================================

_validate_repo() {
    local repo="$1"
    if [[ ! "$repo" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
        log_error "無効なリポジトリ形式です: $repo（owner/repo 形式で指定してください）"
        return 1
    fi
}

_validate_positive_int() {
    local val="$1"
    local name="$2"
    if [[ ! "$val" =~ ^[1-9][0-9]*$ ]]; then
        log_error "無効な値です: $name=$val（正の整数で指定してください）"
        return 1
    fi
}

# =============================================================================
# YAML エスケープ
# =============================================================================

_yaml_escape() {
    local text="$1"
    # YAML block scalar 内で問題になる文字を処理
    # ダブルクォート内に埋め込むため、バックスラッシュとダブルクォートをエスケープ
    text="${text//\\/\\\\}"
    text="${text//\"/\\\"}"
    # 改行をスペースに置換（1行に収める）
    text="${text//$'\n'/ }"
    echo "$text"
}

# =============================================================================
# Layer クエリ実行
# =============================================================================

_query_layer() {
    local db_path="$1"
    local layer_name="$2"
    local where_clause="$3"
    local limit="$4"
    local content_limit="$5"

    local result
    result=$(sqlite3 "$db_path" 2>/dev/null <<ENDSQL
.timeout 5000
SELECT agent, type, SUBSTR(content, 1, ${content_limit}) as content, task_id, timestamp
FROM (
    SELECT agent, type, content, task_id, timestamp,
           ROW_NUMBER() OVER (PARTITION BY agent, content ORDER BY timestamp DESC) as rn
    FROM memories
    WHERE ${where_clause}
)
WHERE rn = 1
ORDER BY timestamp DESC
LIMIT ${limit};
ENDSQL
    ) || true

    echo "$result"
}

# =============================================================================
# YAML 出力生成
# =============================================================================

_format_layer_yaml() {
    local layer_label="$1"
    local query_result="$2"
    local indent="$3"

    echo "${indent}${layer_label}:"

    if [[ -z "$query_result" ]]; then
        echo "${indent}  []"
        return
    fi

    while IFS='|' read -r agent type content task_id timestamp; do
        local safe_content
        safe_content=$(_yaml_escape "$content")
        echo "${indent}  - agent: \"${agent}\""
        echo "${indent}    type: \"${type}\""
        echo "${indent}    content: \"${safe_content}\""
        if [[ -n "$task_id" ]]; then
            echo "${indent}    task_id: \"${task_id}\""
        fi
        echo "${indent}    timestamp: \"${timestamp}\""
    done <<< "$query_result"
}

# =============================================================================
# メイン処理
# =============================================================================

main() {
    local repo=""
    local issue=""
    local task_id=""
    local max_chars=4000
    local content_limit=300

    # 引数パース
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo) repo="$2"; shift 2 ;;
            --issue) issue="$2"; shift 2 ;;
            --task-id) task_id="$2"; shift 2 ;;
            --max-chars) max_chars="$2"; shift 2 ;;
            --content-limit) content_limit="$2"; shift 2 ;;
            -h|--help) show_help; exit 0 ;;
            *)
                log_error "不明なオプション: $1"
                show_help
                exit 1
                ;;
        esac
    done

    # バリデーション: --repo 必須
    if [[ -z "$repo" ]]; then
        log_error "--repo は必須です"
        show_help
        exit 1
    fi
    _validate_repo "$repo" || exit 1

    if [[ -n "$issue" ]]; then
        _validate_positive_int "$issue" "--issue" || exit 1
    fi
    _validate_positive_int "$max_chars" "--max-chars" || exit 1
    _validate_positive_int "$content_limit" "--content-limit" || exit 1

    # DB パス解決
    local db_path
    db_path=$(_get_db_path) || exit 1

    if [[ ! -f "$db_path" ]]; then
        log_error "データベースが見つかりません: $db_path"
        exit 1
    fi

    # SQL injection 対策: リポジトリ名のシングルクォートをエスケープ
    local safe_repo="${repo//\'/\'\'}"

    # Layer 0: 同一 task_id の全エージェントメモリ（最大5件）
    local layer0_result=""
    if [[ -n "$task_id" ]]; then
        local safe_task_id="${task_id//\'/\'\'}"
        layer0_result=$(_query_layer "$db_path" "layer_0" \
            "task_id = '${safe_task_id}' AND type NOT IN ('message_sent', 'message_received')" \
            5 "$content_limit")
    fi

    # Layer 1: 同一 repository + issue_number の全エージェントメモリ（最大15件）
    local layer1_result=""
    if [[ -n "$issue" ]]; then
        layer1_result=$(_query_layer "$db_path" "layer_1" \
            "repository = '${safe_repo}' AND issue_number = ${issue} AND type NOT IN ('message_sent', 'message_received')" \
            15 "$content_limit")
    fi

    # Layer 2: 同一 repository 別 issue のメモリ（最大5件）
    local layer2_where="repository = '${safe_repo}' AND type IN ('decision', 'learning', 'error', 'observation')"
    if [[ -n "$issue" ]]; then
        layer2_where="${layer2_where} AND (issue_number != ${issue} OR issue_number IS NULL)"
    fi
    local layer2_result
    layer2_result=$(_query_layer "$db_path" "layer_2" \
        "$layer2_where" \
        5 "$content_limit")

    # YAML 出力生成
    local output=""
    output+="team_memory_context:"$'\n'
    output+=$(_format_layer_yaml "layer_0" "$layer0_result" "  ")$'\n'
    output+=$(_format_layer_yaml "layer_1" "$layer1_result" "  ")$'\n'
    output+=$(_format_layer_yaml "layer_2" "$layer2_result" "  ")

    # 総出力文字数制限
    if [[ ${#output} -gt $max_chars ]]; then
        output="${output:0:$max_chars}"
        # 最後の不完全行を除去
        output="${output%$'\n'*}"
        output+=$'\n'"  # ... truncated (max_chars=${max_chars})"
        log_warn "出力が ${max_chars} 文字を超えたため切り詰めました"
    fi

    echo "$output"
}

# =============================================================================
# ヘルプ
# =============================================================================

show_help() {
    cat << 'EOF'
Memory Context 取得ツール

使用方法:
  memory_context.sh --repo OWNER/REPO [options]

オプション:
  --repo OWNER/REPO       対象リポジトリ（必須）
  --issue NUMBER          Issue番号（任意）
  --task-id TASK_ID       タスクID（任意、Layer 0 用）
  --max-chars NUMBER      総出力文字数上限（デフォルト: 4000）
  --content-limit NUMBER  各メモリのcontent切り詰め文字数（デフォルト: 300）
  -h, --help              ヘルプ表示

3層フィルタリング:
  Layer 0: 同一task_idの全エージェントメモリ（前任者/差し戻し対応）最大5件
  Layer 1: 同一repository + issue_numberの全エージェントメモリ 最大15件
  Layer 2: 同一repository別issueのメモリ（decision/learning/error/observation）最大5件

出力形式: YAML block scalar（task_assignment埋め込み可能）

使用例:
  # リポジトリ + Issue指定
  memory_context.sh --repo myfinder/IGNITE --issue 210

  # タスクID指定（Layer 0 有効化）
  memory_context.sh --repo myfinder/IGNITE --issue 210 --task-id task_003

  # 出力制限カスタマイズ
  memory_context.sh --repo myfinder/IGNITE --issue 210 --max-chars 2000 --content-limit 150
EOF
}

main "$@"

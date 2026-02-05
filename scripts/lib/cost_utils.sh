# shellcheck shell=bash
# lib/cost_utils.sh - コスト計算ユーティリティ
# PRICE_INPUT, PRICE_OUTPUT 等は load_pricing() で値が設定される

[[ -n "${__LIB_COST_UTILS_LOADED:-}" ]] && return; __LIB_COST_UTILS_LOADED=1

# =============================================================================
# 料金設定
# =============================================================================

load_pricing() {
    local pricing_file="$IGNITE_CONFIG_DIR/pricing.yaml"
    if [[ ! -f "$pricing_file" ]]; then
        print_error "料金設定ファイルが見つかりません: $pricing_file"
        return 1
    fi

    # デフォルトモデルの料金を取得
    PRICE_INPUT=$(grep -A5 "claude-opus-4-5-20251101:" "$pricing_file" | grep "input_per_1m_tokens:" | awk '{print $2}')
    PRICE_OUTPUT=$(grep -A5 "claude-opus-4-5-20251101:" "$pricing_file" | grep "output_per_1m_tokens:" | awk '{print $2}')
    PRICE_CACHE_READ=$(grep -A5 "claude-opus-4-5-20251101:" "$pricing_file" | grep "cache_read_per_1m_tokens:" | awk '{print $2}')
    PRICE_CACHE_CREATE=$(grep -A5 "claude-opus-4-5-20251101:" "$pricing_file" | grep "cache_creation_per_1m_tokens:" | awk '{print $2}')
    EXCHANGE_RATE=$(grep "exchange_rate_jpy:" "$pricing_file" | awk '{print $2}')

    # デフォルト値 (Claude Opus 4.5)
    PRICE_INPUT=${PRICE_INPUT:-5.00}
    PRICE_OUTPUT=${PRICE_OUTPUT:-25.00}
    PRICE_CACHE_READ=${PRICE_CACHE_READ:-0.50}
    PRICE_CACHE_CREATE=${PRICE_CACHE_CREATE:-6.25}
    EXCHANGE_RATE=${EXCHANGE_RATE:-150.0}
}

# =============================================================================
# トークン集計
# =============================================================================

# セッションIDからトークン使用量を集計
collect_session_tokens() {
    local session_id="$1"
    local session_file="$CLAUDE_PROJECTS_DIR/${session_id}.jsonl"
    local session_dir="$CLAUDE_PROJECTS_DIR/${session_id}"

    # 集計対象ファイル
    local files=()
    if [[ -f "$session_file" ]]; then
        files+=("$session_file")
    fi
    # サブエージェントのファイルも含める
    if [[ -d "$session_dir/subagents" ]]; then
        while IFS= read -r -d '' f; do
            files+=("$f")
        done < <(find "$session_dir/subagents" -name "*.jsonl" -print0 2>/dev/null)
    fi

    if [[ ${#files[@]} -eq 0 ]]; then
        echo '{"input":0,"output":0,"cache_read":0,"cache_creation":0}'
        return
    fi

    # jqで集計
    cat "${files[@]}" 2>/dev/null | jq -s '
      [.[] | select(.type == "assistant" and .message.usage != null) | .message.usage]
      | {
          input: (map(.input_tokens // 0) | add // 0),
          output: (map(.output_tokens // 0) | add // 0),
          cache_read: (map(.cache_read_input_tokens // 0) | add // 0),
          cache_creation: (map(.cache_creation_input_tokens // 0) | add // 0)
        }
    '
}

# =============================================================================
# フォーマットユーティリティ
# =============================================================================

# トークン数を人間が読みやすい形式に変換
format_tokens() {
    local tokens="$1"
    if [[ "$tokens" -ge 1000000 ]]; then
        printf "%.1fM" "$(echo "scale=1; $tokens / 1000000" | bc)"
    elif [[ "$tokens" -ge 1000 ]]; then
        printf "%.1fK" "$(echo "scale=1; $tokens / 1000" | bc)"
    else
        echo "$tokens"
    fi
}

# トークン数をカンマ区切りでフォーマット
format_number() {
    local num="$1"
    printf "%'d" "$num" 2>/dev/null || echo "$num"
}

# 文字列の表示幅を計算（全角文字=2, 半角文字=1）
get_display_width() {
    local str="$1"
    # wc -L はターミナルの表示幅を正しく計算する（ヒアストリングで渡す）
    local width
    width=$(wc -L <<< "$str")
    echo "$width"
}

# 指定した表示幅になるよう右パディング
pad_right() {
    local str="$1"
    local target_width="$2"
    local current_width
    current_width=$(get_display_width "$str")
    local padding
    padding=$((target_width - current_width))
    if [[ $padding -lt 0 ]]; then padding=0; fi
    printf "%s%*s" "$str" "$padding" ""
}

# 指定した表示幅になるよう左パディング（右寄せ）
pad_left() {
    local str="$1"
    local target_width="$2"
    local current_width
    current_width=$(get_display_width "$str")
    local padding
    padding=$((target_width - current_width))
    if [[ $padding -lt 0 ]]; then padding=0; fi
    printf "%*s%s" "$padding" "" "$str"
}

# =============================================================================
# コスト計算
# =============================================================================

# コストを計算（ドル）
calculate_cost() {
    local input="$1"
    local output="$2"
    local cache_read="$3"
    local cache_creation="$4"

    # 百万トークンあたりの価格で計算
    echo "scale=4; ($input * $PRICE_INPUT / 1000000) + ($output * $PRICE_OUTPUT / 1000000) + ($cache_read * $PRICE_CACHE_READ / 1000000) + ($cache_creation * $PRICE_CACHE_CREATE / 1000000)" | bc
}

# =============================================================================
# セッション解決
# =============================================================================

# sessions-index.json から起動時刻以降のセッションを検索
find_sessions_after_time() {
    local after_time="$1"  # ISO 8601 形式
    local sessions_index="$CLAUDE_PROJECTS_DIR/sessions-index.json"

    if [[ ! -f "$sessions_index" ]]; then
        return 1
    fi

    jq -r --arg after "$after_time" '
      .entries[]
      | select(.created >= $after)
      | .sessionId
    ' "$sessions_index"
}

# エージェント役割からsessions-index.jsonを検索してセッションIDを解決
resolve_agent_session_id() {
    local agent_role="$1"
    local started_at="$2"
    local sessions_index="$CLAUDE_PROJECTS_DIR/sessions-index.json"

    [[ ! -f "$sessions_index" ]] && return 1

    local pattern=""
    case "$agent_role" in
        leader|strategist|architect|evaluator|coordinator|innovator)
            # セッション履歴内で指示ファイルのパターンを検索
            pattern="${agent_role}\\.md.*として振る舞って"
            ;;
        ignitian_*)
            local num="${agent_role#ignitian_}"
            pattern="IGNITIAN-${num}"
            ;;
        *) return 1 ;;
    esac

    # まずsessions-index.jsonから検索
    local session_id
    session_id=$(jq -r --arg after "$started_at" --arg pattern "$pattern" '
      .entries
      | map(select(.created >= $after and (.firstPrompt | test($pattern))))
      | sort_by(.created) | last | .sessionId // empty
    ' "$sessions_index" 2>/dev/null)

    if [[ -n "$session_id" ]]; then
        echo "$session_id"
        return 0
    fi

    # インデックスに見つからない場合、セッションファイルを直接検索
    local project_dir
    project_dir=$(dirname "$sessions_index")
    for f in "$project_dir"/*.jsonl; do
        [[ -f "$f" ]] || continue
        # ファイルの更新時刻が開始時刻より後かチェック
        local file_mtime
        file_mtime=$(stat -c %Y "$f" 2>/dev/null)
        local start_epoch
        start_epoch=$(date -d "$started_at" +%s 2>/dev/null)
        [[ -z "$file_mtime" ]] || [[ -z "$start_epoch" ]] && continue
        [[ $file_mtime -lt $start_epoch ]] && continue

        # firstPromptにパターンが含まれるか確認
        if head -5 "$f" 2>/dev/null | grep -q "$pattern"; then
            basename "$f" .jsonl
            return 0
        fi
    done
}

# sessions.yamlのsession_idがnullのエージェントを自動解決
update_sessions_yaml() {
    local sessions_file="$WORKSPACE_DIR/costs/sessions.yaml"

    [[ ! -f "$sessions_file" ]] && return 1

    local started_at
    started_at=$(grep "^started_at:" "$sessions_file" | awk '{print $2}' | tr -d '"')
    [[ -z "$started_at" ]] && return 1

    # ISO 8601形式の開始時刻をUTCに変換（sessions-index.jsonはUTC）
    # エージェント起動はsessions.yamlのstarted_atより前に行われるため、3分前からを検索対象とする
    local started_utc
    started_utc=$(date -u -d "$started_at - 3 minutes" +"%Y-%m-%dT%H:%M:%S" 2>/dev/null)
    [[ -z "$started_utc" ]] && return 1

    local updated=false

    # Sub-Leaders のセッションID解決
    for role in leader strategist architect evaluator coordinator innovator; do
        local current_id
        current_id=$(grep -A5 "^  ${role}:" "$sessions_file" 2>/dev/null | grep "session_id:" | head -1 | awk '{print $2}' | tr -d '"')
        if [[ -z "$current_id" ]] || [[ "$current_id" == "null" ]]; then
            local resolved_id
            resolved_id=$(resolve_agent_session_id "$role" "$started_utc")
            if [[ -n "$resolved_id" ]]; then
                sed -i "/^  ${role}:/,/session_id:/{s/session_id: null/session_id: \"$resolved_id\"/}" "$sessions_file"
                updated=true
            fi
        fi
    done

    # IGNITIANs のセッションID解決
    for i in 1 2 3 4 5 6; do
        local role="ignitian_$i"
        if grep -q "^  ${role}:" "$sessions_file"; then
            local current_id
            current_id=$(grep -A3 "^  ${role}:" "$sessions_file" 2>/dev/null | grep "session_id:" | head -1 | awk '{print $2}' | tr -d '"')
            if [[ -z "$current_id" ]] || [[ "$current_id" == "null" ]]; then
                local resolved_id
                resolved_id=$(resolve_agent_session_id "$role" "$started_utc")
                if [[ -n "$resolved_id" ]]; then
                    sed -i "/^  ${role}:/,/session_id:/{s/session_id: null/session_id: \"$resolved_id\"/}" "$sessions_file"
                    updated=true
                fi
            fi
        fi
    done

    [[ "$updated" == true ]]
}

# エージェント名からセッションIDを取得
get_agent_session_id() {
    local agent_role="$1"
    local sessions_file="$WORKSPACE_DIR/costs/sessions.yaml"

    if [[ ! -f "$sessions_file" ]]; then
        return 1
    fi

    # session_id は role: の後 4行以内にある
    grep -A5 "^  ${agent_role}:" "$sessions_file" 2>/dev/null | grep "session_id:" | head -1 | awk '{print $2}' | tr -d '"'
}

# =============================================================================
# コスト履歴
# =============================================================================

# コスト一覧を表示（セッション履歴）
list_cost_sessions() {
    local history_dir="$WORKSPACE_DIR/costs/history"

    print_header "コスト履歴一覧"
    echo ""

    if [[ ! -d "$history_dir" ]] || [[ -z "$(ls -A "$history_dir" 2>/dev/null)" ]]; then
        print_warning "履歴がありません"
        echo ""
        echo "現在のセッションのコストを確認するには:"
        echo -e "  ${YELLOW}./scripts/ignite cost${NC}"
        return
    fi

    echo "セッション名              開始日時              合計費用"
    echo "────────────────────────────────────────────────────────"

    for file in "$history_dir"/*.yaml; do
        if [[ -f "$file" ]]; then
            local name
            name=$(grep "^session_name:" "$file" | awk '{print $2}' | tr -d '"')
            local started
            started=$(grep "^started_at:" "$file" | awk '{print $2}' | tr -d '"' | cut -d'T' -f1,2 | tr 'T' ' ')
            local cost
            cost=$(grep -A3 "^total:" "$file" | grep "cost_usd:" | awk '{print $2}')
            printf "%-24s %-20s \$%.2f\n" "$name" "$started" "$cost"
        fi
    done

    echo ""
    echo "詳細を表示:"
    echo -e "  ${YELLOW}./scripts/ignite cost -s <session-name>${NC}"
}

# コスト履歴を保存する関数
save_cost_history() {
    local sessions_file="$WORKSPACE_DIR/costs/sessions.yaml"

    if [[ ! -f "$sessions_file" ]]; then
        print_warning "セッション情報が見つかりません。コスト履歴はスキップします。"
        return
    fi

    print_info "コスト履歴を保存中..."

    # 料金設定を読み込む
    load_pricing || return

    local session_name
    session_name=$(grep "^session_name:" "$sessions_file" | awk '{print $2}' | tr -d '"')
    local started_at
    started_at=$(grep "^started_at:" "$sessions_file" | awk '{print $2}' | tr -d '"')
    local stopped_at
    stopped_at=$(date -Iseconds)
    local date_suffix
    date_suffix=$(date +%Y-%m-%d)

    local history_file="$WORKSPACE_DIR/costs/history/${session_name}_${date_suffix}.yaml"
    mkdir -p "$WORKSPACE_DIR/costs/history"

    # エージェント定義
    local -a agents=("leader" "strategist" "architect" "evaluator" "coordinator" "innovator")

    # 履歴ファイルの作成開始
    cat > "$history_file" <<EOF
# IGNITE コスト履歴
# 自動生成: $(date -Iseconds)

session_name: "${session_name}"
started_at: "${started_at}"
stopped_at: "${stopped_at}"

agents:
EOF

    local total_input=0
    local total_output=0
    local total_cost=0

    # 各エージェントのコストを記録
    for role in "${agents[@]}"; do
        local session_id
        session_id=$(get_agent_session_id "$role")
        if [[ -n "$session_id" ]] && [[ "$session_id" != "null" ]]; then
            local tokens
            tokens=$(collect_session_tokens "$session_id")
            local input
            input=$(echo "$tokens" | jq -r '.input')
            local output
            output=$(echo "$tokens" | jq -r '.output')
            local cache_read
            cache_read=$(echo "$tokens" | jq -r '.cache_read')
            local cache_creation
            cache_creation=$(echo "$tokens" | jq -r '.cache_creation')
            local cost
            cost=$(calculate_cost "$input" "$output" "$cache_read" "$cache_creation")

            cat >> "$history_file" <<EOF
  ${role}:
    session_id: "${session_id}"
    input_tokens: ${input}
    output_tokens: ${output}
    cache_read_tokens: ${cache_read}
    cache_creation_tokens: ${cache_creation}
    cost_usd: ${cost}
EOF

            total_input=$((total_input + input))
            total_output=$((total_output + output))
            total_cost=$(echo "$total_cost + $cost" | bc)
        fi
    done

    # IGNITIANsのコストを記録
    local ignitian_total_input=0
    local ignitian_total_output=0
    local ignitian_total_cost=0
    local ignitian_count=0

    echo "" >> "$history_file"
    echo "ignitians:" >> "$history_file"

    local in_ignitians=false
    local current_ignitian=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*ignitians: ]]; then
            in_ignitians=true
            continue
        fi
        if [[ "$in_ignitians" == true ]]; then
            if [[ "$line" =~ ^[[:space:]]*ignitian_([0-9]+): ]]; then
                current_ignitian="ignitian_${BASH_REMATCH[1]}"
                ignitian_count=$((ignitian_count + 1))
            elif [[ "$line" =~ ^[[:space:]]*session_id:[[:space:]]*\"?([^\"]+)\"? ]] && [[ -n "$current_ignitian" ]]; then
                local session_id="${BASH_REMATCH[1]}"
                if [[ -n "$session_id" ]] && [[ "$session_id" != "null" ]]; then
                    local tokens
                    tokens=$(collect_session_tokens "$session_id")
                    local input
                    input=$(echo "$tokens" | jq -r '.input')
                    local output
                    output=$(echo "$tokens" | jq -r '.output')
                    local cache_read
                    cache_read=$(echo "$tokens" | jq -r '.cache_read')
                    local cache_creation
                    cache_creation=$(echo "$tokens" | jq -r '.cache_creation')
                    local cost
                    cost=$(calculate_cost "$input" "$output" "$cache_read" "$cache_creation")

                    cat >> "$history_file" <<EOF
  ${current_ignitian}:
    session_id: "${session_id}"
    input_tokens: ${input}
    output_tokens: ${output}
    cache_read_tokens: ${cache_read}
    cache_creation_tokens: ${cache_creation}
    cost_usd: ${cost}
EOF

                    ignitian_total_input=$((ignitian_total_input + input))
                    ignitian_total_output=$((ignitian_total_output + output))
                    ignitian_total_cost=$(echo "$ignitian_total_cost + $cost" | bc)
                fi
                current_ignitian=""
            elif [[ "$line" =~ ^[a-z]+: ]]; then
                # インデントなしの新しいセクションが始まったら終了
                in_ignitians=false
            fi
        fi
    done < "$sessions_file"

    # 全体の合計
    total_input=$((total_input + ignitian_total_input))
    total_output=$((total_output + ignitian_total_output))
    total_cost=$(echo "$total_cost + $ignitian_total_cost" | bc)

    cat >> "$history_file" <<EOF

total:
  input_tokens: ${total_input}
  output_tokens: ${total_output}
  cost_usd: ${total_cost}
  ignitians_count: ${ignitian_count}
EOF

    print_success "コスト履歴を保存しました: $history_file"
}

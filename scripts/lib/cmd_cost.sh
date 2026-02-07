# shellcheck shell=bash
# lib/cmd_cost.sh - costコマンド

[[ -n "${__LIB_CMD_COST_LOADED:-}" ]] && return; __LIB_CMD_COST_LOADED=1

# =============================================================================
# cost コマンド
# =============================================================================
cmd_cost() {
    local target_session=""
    local target_agent=""
    local detailed=false
    local json_output=false
    local list_mode=false

    # オプション解析
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -s|--session)
                target_session="$2"
                if [[ ! "$target_session" =~ ^ignite- ]]; then
                    target_session="ignite-$target_session"
                fi
                shift 2
                ;;
            -a|--agent)
                target_agent="$2"
                shift 2
                ;;
            -d|--detailed)
                detailed=true
                shift
                ;;
            -j|--json)
                json_output=true
                shift
                ;;
            -l|--list)
                list_mode=true
                shift
                ;;
            -w|--workspace)
                WORKSPACE_DIR="$2"
                if [[ ! "$WORKSPACE_DIR" = /* ]]; then
                    WORKSPACE_DIR="$(pwd)/$WORKSPACE_DIR"
                fi
                shift 2
                ;;
            -h|--help) cmd_help cost; exit 0 ;;
            *) print_error "Unknown option: $1"; cmd_help cost; exit 1 ;;
        esac
    done

    # ワークスペースを設定
    setup_workspace

    # session_id が null のエージェントがあれば自動解決を試みる
    update_sessions_yaml 2>/dev/null || true

    # 一覧モード
    if [[ "$list_mode" == true ]]; then
        list_cost_sessions
        return 0
    fi

    # 料金設定を読み込む
    load_pricing || exit 1

    # セッション情報の取得元を決定
    local sessions_file="$WORKSPACE_DIR/costs/sessions.yaml"
    local started_at=""

    if [[ -n "$target_session" ]]; then
        # 履歴から検索
        local history_file="$WORKSPACE_DIR/costs/history/${target_session}.yaml"
        if [[ -f "$history_file" ]]; then
            sessions_file="$history_file"
            started_at=$(grep "^started_at:" "$history_file" | awk '{print $2}' | tr -d '"')
        else
            # 現在のセッションファイルを確認
            if [[ -f "$sessions_file" ]]; then
                local current_session
                current_session=$(grep "^session_name:" "$sessions_file" | awk '{print $2}' | tr -d '"')
                if [[ "$current_session" != "$target_session" ]]; then
                    print_error "セッション '$target_session' が見つかりません"
                    echo ""
                    echo "利用可能なセッション一覧:"
                    echo -e "  ${YELLOW}./scripts/ignite cost -l${NC}"
                    exit 1
                fi
            else
                print_error "セッション情報が見つかりません"
                exit 1
            fi
        fi
    fi

    if [[ ! -f "$sessions_file" ]]; then
        print_error "セッション情報が見つかりません: $sessions_file"
        echo ""
        echo "IGNITEシステムを起動してください:"
        echo -e "  ${YELLOW}./scripts/ignite start${NC}"
        exit 1
    fi

    # セッション情報を読み取り
    if [[ -z "$started_at" ]]; then
        started_at=$(grep "^started_at:" "$sessions_file" | awk '{print $2}' | tr -d '"')
    fi
    local session_name
    session_name=$(grep "^session_name:" "$sessions_file" | awk '{print $2}' | tr -d '"')

    # 経過時間を計算
    local elapsed=""
    if [[ -n "$started_at" ]]; then
        local start_epoch
        start_epoch=$(date -d "$started_at" +%s 2>/dev/null || echo "0")
        local now_epoch
        now_epoch=$(date +%s)
        local diff
        diff=$((now_epoch - start_epoch))
        local hours
        hours=$((diff / 3600))
        local minutes
        minutes=$(((diff % 3600) / 60))
        elapsed="${hours}h ${minutes}m"
    fi

    # エージェント定義（agents と agent_names は同じ長さであること）
    local -a agents=("leader" "${SUB_LEADERS[@]}")
    local -a agent_names=("$LEADER_NAME" "${SUB_LEADER_NAMES[@]}")

    # 各エージェントのトークン使用量を集計
    declare -A agent_input
    declare -A agent_output
    declare -A agent_cache_read
    declare -A agent_cache_creation
    declare -A agent_cost

    local total_input=0
    local total_output=0
    local total_cache_read=0
    local total_cache_creation=0
    local total_cost=0

    # Sub-Leaders と Leader の集計
    for i in "${!agents[@]}"; do
        local role="${agents[$i]}"

        # 特定エージェントのみ表示する場合
        if [[ -n "$target_agent" ]] && [[ "$target_agent" != "$role" ]] && [[ "$target_agent" != "ignitians" ]]; then
            continue
        fi

        local session_id
        session_id=$(get_agent_session_id "$role")
        if [[ -n "$session_id" ]]; then
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

            agent_input[$role]=$input
            agent_output[$role]=$output
            agent_cache_read[$role]=$cache_read
            agent_cache_creation[$role]=$cache_creation
            agent_cost[$role]=$cost

            total_input=$((total_input + input))
            total_output=$((total_output + output))
            total_cache_read=$((total_cache_read + cache_read))
            total_cache_creation=$((total_cache_creation + cache_creation))
            total_cost=$(echo "$total_cost + $cost" | bc)
        fi
    done

    # IGNITIANs の集計
    local ignitian_input=0
    local ignitian_output=0
    local ignitian_cache_read=0
    local ignitian_cache_creation=0
    local ignitian_cost=0
    local ignitian_count=0
    declare -A ignitian_data

    # ignitians セクションを解析
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

                    ignitian_data[$current_ignitian]="$input:$output:$cache_read:$cache_creation:$cost"

                    ignitian_input=$((ignitian_input + input))
                    ignitian_output=$((ignitian_output + output))
                    ignitian_cache_read=$((ignitian_cache_read + cache_read))
                    ignitian_cache_creation=$((ignitian_cache_creation + cache_creation))
                    ignitian_cost=$(echo "$ignitian_cost + $cost" | bc)
                fi
                current_ignitian=""
            elif [[ "$line" =~ ^[a-z]+: ]]; then
                # インデントなしの新しいセクションが始まったら終了
                in_ignitians=false
            fi
        fi
    done < "$sessions_file"

    # IGNITIANs の合計を全体に追加
    total_input=$((total_input + ignitian_input))
    total_output=$((total_output + ignitian_output))
    total_cache_read=$((total_cache_read + ignitian_cache_read))
    total_cache_creation=$((total_cache_creation + ignitian_cache_creation))
    total_cost=$(echo "$total_cost + $ignitian_cost" | bc)

    # JSON出力モード
    if [[ "$json_output" == true ]]; then
        local json_agents="{"
        local first=true
        for i in "${!agents[@]}"; do
            local role="${agents[$i]}"
            if [[ -n "${agent_input[$role]:-}" ]]; then
                if [[ "$first" == false ]]; then json_agents+=","; fi
                first=false
                json_agents+="\"$role\":{\"input\":${agent_input[$role]},\"output\":${agent_output[$role]},\"cache_read\":${agent_cache_read[$role]},\"cache_creation\":${agent_cache_creation[$role]},\"cost\":${agent_cost[$role]}}"
            fi
        done
        json_agents+=",\"ignitians\":{\"count\":$ignitian_count,\"input\":$ignitian_input,\"output\":$ignitian_output,\"cache_read\":$ignitian_cache_read,\"cache_creation\":$ignitian_cache_creation,\"cost\":$ignitian_cost}"
        json_agents+="}"

        local jpy_cost
        jpy_cost=$(echo "$total_cost * $EXCHANGE_RATE" | bc)
        echo "{\"session\":\"$session_name\",\"started_at\":\"$started_at\",\"elapsed\":\"$elapsed\",\"agents\":$json_agents,\"total\":{\"input\":$total_input,\"output\":$total_output,\"cache_read\":$total_cache_read,\"cache_creation\":$total_cache_creation,\"cost\":$total_cost,\"cost_jpy\":$jpy_cost}}"
        return 0
    fi

    # テーブル表示
    print_header "IGNITE コスト概要"
    echo ""

    if [[ -n "$session_name" ]]; then
        echo -e "${BLUE}セッション:${NC} $session_name"
    fi
    if [[ -n "$started_at" ]]; then
        local started_display
        started_display=$(echo "$started_at" | tr 'T' ' ' | cut -d'+' -f1)
        echo -e "${BLUE}セッション開始:${NC} $started_display"
    fi
    if [[ -n "$elapsed" ]]; then
        echo -e "${BLUE}経過時間:${NC} $elapsed"
    fi
    echo ""

    # テーブル列幅定義（表示幅）
    local col1_width=14  # エージェント名
    local col2_width=12  # 入力トークン
    local col3_width=12  # 出力トークン
    local col5_width=13  # キャッシュ（読込/作成）
    local col4_width=11  # 費用

    # テーブルヘッダー
    echo "┌────────────────┬──────────────┬──────────────┬───────────────┬─────────────┐"
    printf "│ %s │ %s │ %s │ %s │ %s │\n" \
        "$(pad_right "エージェント" $col1_width)" \
        "$(pad_left "入力トークン" $col2_width)" \
        "$(pad_left "出力トークン" $col3_width)" \
        "$(pad_left "Cache(R/W)" $col5_width)" \
        "$(pad_left "費用 (USD)" $col4_width)"
    echo "├────────────────┼──────────────┼──────────────┼───────────────┼─────────────┤"

    # Leader と Sub-Leaders
    for i in "${!agents[@]}"; do
        local role="${agents[$i]}"
        local name="${agent_names[$i]}"

        if [[ -n "$target_agent" ]] && [[ "$target_agent" != "$role" ]] && [[ "$target_agent" != "ignitians" ]]; then
            continue
        fi

        if [[ -n "${agent_input[$role]:-}" ]]; then
            local input_fmt
            input_fmt=$(format_number "${agent_input[$role]}")
            local output_fmt
            output_fmt=$(format_number "${agent_output[$role]}")
            local cache_r
            cache_r=$(echo "scale=1; ${agent_cache_read[$role]:-0} / 1000000" | bc)
            local cache_c
            cache_c=$(echo "scale=1; ${agent_cache_creation[$role]:-0} / 1000000" | bc)
            local cache_fmt="${cache_r}/${cache_c}M"
            local cost_fmt
            cost_fmt=$(printf "\$%8.2f" "${agent_cost[$role]}")
            printf "│ %s │ %s │ %s │ %s │ %s │\n" \
                "$(pad_right "$name" $col1_width)" \
                "$(pad_left "$input_fmt" $col2_width)" \
                "$(pad_left "$output_fmt" $col3_width)" \
                "$(pad_left "$cache_fmt" $col5_width)" \
                "$(pad_left "$cost_fmt" $col4_width)"
        fi
    done

    # IGNITIANs
    if [[ -z "$target_agent" ]] || [[ "$target_agent" == "ignitians" ]]; then
        if [[ $ignitian_count -gt 0 ]]; then
            echo "├────────────────┼──────────────┼──────────────┼───────────────┼─────────────┤"

            if [[ "$detailed" == true ]]; then
                # 詳細表示: 各IGNITIANを個別に表示
                for key in $(echo "${!ignitian_data[@]}" | tr ' ' '\n' | sort -V); do
                    local data="${ignitian_data[$key]}"
                    local input
                    input=$(echo "$data" | cut -d: -f1)
                    local output
                    output=$(echo "$data" | cut -d: -f2)
                    local cache_read
                    cache_read=$(echo "$data" | cut -d: -f3)
                    local cache_create
                    cache_create=$(echo "$data" | cut -d: -f4)
                    local cost
                    cost=$(echo "$data" | cut -d: -f5)
                    local input_fmt
                    input_fmt=$(format_number "$input")
                    local output_fmt
                    output_fmt=$(format_number "$output")
                    local cache_r
                    cache_r=$(echo "scale=1; ${cache_read:-0} / 1000000" | bc)
                    local cache_c
                    cache_c=$(echo "scale=1; ${cache_create:-0} / 1000000" | bc)
                    local cache_fmt="${cache_r}/${cache_c}M"
                    local cost_fmt
                    cost_fmt=$(printf "\$%8.2f" "$cost")
                    local display_name
                    display_name=$(echo "$key" | sed 's/ignitian_/IGNITIAN-/')
                    printf "│ %s │ %s │ %s │ %s │ %s │\n" \
                        "$(pad_right "$display_name" $col1_width)" \
                        "$(pad_left "$input_fmt" $col2_width)" \
                        "$(pad_left "$output_fmt" $col3_width)" \
                        "$(pad_left "$cache_fmt" $col5_width)" \
                        "$(pad_left "$cost_fmt" $col4_width)"
                done
            else
                # 集計表示
                local ignitian_input_fmt
                ignitian_input_fmt=$(format_number "$ignitian_input")
                local ignitian_output_fmt
                ignitian_output_fmt=$(format_number "$ignitian_output")
                local ign_cache_r
                ign_cache_r=$(echo "scale=1; ${ignitian_cache_read:-0} / 1000000" | bc)
                local ign_cache_c
                ign_cache_c=$(echo "scale=1; ${ignitian_cache_creation:-0} / 1000000" | bc)
                local ignitian_cache_fmt="${ign_cache_r}/${ign_cache_c}M"
                local ignitian_cost_fmt
                ignitian_cost_fmt=$(printf "\$%8.2f" "$ignitian_cost")
                local ignitian_label="IGNITIANs ($ignitian_count)"
                printf "│ %s │ %s │ %s │ %s │ %s │\n" \
                    "$(pad_right "$ignitian_label" $col1_width)" \
                    "$(pad_left "$ignitian_input_fmt" $col2_width)" \
                    "$(pad_left "$ignitian_output_fmt" $col3_width)" \
                    "$(pad_left "$ignitian_cache_fmt" $col5_width)" \
                    "$(pad_left "$ignitian_cost_fmt" $col4_width)"
            fi
        fi
    fi

    # 合計
    if [[ -z "$target_agent" ]]; then
        echo "├────────────────┼──────────────┼──────────────┼───────────────┼─────────────┤"
        local total_input_fmt
        total_input_fmt=$(format_number "$total_input")
        local total_output_fmt
        total_output_fmt=$(format_number "$total_output")
        local total_cache_r
        total_cache_r=$(echo "scale=1; ${total_cache_read:-0} / 1000000" | bc)
        local total_cache_c
        total_cache_c=$(echo "scale=1; ${total_cache_creation:-0} / 1000000" | bc)
        local total_cache_fmt="${total_cache_r}/${total_cache_c}M"
        local total_cost_fmt
        total_cost_fmt=$(printf "\$%8.2f" "$total_cost")
        local jpy_cost
        jpy_cost=$(printf "%.0f" "$(echo "$total_cost * $EXCHANGE_RATE" | bc)")
        printf "│ %s │ %s │ %s │ %s │ %s │\n" \
            "$(pad_right "合計" $col1_width)" \
            "$(pad_left "$total_input_fmt" $col2_width)" \
            "$(pad_left "$total_output_fmt" $col3_width)" \
            "$(pad_left "$total_cache_fmt" $col5_width)" \
            "$(pad_left "$total_cost_fmt" $col4_width)"
    fi

    echo "└────────────────┴──────────────┴──────────────┴───────────────┴─────────────┘"

    echo ""
    echo -e "${BLUE}料金:${NC} Claude Opus 4.5 (\$${PRICE_INPUT}/1M入力, \$${PRICE_OUTPUT}/1M出力)"
    if [[ -z "$target_agent" ]]; then
        echo -e "${BLUE}日本円概算:${NC} ¥$(format_number "$jpy_cost") (税別, \$1=¥${EXCHANGE_RATE})"
    fi

    # 詳細表示の場合はキャッシュ情報も表示
    if [[ "$detailed" == true ]]; then
        echo ""
        echo -e "${BLUE}キャッシュ使用量:${NC}"
        echo "  キャッシュ読み込み: $(format_number "$total_cache_read") トークン"
        echo "  キャッシュ作成: $(format_number "$total_cache_creation") トークン"
    fi
}

# shellcheck shell=bash
# lib/cmd_stop.sh - stopコマンド
[[ -n "${__LIB_CMD_STOP_LOADED:-}" ]] && return; __LIB_CMD_STOP_LOADED=1

cmd_stop() {
    local skip_confirm=false

    # オプション解析
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes) skip_confirm=true; shift ;;
            -s|--session)
                SESSION_NAME="$2"
                if [[ ! "$SESSION_NAME" =~ ^ignite- ]]; then
                    SESSION_NAME="ignite-$SESSION_NAME"
                fi
                shift 2
                ;;
            -w|--workspace)
                WORKSPACE_DIR="$2"
                if [[ ! "$WORKSPACE_DIR" = /* ]]; then
                    WORKSPACE_DIR="$(pwd)/$WORKSPACE_DIR"
                fi
                shift 2
                ;;
            -h|--help) cmd_help stop; exit 0 ;;
            *) print_error "Unknown option: $1"; cmd_help stop; exit 1 ;;
        esac
    done

    # ワークスペース解決 → 設定ロード → セッション名解決
    setup_workspace
    setup_workspace_config "$WORKSPACE_DIR"
    setup_session_name

    print_header "IGNITE システム停止"
    echo ""
    echo -e "${BLUE}対象セッション:${NC} $SESSION_NAME"
    echo ""

    # セッションの存在確認
    if ! session_exists; then
        print_error "セッション '$SESSION_NAME' が見つかりません"
        echo ""
        print_info "実行中のセッション一覧:"
        list_sessions 2>/dev/null || true
        exit 1
    fi

    # 確認（非対話環境ではスキップ）
    if [[ "$skip_confirm" == false ]] && [[ -t 0 ]]; then
        read -p "IGNITE システムを停止しますか? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_warning "キャンセルしました"
            exit 0
        fi
    fi

    # systemd サービス状態同期（プロセス kill の前に実行し、状態不整合を防ぐ）
    _stop_systemd_service

    # GitHub Watcher を停止
    _stop_pid_process "$IGNITE_RUNTIME_DIR/github_watcher.pid" "GitHub Watcher"

    # キューモニターを停止
    _stop_pid_process "$IGNITE_RUNTIME_DIR/queue_monitor.pid" "キューモニター"

    # エージェントプロセス停止（PID ベース → 共通 _kill_process_tree 使用）
    print_warning "エージェントプロセスを停止中..."
    for pid_file in "$IGNITE_RUNTIME_DIR/state"/.agent_pid_*; do
        [[ -f "$pid_file" ]] || continue
        local pid pane_idx
        pid=$(cat "$pid_file" 2>/dev/null || true)
        # ファイル名から pane_idx を抽出（.agent_pid_N → N）
        pane_idx="${pid_file##*.agent_pid_}"
        if [[ -n "$pid" ]] && _validate_pid "$pid" "opencode"; then
            _kill_process_tree "$pid" "$pane_idx" "$IGNITE_RUNTIME_DIR"
        fi
        rm -f "$pid_file"
    done
    # PID ファイルに載っていない孤立プロセスも掃除（orphan sweep: 安全弁）
    _sweep_orphan_processes

    rm -f "$IGNITE_RUNTIME_DIR/state"/.agent_{pgid,port,session,name}_*
    rm -f "$IGNITE_RUNTIME_DIR/state"/.send_lock_*
    print_success "エージェントプロセスを停止しました"

    # 最終残存プロセスチェック
    _check_remaining_processes

    # セッション情報ファイルを削除
    rm -f "$IGNITE_CONFIG_DIR/sessions/${SESSION_NAME}.yaml"
    rm -f "$IGNITE_RUNTIME_DIR/ignite-daemon.pid"

    log_info "IGNITE システム停止完了: session=$SESSION_NAME, workspace=$WORKSPACE_DIR"
    print_success "IGNITE システムを停止しました"
}

# _stop_pid_process <pid_file> <label>
# PIDファイルベースのプロセス停止（SIGTERM → 待機 → SIGKILL）
_stop_pid_process() {
    local pid_file="$1"
    local label="$2"

    [[ -f "$pid_file" ]] || return 0

    local pid
    pid=$(cat "$pid_file" 2>/dev/null || true)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        print_info "${label}を停止中..."
        kill "$pid" 2>/dev/null || true
        # プロセス終了を最大3秒待機（0.5秒 × 6回）
        local attempt=0
        while kill -0 "$pid" 2>/dev/null && [[ $attempt -lt 6 ]]; do
            sleep 0.5
            attempt=$((attempt + 1))
        done
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
        fi
        print_success "${label}停止完了"
    fi
    rm -f "$pid_file"
}

# _is_workspace_process <pid>
# 指定PIDが自ワークスペースに属するか判定（macOS/Linux両対応）
_is_workspace_process() {
    local pid="$1"

    # (1) Linux: /proc/PID/environ から WORKSPACE_DIR をチェック
    if [[ -f "/proc/$pid/environ" ]]; then
        grep -qsF "$WORKSPACE_DIR" "/proc/$pid/environ" 2>/dev/null && return 0
        return 1
    fi

    # (2) macOS フォールバック: ps eww で環境変数を取得
    if command -v ps &>/dev/null; then
        if ps eww -p "$pid" 2>/dev/null | grep -qsF "$WORKSPACE_DIR"; then
            return 0
        fi
    fi

    return 1
}

# _sweep_orphan_processes
# PIDファイルに載っていない孤立プロセスを検出・停止
_sweep_orphan_processes() {
    # opencode serve および node 関連プロセスを検出
    local _orphan_pids=""
    _orphan_pids=$(
        {
            pgrep -f "opencode serve.*--print-logs" 2>/dev/null || true
            pgrep -f "node.*opencode" 2>/dev/null || true
        } | sort -u | while read -r _op; do
            [[ -n "$_op" ]] || continue
            # WORKSPACE_DIR マッチで自ワークスペースのプロセスのみ対象（他WS誤kill防止）
            if _is_workspace_process "$_op"; then
                echo "$_op"
            fi
        done
    ) || true

    if [[ -z "$_orphan_pids" ]]; then
        return 0
    fi

    log_info "孤立プロセスを検出: $(echo "$_orphan_pids" | wc -l) 件"

    # 子プロセスも含めて停止
    echo "$_orphan_pids" | while read -r _op; do
        [[ -n "$_op" ]] || continue
        pkill -P "$_op" 2>/dev/null || true
        kill "$_op" 2>/dev/null || true
    done

    sleep 1

    # 生存チェック → SIGKILL エスカレーション
    echo "$_orphan_pids" | while read -r _op; do
        [[ -n "$_op" ]] || continue
        if kill -0 "$_op" 2>/dev/null; then
            if _validate_pid "$_op" "opencode"; then
                log_warn "孤立プロセス PID=$_op が停止しません。SIGKILL を送信します"
                pkill -9 -P "$_op" 2>/dev/null || true
                kill -9 "$_op" 2>/dev/null || true
            fi
        fi
    done
}

# _check_remaining_processes
# 全kill完了後に残存プロセスをチェックし報告
_check_remaining_processes() {
    local _remaining=""
    _remaining=$(
        {
            pgrep -f "opencode serve.*--print-logs" 2>/dev/null || true
            pgrep -f "node.*opencode" 2>/dev/null || true
        } | sort -u | while read -r _rp; do
            [[ -n "$_rp" ]] || continue
            if _is_workspace_process "$_rp"; then
                echo "$_rp"
            fi
        done
    ) || true

    if [[ -n "$_remaining" ]]; then
        local _count
        _count=$(echo "$_remaining" | wc -l)
        log_warn "停止処理後も ${_count} 件のプロセスが残存しています: $(echo "$_remaining" | tr '\n' ' ')"
    fi
}

# _stop_systemd_service
# systemd サービスとの状態同期（再帰呼び出し防止付き）
_stop_systemd_service() {
    # systemctl が存在しない環境ではスキップ（graceful degradation）
    if ! command -v systemctl &>/dev/null; then
        log_info "systemctl が見つかりません。systemd サービス同期をスキップします"
        return 0
    fi

    # INVOCATION_ID 環境変数でsystemd経由の呼び出しを検知（再帰防止: critical）
    # systemd が ExecStop でこのスクリプトを呼んだ場合、INVOCATION_ID が自動設定される
    if [[ -n "${INVOCATION_ID:-}" ]]; then
        log_info "systemd 経由の呼び出しを検知（INVOCATION_ID=${INVOCATION_ID}）。systemctl 呼び出しをスキップします"
        return 0
    fi

    # 直接実行時: systemd サービスが active なら停止
    # SESSION_NAME は "ignite-xxx" だが、systemd インスタンス名は "xxx"（ignite- プレフィックスなし）
    local instance_name="${SESSION_NAME#ignite-}"
    local service_name="ignite@${instance_name}.service"
    local service_state
    service_state=$(systemctl --user is-active "$service_name" 2>/dev/null || true)

    case "$service_state" in
        active|activating|reloading)
            print_info "systemd サービス ${service_name} を停止中..."
            if systemctl --user stop "$service_name" 2>/dev/null; then
                print_success "systemd サービス停止完了: ${service_name}"
            else
                log_warn "systemd サービス停止に失敗: ${service_name}"
            fi
            ;;
        inactive|deactivating|failed|"")
            log_info "systemd サービスは既に停止済み: ${service_name} (state=${service_state:-unknown})"
            ;;
        *)
            # unknown, not-found 等
            log_info "systemd サービス未設定またはステータス不明: ${service_name} (state=${service_state})"
            ;;
    esac
}

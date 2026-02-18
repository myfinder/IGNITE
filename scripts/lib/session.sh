# shellcheck shell=bash
# lib/session.sh - セッションID生成・ワークスペース管理
[[ -n "${__LIB_SESSION_LOADED:-}" ]] && return; __LIB_SESSION_LOADED=1

# =============================================================================
# 関数名: generate_session_id
# 目的: ユニークなセッションIDを自動生成する
# 引数: なし
# 戻り値: "ignite-XXXX" 形式のセッションID（XXXXは4文字のハッシュ）
# =============================================================================
generate_session_id() {
    # プロジェクトパス + タイムスタンプから短いIDを生成
    echo "ignite-$(echo "${PROJECT_ROOT}-$(date +%s)" | md5sum | cut -c1-4)"
}

# デフォルトのワークスペースパス
get_default_workspace() {
    echo "$DEFAULT_WORKSPACE_DIR"
}

# セッションIDの設定（指定がなければ自動生成）
# 解決順: 1) runtime.yaml → 2) 新規生成
setup_session_name() {
    [[ -n "$SESSION_NAME" ]] && return

    # 1. ワークスペースの runtime.yaml からセッション名を取得
    local ws="${WORKSPACE_DIR:-}"
    if [[ -z "$ws" ]] && [[ -n "${IGNITE_WORKSPACE:-}" ]]; then
        ws="$IGNITE_WORKSPACE"
    fi
    if [[ -z "$ws" ]] && [[ -d "$(pwd)/.ignite" ]]; then
        ws="$(pwd)"
    fi
    if [[ -n "$ws" ]] && [[ -f "$ws/.ignite/runtime.yaml" ]]; then
        local name
        name=$(yaml_get "$ws/.ignite/runtime.yaml" "session_name")
        if [[ -n "$name" ]]; then
            # Leader PID が生存していれば有効
            local leader_pid
            leader_pid=$(cat "$ws/.ignite/state/.agent_pid_0" 2>/dev/null || true)
            if [[ -n "$leader_pid" ]] && kill -0 "$leader_pid" 2>/dev/null; then
                SESSION_NAME="$name"
                WORKSPACE_DIR="$ws"
                return
            fi
        fi
    fi

    # 2. セッションなし → 新規生成
    SESSION_NAME=$(generate_session_id)
}

# ワークスペースの設定（指定がなければ 環境変数 → .ignite/ 自動検出 → デフォルト）
setup_workspace() {
    if [[ -z "$WORKSPACE_DIR" ]]; then
        # 環境変数 IGNITE_WORKSPACE が設定されていれば使用（systemd 連携用）
        if [[ -n "${IGNITE_WORKSPACE:-}" ]]; then
            WORKSPACE_DIR="$IGNITE_WORKSPACE"
            log_info "ワークスペース設定（環境変数）: $WORKSPACE_DIR"
        # CWD に .ignite/ があれば自動検出（Git方式）
        elif [[ -d "$(pwd)/.ignite" ]]; then
            WORKSPACE_DIR="$(pwd)"
            log_info "ワークスペース検出: $WORKSPACE_DIR"
        else
            WORKSPACE_DIR=$(get_default_workspace)
            log_info "デフォルトワークスペース: $WORKSPACE_DIR"
        fi
    fi
}

# ワークスペースディレクトリの存在チェック（start以外のコマンド用）
require_workspace() {
    if [[ ! -d "$WORKSPACE_DIR" ]]; then
        print_error "ワークスペースディレクトリが見つかりません: $WORKSPACE_DIR"
        print_info "先に 'ignite start' でワークスペースを作成してください"
        exit 1
    fi
}

# 実行中の全IGNITEセッションを一覧表示
list_sessions() {
    # runtime.yaml ベースで一覧
    local ws="${WORKSPACE_DIR:-}"
    if [[ -n "$ws" ]] && [[ -f "$ws/.ignite/runtime.yaml" ]]; then
        local name
        name=$(yaml_get "$ws/.ignite/runtime.yaml" "session_name" 2>/dev/null || true)
        if [[ -n "$name" ]]; then
            local leader_pid
            leader_pid=$(cat "$ws/.ignite/state/.agent_pid_0" 2>/dev/null || true)
            if [[ -n "$leader_pid" ]] && kill -0 "$leader_pid" 2>/dev/null; then
                echo "$name"
                return 0
            fi
        fi
    fi
    print_warning "実行中のIGNITEセッションはありません"
    return 1
}

# セッションが存在するかチェック
session_exists() {
    local state_dir="$IGNITE_RUNTIME_DIR/state"
    ls "$state_dir"/.agent_pid_* &>/dev/null || return 1
    local leader_pid
    leader_pid=$(cat "$state_dir/.agent_pid_0" 2>/dev/null || true)
    [[ -n "$leader_pid" ]] && kill -0 "$leader_pid" 2>/dev/null
}

# =============================================================================
# 関数名: list_all_sessions
# 目的: 全ワークスペースまたは現ワークスペースのセッション一覧を出力する
# 引数: [--all] 全ワークスペースを走査（省略時は現WSのみ）
# 出力: 1行1セッション形式 "session_name<TAB>status<TAB>workspace_dir"
# 戻り値: 0=セッションが1件以上見つかった, 1=セッションなし
# 備考: WORKSPACE_DIR グローバル変数は走査中に書き換えない
# =============================================================================
list_all_sessions() {
    local scan_all=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all) scan_all=true; shift ;;
            *) shift ;;
        esac
    done

    local found=0

    # ワークスペース一覧を収集
    local -a ws_dirs=()

    if [[ "$scan_all" == true ]]; then
        # 3段階フォールバックで IGNITE_WORKSPACES_DIR を検出
        local workspaces_dir=""

        # (1) 環境変数 IGNITE_WORKSPACES_DIR
        if [[ -n "${IGNITE_WORKSPACES_DIR:-}" ]] && [[ -d "$IGNITE_WORKSPACES_DIR" ]]; then
            workspaces_dir="$IGNITE_WORKSPACES_DIR"
        fi

        # (2) 現ワークスペースの親ディレクトリから .ignite を持つサブディレクトリを検索
        if [[ -z "$workspaces_dir" ]] && [[ -n "${WORKSPACE_DIR:-}" ]]; then
            local parent_dir
            # realpath でパス正規化（末尾 '/.' 対応）
            parent_dir="$(realpath "${WORKSPACE_DIR}/.." 2>/dev/null || dirname "$WORKSPACE_DIR")"
            if [[ -d "$parent_dir" ]]; then
                # 親ディレクトリに .ignite を持つサブディレクトリが存在するか確認
                local _check_dir
                for _check_dir in "$parent_dir"/*/; do
                    if [[ -d "${_check_dir}.ignite" ]]; then
                        workspaces_dir="$parent_dir"
                        break
                    fi
                done
            fi
        fi

        # (3) フォールバック: 現ワークスペースのみ
        if [[ -n "$workspaces_dir" ]]; then
            local _ws_candidate
            for _ws_candidate in "$workspaces_dir"/*/; do
                [[ -d "$_ws_candidate" ]] || continue
                local _normalized
                _normalized="$(realpath "$_ws_candidate" 2>/dev/null || echo "$_ws_candidate")"
                if [[ -d "${_normalized}/.ignite" ]]; then
                    ws_dirs+=("$_normalized")
                fi
            done
        else
            # フォールバック: 現ワークスペースのみ
            if [[ -n "${WORKSPACE_DIR:-}" ]]; then
                local _norm_ws
                _norm_ws="$(realpath "$WORKSPACE_DIR" 2>/dev/null || echo "$WORKSPACE_DIR")"
                ws_dirs+=("$_norm_ws")
            fi
        fi
    else
        # --all なし: 現ワークスペースのみ
        if [[ -n "${WORKSPACE_DIR:-}" ]]; then
            local _norm_ws
            _norm_ws="$(realpath "$WORKSPACE_DIR" 2>/dev/null || echo "$WORKSPACE_DIR")"
            ws_dirs+=("$_norm_ws")
        fi
    fi

    # 各ワークスペースの sessions/*.yaml を走査
    local _ws
    for _ws in "${ws_dirs[@]}"; do
        local _session_dir="${_ws}/.ignite/sessions"
        local _ws_found=0

        if [[ -d "$_session_dir" ]]; then
            local _yaml_file
            for _yaml_file in "$_session_dir"/*.yaml; do
                [[ -f "$_yaml_file" ]] || continue

                # 空ファイルチェック
                if [[ ! -s "$_yaml_file" ]]; then
                    echo "[WARN] list_all_sessions: 空のセッションファイルをスキップ: $_yaml_file" >&2
                    continue
                fi

                # セッション名を取得（必須フィールド）
                local _s_name
                _s_name="$(grep '^session_name:' "$_yaml_file" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"' | tr -d "'")"
                if [[ -z "$_s_name" ]]; then
                    echo "[WARN] list_all_sessions: session_name が欠損しているファイルをスキップ: $_yaml_file" >&2
                    continue
                fi

                # workspace_dir を取得
                local _s_workspace
                _s_workspace="$(grep '^workspace_dir:' "$_yaml_file" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"' | tr -d "'")"
                if [[ -z "$_s_workspace" ]]; then
                    echo "[WARN] list_all_sessions: workspace_dir が欠損しているファイルをスキップ: $_yaml_file" >&2
                    continue
                fi

                # パス正規化
                _s_workspace="$(realpath "$_s_workspace" 2>/dev/null || echo "$_s_workspace")"

                # STATUS判定: Leader PID (.agent_pid_0) の生存チェック
                local _s_status="stopped"
                local _pid_file="${_s_workspace}/.ignite/state/.agent_pid_0"
                if [[ -f "$_pid_file" ]]; then
                    local _leader_pid
                    _leader_pid="$(cat "$_pid_file" 2>/dev/null || true)"
                    if [[ -n "$_leader_pid" ]]; then
                        if kill -0 "$_leader_pid" 2>/dev/null; then
                            _s_status="running"
                        else
                            echo "[WARN] list_all_sessions: staleセッション検出 (PID=$_leader_pid は無効): $_s_name" >&2
                            _s_status="stale"
                            continue
                        fi
                    fi
                fi

                # 出力: session_name<TAB>status<TAB>workspace_dir
                printf '%s\t%s\t%s\n' "$_s_name" "$_s_status" "$_s_workspace"
                found=$((found + 1))
                _ws_found=$((_ws_found + 1))
            done
        fi

        # このワークスペースで sessions/*.yaml からセッションが見つからなかった場合:
        # runtime.yaml フォールバック
        if [[ "$_ws_found" -eq 0 ]] && [[ -f "${_ws}/.ignite/runtime.yaml" ]]; then
            local _rt_name
            _rt_name="$(yaml_get "${_ws}/.ignite/runtime.yaml" "session_name" 2>/dev/null || true)"
            if [[ -n "$_rt_name" ]]; then
                local _rt_status="stopped"
                local _rt_pid_file="${_ws}/.ignite/state/.agent_pid_0"
                if [[ -f "$_rt_pid_file" ]]; then
                    local _rt_pid
                    _rt_pid="$(cat "$_rt_pid_file" 2>/dev/null || true)"
                    if [[ -n "$_rt_pid" ]] && kill -0 "$_rt_pid" 2>/dev/null; then
                        _rt_status="running"
                    fi
                fi
                printf '%s\t%s\t%s\n' "$_rt_name" "$_rt_status" "$_ws"
                found=$((found + 1))
            fi
        fi
    done

    if [[ "$found" -eq 0 ]]; then
        return 1
    fi
    return 0
}

# 設定ファイルからワーカー数を取得（resolve_config でワークスペース優先）
get_worker_count() {
    local config_file
    config_file=$(resolve_config "system.yaml" 2>/dev/null) || config_file="$IGNITE_CONFIG_DIR/system.yaml"
    if [[ -f "$config_file" ]]; then
        local count
        count=$(yaml_get "$config_file" 'worker_count')
        if [[ -n "$count" ]] && [[ "$count" =~ ^[0-9]+$ ]]; then
            echo "$count"
            return
        fi
    fi
    echo "$DEFAULT_WORKER_COUNT"
}

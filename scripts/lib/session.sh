# shellcheck shell=bash
# lib/session.sh - セッションID生成・ワークスペース管理
[[ -n "${__LIB_SESSION_LOADED:-}" ]] && return; __LIB_SESSION_LOADED=1

# =============================================================================
# _is_leader_alive <workspace_dir>
# Leader エージェントが稼働中かを判定する。
# per-message モデルでは CLI プロセスは一時的なため、session_id の存在のみで判定。
# session_id ファイルは ignite stop 時に cli_cleanup_agent_state で削除される。
# 戻り値: 0=alive, 1=dead
# =============================================================================
_is_leader_alive() {
    local ws="$1"
    local session_id
    session_id=$(cat "${ws}/.ignite/state/.agent_session_0" 2>/dev/null || true)
    [[ -n "$session_id" ]]
}

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
            # Leader が生存していれば有効
            if _is_leader_alive "$ws"; then
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
            if _is_leader_alive "$ws"; then
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
    _is_leader_alive "${WORKSPACE_DIR:-$(pwd)}"
}

# =============================================================================
# 関数名: get_workspaces_list_path
# 目的: workspaces.list ファイルのパスを返す
# 戻り値: workspaces.list の絶対パス
# =============================================================================
get_workspaces_list_path() {
    echo "${XDG_DATA_HOME:-$HOME/.local/share}/ignite/workspaces.list"
}

# =============================================================================
# 関数名: register_workspace
# 目的: ワークスペースを workspaces.list に登録する（重複排除・アトミック書込）
# 引数: [path] 登録するワークスペースの絶対パス（省略時は WORKSPACE_DIR）
# 戻り値: 0=成功
# 備考: flock + mktemp + mv によるアトミック書込
# =============================================================================
register_workspace() {
    local ws_path="${1:-${WORKSPACE_DIR:-}}"
    [[ -z "$ws_path" ]] && return 0

    # パス正規化
    ws_path="$(realpath "$ws_path" 2>/dev/null || echo "$ws_path")"

    local list_file
    list_file="$(get_workspaces_list_path)"

    # ディレクトリ自動作成
    mkdir -p "$(dirname "$list_file")"

    # ファイルが存在し、既に登録済みならスキップ
    if [[ -f "$list_file" ]] && grep -qxF "$ws_path" "$list_file" 2>/dev/null; then
        return 0
    fi

    # flock + mktemp + mv によるアトミック書込
    local lock_file="${list_file}.lock"
    (
        flock -w 5 200 || { echo "[WARN] register_workspace: ロック取得失敗" >&2; exit 1; }

        # flock 内で再度重複チェック（競合対策）
        if [[ -f "$list_file" ]] && grep -qxF "$ws_path" "$list_file" 2>/dev/null; then
            exit 0
        fi

        local tmp_file
        tmp_file="$(mktemp "${list_file}.XXXXXX")"

        # 既存内容をコピー + 新規行を追加
        if [[ -f "$list_file" ]]; then
            cat "$list_file" > "$tmp_file"
        fi
        echo "$ws_path" >> "$tmp_file"

        mv "$tmp_file" "$list_file"
    ) 200>"$lock_file"
}

# =============================================================================
# 関数名: list_all_sessions
# 目的: 全ワークスペースまたは現ワークスペースのセッション一覧を出力する
# 引数: [--all] 全ワークスペースを走査（省略時は現WSのみ）
# 出力: 1行1セッション形式 "session_name<TAB>status<TAB>agents<TAB>workspace_dir"
# 戻り値: 0=セッションが1件以上見つかった, 1=セッションなし
# 備考: WORKSPACE_DIR グローバル変数は走査中に書き換えない
#        workspaces.list を唯一のソースとして使用（親ディレクトリ推測なし）
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
        local list_file
        list_file="$(get_workspaces_list_path)"

        if [[ -f "$list_file" ]]; then
            # workspaces.list を唯一のソースとして使用
            local _line
            while IFS= read -r _line || [[ -n "$_line" ]]; do
                # 空行スキップ
                [[ -z "$_line" ]] && continue
                # コメント行スキップ
                [[ "$_line" == \#* ]] && continue

                # パス正規化
                local _normalized
                _normalized="$(realpath "$_line" 2>/dev/null || echo "$_line")"

                # 無効パスチェック
                if [[ ! -d "$_normalized/.ignite" ]]; then
                    echo "[WARN] list_all_sessions: 無効なワークスペースパスをスキップ: $_normalized" >&2
                    continue
                fi

                ws_dirs+=("$_normalized")
            done < "$list_file"
        fi

        # セカンダリフォールバック: IGNITE_WORKSPACES_DIR 環境変数
        if [[ ${#ws_dirs[@]} -eq 0 ]] && [[ -n "${IGNITE_WORKSPACES_DIR:-}" ]] && [[ -d "$IGNITE_WORKSPACES_DIR" ]]; then
            local _ws_candidate
            for _ws_candidate in "$IGNITE_WORKSPACES_DIR"/*/; do
                [[ -d "$_ws_candidate" ]] || continue
                local _normalized
                _normalized="$(realpath "$_ws_candidate" 2>/dev/null || echo "$_ws_candidate")"
                if [[ -d "${_normalized}/.ignite" ]]; then
                    ws_dirs+=("$_normalized")
                fi
            done
        fi

        # 最終フォールバック: 現ワークスペースのみ
        if [[ ${#ws_dirs[@]} -eq 0 ]]; then
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

                # AGENTS列: mode, agents_total, agents_actual を取得
                local _s_mode _s_total _s_actual _agents_display="-"
                _s_mode="$(grep '^mode:' "$_yaml_file" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"' | tr -d "'" || true)"
                _s_total="$(grep '^agents_total:' "$_yaml_file" 2>/dev/null | head -1 | awk '{print $2}' || true)"
                _s_actual="$(grep '^agents_actual:' "$_yaml_file" 2>/dev/null | head -1 | awk '{print $2}' || true)"
                if [[ -n "$_s_total" ]] && [[ -n "$_s_actual" ]]; then
                    _agents_display="${_s_actual}/${_s_total}"
                    if [[ "${_s_mode:-}" == "leader" ]]; then
                        _agents_display="${_agents_display} (solo)"
                    fi
                fi

                # STATUS判定: Leader の生存チェック
                # stale セッションは STATUS='stopped' として出力（スキップしない）
                local _s_status="stopped"
                if _is_leader_alive "$_s_workspace"; then
                    _s_status="running"
                fi

                # 出力: session_name<TAB>status<TAB>agents<TAB>workspace_dir
                printf '%s\t%s\t%s\t%s\n' "$_s_name" "$_s_status" "$_agents_display" "$_s_workspace"
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
                if _is_leader_alive "$_ws"; then
                    _rt_status="running"
                fi
                printf '%s\t%s\t%s\t%s\n' "$_rt_name" "$_rt_status" "-" "$_ws"
                found=$((found + 1))
            fi
        fi
    done

    if [[ "$found" -eq 0 ]]; then
        return 1
    fi
    return 0
}

# =============================================================================
# 関数名: cleanup_stale_sessions
# 目的: PID が死亡している stale セッション YAML を削除する
# 引数: [workspace_path] ワークスペースパス（省略時は WORKSPACE_DIR）
# 戻り値: 0=常に成功
# =============================================================================
cleanup_stale_sessions() {
    local ws="${1:-${WORKSPACE_DIR:-}}"
    [[ -z "$ws" ]] && return 0

    local session_dir="${ws}/.ignite/sessions"
    [[ -d "$session_dir" ]] || return 0

    local yaml_file
    for yaml_file in "$session_dir"/*.yaml; do
        [[ -f "$yaml_file" ]] || continue
        [[ -s "$yaml_file" ]] || continue

        # session_name を取得
        local s_name
        s_name="$(grep '^session_name:' "$yaml_file" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"' | tr -d "'")"
        [[ -z "$s_name" ]] && continue

        # workspace_dir を取得
        local s_workspace
        s_workspace="$(grep '^workspace_dir:' "$yaml_file" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"' | tr -d "'")"
        [[ -z "$s_workspace" ]] && continue

        # Leader の生存チェック
        if ! _is_leader_alive "$s_workspace"; then
            log_info "stale セッションを削除: $s_name"
            rm -f "$yaml_file"
        fi
    done

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

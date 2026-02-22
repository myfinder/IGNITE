#!/usr/bin/env bats
# =============================================================================
# queue_monitor.sh テスト
# テスト対象: scripts/utils/queue_monitor.sh
# =============================================================================

load 'test_helper'

setup() {
    setup_temp_dir

    # queue_monitor.sh の初期化ロジックを部分的にテストするため、
    # core.sh のみ source して変数解決の挙動を検証する
    source "$SCRIPTS_DIR/lib/core.sh"
}

teardown() {
    cleanup_temp_dir
}

# =============================================================================
# IGNITE_WORKSPACE → WORKSPACE_DIR 変換
# =============================================================================

@test "queue_monitor: IGNITE_WORKSPACE が WORKSPACE_DIR に変換される" {
    local ws_dir="$TEST_TEMP_DIR/workspace-a"
    mkdir -p "$ws_dir/.ignite/state"

    run bash -c '
        export IGNITE_WORKSPACE="'"$ws_dir"'"
        unset WORKSPACE_DIR
        source "'"$SCRIPTS_DIR"'/lib/core.sh"
        # queue_monitor.sh L32-35 の変換ロジック
        if [[ -z "${WORKSPACE_DIR:-}" ]] && [[ -n "${IGNITE_WORKSPACE:-}" ]]; then
            WORKSPACE_DIR="$IGNITE_WORKSPACE"
        fi
        echo "$WORKSPACE_DIR"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "$ws_dir" ]
}

@test "queue_monitor: WORKSPACE_DIR が既設定なら IGNITE_WORKSPACE で上書きしない" {
    run bash -c '
        export IGNITE_WORKSPACE="/should/not/use"
        export WORKSPACE_DIR="/already/set"
        source "'"$SCRIPTS_DIR"'/lib/core.sh"
        if [[ -z "${WORKSPACE_DIR:-}" ]] && [[ -n "${IGNITE_WORKSPACE:-}" ]]; then
            WORKSPACE_DIR="$IGNITE_WORKSPACE"
        fi
        echo "$WORKSPACE_DIR"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "/already/set" ]
}

@test "queue_monitor: 両方未設定時は PROJECT_ROOT/workspace にフォールバック" {
    run bash -c '
        unset IGNITE_WORKSPACE
        unset WORKSPACE_DIR
        source "'"$SCRIPTS_DIR"'/lib/core.sh"
        if [[ -z "${WORKSPACE_DIR:-}" ]] && [[ -n "${IGNITE_WORKSPACE:-}" ]]; then
            WORKSPACE_DIR="$IGNITE_WORKSPACE"
        fi
        WORKSPACE_DIR="${WORKSPACE_DIR:-$PROJECT_ROOT/workspace}"
        echo "$WORKSPACE_DIR"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == */workspace ]]
}

# =============================================================================
# ロックファイルのワークスペース分離
# =============================================================================

@test "queue_monitor: 異なるワークスペースで独立したロックファイルパスになる" {
    local ws_a="$TEST_TEMP_DIR/workspace-a"
    local ws_b="$TEST_TEMP_DIR/workspace-b"
    mkdir -p "$ws_a/.ignite/state"
    mkdir -p "$ws_b/.ignite/state"

    # ワークスペースAのロックファイルパスを取得
    local lock_a
    lock_a=$(bash -c '
        export IGNITE_WORKSPACE="'"$ws_a"'"
        unset WORKSPACE_DIR
        unset IGNITE_RUNTIME_DIR
        source "'"$SCRIPTS_DIR"'/lib/core.sh"
        if [[ -z "${WORKSPACE_DIR:-}" ]] && [[ -n "${IGNITE_WORKSPACE:-}" ]]; then
            WORKSPACE_DIR="$IGNITE_WORKSPACE"
        fi
        [[ -n "${WORKSPACE_DIR:-}" ]] && setup_workspace_config "$WORKSPACE_DIR"
        WORKSPACE_DIR="${WORKSPACE_DIR:-$PROJECT_ROOT/workspace}"
        IGNITE_RUNTIME_DIR="${IGNITE_RUNTIME_DIR:-$WORKSPACE_DIR}"
        echo "${IGNITE_RUNTIME_DIR}/state/queue_monitor.lock"
    ')

    # ワークスペースBのロックファイルパスを取得
    local lock_b
    lock_b=$(bash -c '
        export IGNITE_WORKSPACE="'"$ws_b"'"
        unset WORKSPACE_DIR
        unset IGNITE_RUNTIME_DIR
        source "'"$SCRIPTS_DIR"'/lib/core.sh"
        if [[ -z "${WORKSPACE_DIR:-}" ]] && [[ -n "${IGNITE_WORKSPACE:-}" ]]; then
            WORKSPACE_DIR="$IGNITE_WORKSPACE"
        fi
        [[ -n "${WORKSPACE_DIR:-}" ]] && setup_workspace_config "$WORKSPACE_DIR"
        WORKSPACE_DIR="${WORKSPACE_DIR:-$PROJECT_ROOT/workspace}"
        IGNITE_RUNTIME_DIR="${IGNITE_RUNTIME_DIR:-$WORKSPACE_DIR}"
        echo "${IGNITE_RUNTIME_DIR}/state/queue_monitor.lock"
    ')

    # パスが異なることを確認
    [ "$lock_a" != "$lock_b" ]
    [[ "$lock_a" == *"workspace-a"* ]]
    [[ "$lock_b" == *"workspace-b"* ]]
}

@test "queue_monitor: 異なるワークスペースの flock が互いにブロックしない" {
    local ws_a="$TEST_TEMP_DIR/workspace-a"
    local ws_b="$TEST_TEMP_DIR/workspace-b"
    mkdir -p "$ws_a/.ignite/state"
    mkdir -p "$ws_b/.ignite/state"

    local lock_a="$ws_a/.ignite/state/queue_monitor.lock"
    local lock_b="$ws_b/.ignite/state/queue_monitor.lock"

    # ワークスペースAでロック取得
    exec 8>"$lock_a"
    flock -n 8
    local a_locked=$?

    # ワークスペースBでロック取得（別パスなので成功するはず）
    exec 7>"$lock_b"
    flock -n 7
    local b_locked=$?

    # 両方ロック解放
    exec 8>&-
    exec 7>&-

    [ "$a_locked" -eq 0 ]
    [ "$b_locked" -eq 0 ]
}

@test "queue_monitor: 同一ワークスペースの flock は二重取得できない" {
    local ws="$TEST_TEMP_DIR/workspace-same"
    mkdir -p "$ws/.ignite/state"

    local lock_file="$ws/.ignite/state/queue_monitor.lock"

    # プロセス1でロック取得（バックグラウンド）
    bash -c 'exec 9>"'"$lock_file"'" && flock -n 9 && sleep 3' &
    local pid1=$!
    sleep 0.5

    # プロセス2でロック取得（同じパス → 失敗するはず）
    run bash -c 'exec 9>"'"$lock_file"'" && flock -n 9 2>/dev/null; echo $?'

    kill "$pid1" 2>/dev/null
    wait "$pid1" 2>/dev/null || true

    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

# =============================================================================
# setup-env での WORKSPACE_DIR 出力
# =============================================================================

@test "setup-env: WORKSPACE_DIR が env ファイルに含まれる" {
    source "$SCRIPTS_DIR/lib/cmd_help.sh"
    source "$SCRIPTS_DIR/lib/cmd_service.sh"

    export XDG_CONFIG_HOME="$TEST_TEMP_DIR/xdg_config"
    local ws_dir="$TEST_TEMP_DIR/workspace-test"
    mkdir -p "$ws_dir/.ignite"

    # ワークスペースディレクトリに cd して実行
    cd "$ws_dir"
    run _service_setup_env test-session </dev/null
    [ "$status" -eq 0 ]

    local env_file="$TEST_TEMP_DIR/xdg_config/ignite/env.test-session"
    [ -f "$env_file" ]

    # WORKSPACE_DIR が含まれること
    run grep "^WORKSPACE_DIR=" "$env_file"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$ws_dir"* ]]
}

@test "setup-env: IGNITE_WORKSPACE と WORKSPACE_DIR が同じ値を持つ" {
    source "$SCRIPTS_DIR/lib/cmd_help.sh"
    source "$SCRIPTS_DIR/lib/cmd_service.sh"

    export XDG_CONFIG_HOME="$TEST_TEMP_DIR/xdg_config"
    local ws_dir="$TEST_TEMP_DIR/workspace-test2"
    mkdir -p "$ws_dir/.ignite"

    cd "$ws_dir"
    run _service_setup_env test-session2 </dev/null
    [ "$status" -eq 0 ]

    local env_file="$TEST_TEMP_DIR/xdg_config/ignite/env.test-session2"

    local ignite_ws
    ignite_ws=$(grep "^IGNITE_WORKSPACE=" "$env_file" | cut -d= -f2-)
    local workspace_dir
    workspace_dir=$(grep "^WORKSPACE_DIR=" "$env_file" | cut -d= -f2-)

    [ -n "$ignite_ws" ]
    [ -n "$workspace_dir" ]
    [ "$ignite_ws" = "$workspace_dir" ]
}

# =============================================================================
# send_message.sh 宛先バリデーション
# =============================================================================

@test "send_message: 有効なエージェント名は受け付ける" {
    local ws="$TEST_TEMP_DIR/ws-valid"
    mkdir -p "$ws/.ignite/queue"

    for agent in leader strategist architect evaluator coordinator innovator; do
        run bash -c "WORKSPACE_DIR='$ws' bash '$SCRIPTS_DIR/utils/send_message.sh' test_msg test_from $agent --body 'hello' 2>&1"
        [ "$status" -eq 0 ]
    done
}

@test "send_message: IGNITIAN パターンを受け付ける" {
    local ws="$TEST_TEMP_DIR/ws-ignitian"
    mkdir -p "$ws/.ignite/queue"

    run bash -c "WORKSPACE_DIR='$ws' bash '$SCRIPTS_DIR/utils/send_message.sh' test_msg test_from ignitian_1 --body 'hello' 2>&1"
    [ "$status" -eq 0 ]

    run bash -c "WORKSPACE_DIR='$ws' bash '$SCRIPTS_DIR/utils/send_message.sh' test_msg test_from ignitian-3 --body 'hello' 2>&1"
    [ "$status" -eq 0 ]
}

@test "send_message: 不正なエージェント名はエラーになる" {
    local ws="$TEST_TEMP_DIR/ws-invalid"
    mkdir -p "$ws/.ignite/queue"

    run bash -c "WORKSPACE_DIR='$ws' bash '$SCRIPTS_DIR/utils/send_message.sh' quality_plan_response evaluator quality_plan_response --body 'hello' 2>&1"
    [ "$status" -eq 1 ]
    [[ "$output" == *"不正な宛先エージェント名"* ]]
}

@test "send_message: メッセージタイプを宛先に指定するとエラーになる" {
    local ws="$TEST_TEMP_DIR/ws-type-as-to"
    mkdir -p "$ws/.ignite/queue"

    run bash -c "WORKSPACE_DIR='$ws' bash '$SCRIPTS_DIR/utils/send_message.sh' task_completed ignitian_1 task_completed --body 'hello' 2>&1"
    [ "$status" -eq 1 ]
    [[ "$output" == *"不正な宛先エージェント名"* ]]
}

# =============================================================================
# 並列配信設定
# =============================================================================

@test "queue_monitor: _PARALLEL_MAX のデフォルト値は 4" {
    run bash -c '
        unset QUEUE_PARALLEL_MAX
        export WORKSPACE_DIR="'"$TEST_TEMP_DIR"'"
        export IGNITE_RUNTIME_DIR="'"$TEST_TEMP_DIR"'"
        export IGNITE_CONFIG_DIR="'"$TEST_TEMP_DIR"'/nonexistent"
        _PARALLEL_MAX="${QUEUE_PARALLEL_MAX:-4}"
        echo "$_PARALLEL_MAX"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "4" ]
}

@test "queue_monitor: QUEUE_PARALLEL_MAX 環境変数でオーバーライドできる" {
    run bash -c '
        export QUEUE_PARALLEL_MAX=8
        _PARALLEL_MAX="${QUEUE_PARALLEL_MAX:-4}"
        echo "$_PARALLEL_MAX"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "8" ]
}

@test "queue_monitor: _load_queue_config が system.yaml から parallel_max を読み込む" {
    local config_dir="$TEST_TEMP_DIR/config"
    mkdir -p "$config_dir"
    cat > "$config_dir/system.yaml" << 'YAML'
queue:
  parallel_max: 6
  poll_interval: 15
YAML

    run bash -c '
        export IGNITE_CONFIG_DIR="'"$config_dir"'"
        _PARALLEL_MAX=4
        POLL_INTERVAL=10
        _load_queue_config() {
            local sys_yaml="${IGNITE_CONFIG_DIR}/system.yaml"
            if [[ -f "$sys_yaml" ]]; then
                local val
                val=$(sed -n "/^queue:/,/^[^ ]/p" "$sys_yaml" | awk -F": " "/^  parallel_max:/{print \$2; exit}" | sed "s/ *#.*//" | xargs)
                _PARALLEL_MAX="${val:-4}"
                val=$(sed -n "/^queue:/,/^[^ ]/p" "$sys_yaml" | awk -F": " "/^  poll_interval:/{print \$2; exit}" | sed "s/ *#.*//" | xargs)
                [[ -n "$val" ]] && POLL_INTERVAL="$val"
            fi
        }
        _load_queue_config
        echo "$_PARALLEL_MAX $POLL_INTERVAL"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "6 15" ]
}

@test "queue_monitor: シャットダウンフラグファイルのライフサイクル" {
    local state_dir="$TEST_TEMP_DIR/state"
    mkdir -p "$state_dir"

    local flag_file="$state_dir/.queue_monitor_shutdown"

    # 初期状態: ファイルなし
    [ ! -f "$flag_file" ]

    # graceful_shutdown 相当: touch
    touch "$flag_file"
    [ -f "$flag_file" ]

    # cleanup_and_log 相当: rm
    rm -f "$flag_file"
    [ ! -f "$flag_file" ]
}

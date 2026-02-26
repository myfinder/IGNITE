# Custom Watcher 作成ガイド

このドキュメントでは、IGNITE の Custom Watcher Framework を使って独自の Watcher を作成する方法を説明します。

## 概要

Custom Watcher Framework は、外部サービスのイベントを監視して IGNITE システムに取り込むための共通基盤です。`watcher_common.sh` が提供するデーモン管理・状態管理・MIME構築・入力サニタイズ等の共通機能を利用し、各 Watcher はイベント取得ロジック（`watcher_poll()`）のみを実装します。

### アーキテクチャ

```
┌──────────────────────────────────────────────────┐
│ Custom Watcher                                    │
│                                                   │
│  watcher_poll()          ← 各Watcherが実装       │
│    ↓                                              │
│  watcher_send_mime()     ← watcher_common.sh提供  │
│    ↓                                              │
│  queue/{to}/*.mime       → Leader等が処理         │
└──────────────────────────────────────────────────┘
```

### リファレンス実装

`scripts/utils/github_watcher.sh` が最も完全なリファレンス実装です。本ガイドのサンプルコードは github_watcher.sh のパターンに基づいています。

## API 仕様 — watcher_common.sh

### 初期化

#### `watcher_init <watcher_name> [config_file]`

Watcher の初期化を行います。設定読み込み、状態管理初期化、PIDファイル作成、シグナルtrap登録を一括で実行します。

| 引数 | 説明 |
|------|------|
| `watcher_name` | Watcher名（例: `slack_watcher`）。状態ファイル名・PIDファイル名・ログ接頭辞に使用 |
| `config_file` | 設定ファイルパス（省略時: `$IGNITE_CONFIG_DIR/{watcher-name}.yaml`。アンダースコアはハイフンに変換） |

### 設定

#### `watcher_load_config <config_file>`

YAML設定ファイルから共通設定を読み込みます。SIGHUP受信時にも自動で再呼び出しされます。

| 読み込む設定 | 変数 | デフォルト |
|-------------|------|-----------|
| `interval` | `_WATCHER_POLL_INTERVAL` | `60`（秒） |

Watcher固有の設定は各Watcherが `yaml_get` 等で独自に読み込んでください。

### デーモン管理

#### `watcher_run_daemon`

メインのポーリングループを開始します。以下を繰り返し実行します:

1. Leader プロセス生存チェック（`IGNITE_SESSION` 設定時）
2. `watcher_poll()` 呼び出し（各Watcherが上書き定義）
3. `watcher_cleanup_old_events()` — 24時間超過イベントの自動削除
4. SIGHUP 受信時の設定リロード
5. `_WATCHER_POLL_INTERVAL` 秒待機（1秒刻みで SIGTERM 応答性を確保）

シャットダウンは `_WATCHER_SHUTDOWN_REQUESTED` フラグで制御され、現在の `watcher_poll()` 完了後に安全に停止します。

#### `watcher_shutdown`

PIDファイルを削除してグレースフル停止を行います。EXIT trap から自動呼び出しされるため、通常は明示的に呼ぶ必要はありません。

### MIME メッセージ構築

#### `watcher_send_mime <from> <to> <type> <body_yaml> [repo] [issue]`

MIME メッセージを構築し、指定エージェントのキューに投入します。

| 引数 | 説明 |
|------|------|
| `from` | 送信元Watcher名 |
| `to` | 送信先エージェント名（例: `leader`） |
| `type` | メッセージタイプ（例: `github_event`, `slack_event`） |
| `body_yaml` | ボディYAML文字列（**生成は各Watcherの責務**） |
| `repo` | リポジトリ（省略可、例: `owner/repo`） |
| `issue` | Issue番号（省略可） |

**戻り値**: 生成された MIME ファイルのパス（stdout）

> **重要**: `watcher_send_mime()` は MIME 構築とキュー投入のみを担当します。ボディ YAML の組み立ては各 Watcher が行ってください。

### 状態管理

#### `watcher_init_state <watcher_name>`

状態ファイル（`state/{watcher_name}_state.json`）を初期化します。`watcher_init()` から自動呼び出しされます。

#### `watcher_is_event_processed <event_type> <event_id>`

イベントが処理済みかチェックします。戻り値: `0` = 処理済み、`1` = 未処理。

#### `watcher_mark_event_processed <event_type> <event_id>`

イベントを処理済みとして記録します。タイムスタンプ付きで `processed_events` に追加されます。

#### `watcher_update_last_check <check_key>`

指定キーの最終チェック時刻を更新します。

#### `watcher_get_last_check <check_key>`

指定キーの最終チェック時刻を取得します。未チェックの場合は `initialized_at` を返します。

#### `watcher_cleanup_old_events`

24時間超過の処理済みイベントを自動削除します。`watcher_run_daemon` のループ内で自動呼び出しされます。

### 入力サニタイズ

#### `_watcher_sanitize_input <input> [max_length]`

外部データをサニタイズします。デフォルト最大長は 256 文字。

処理内容:
- 制御文字（`\x00-\x1f`, `\x7f`）を全除去
- シェルメタキャラクタ・YAML特殊文字（`\`, `"`, `;`, `|`, `&`, `$`, `` ` ``, `<`, `>`, `(`, `)`）を全角に変換
- 長さ制限を適用

### カスタム Watcher が実装する関数

#### `watcher_poll`（必須）

1サイクル分のイベント取得・処理を行います。`watcher_common.sh` が空実装を提供しているため、各 Watcher が関数の再定義で上書きします。

#### `watcher_on_event <event_type> <event_data>`（Phase 3 予定）

Push型 Watcher 用のイベントコールバック。現在はスタブ実装のみ。

## watchers.yaml 設定

### スキーマ

```yaml
watchers:
  - name: watcher_name        # 必須: Watcher識別名（一意）
    description: "説明"        # 任意: 説明文
    script_path: path/to/script.sh  # 必須: スクリプトパス（相対パスはプロジェクトルート基準）
    config_file: config-name.yaml    # 必須: 設定ファイル名（config/ 配下）
    enabled: true              # 必須: 有効/無効（bool）
    auto_start: true           # 任意: --with-watcher=auto 時に自動起動（デフォルト: true）
```

### フィールド説明

| フィールド | 型 | 必須 | 説明 |
|-----------|-----|------|------|
| `name` | string | Yes | Watcher の一意な識別名。重複するとバリデーションエラー |
| `description` | string | No | Watcher の説明文 |
| `script_path` | string | Yes | Watcher スクリプトのパス。相対パスはプロジェクトルート（config/ の親）基準で解決 |
| `config_file` | string | Yes | 設定ファイル名。`config/` ディレクトリ配下に配置 |
| `enabled` | bool | Yes | `true` で有効、`false` で無効 |
| `auto_start` | bool | No | `--with-watcher=auto` 時に自動起動するか。デフォルト `true` |

### バリデーション

`validate_watchers_yaml()` が以下を検証します:

- `watchers` セクションが配列であること
- 各エントリに必須フィールド（`name`, `script_path`, `config_file`, `enabled`）が存在すること
- 各フィールドの型が正しいこと
- `name` が重複していないこと
- `script_path` のファイルが存在すること（存在しない場合は警告）

### フォールバック

`watchers.yaml` が存在しない場合、`github-watcher.yaml` が存在すれば `github_watcher` のみ登録された状態として動作します（後方互換）。

### 登録方法

```bash
# 1. watchers.yaml.example をコピー
cp config/watchers.yaml.example config/watchers.yaml

# 2. 新しい watcher エントリを追加
# config/watchers.yaml を編集

# 3. バリデーション実行
ignite validate
```

## 新規 Watcher 作成手順

### Step 1: スクリプトファイルを作成

```bash
touch scripts/utils/my_watcher.sh
chmod +x scripts/utils/my_watcher.sh
```

### Step 2: 基本構造を実装

```bash
#!/bin/bash
# my_watcher.sh — My Custom Watcher

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# core.sh が環境変数を上書きするため、source 前に退避・復元する
_SAVED_WORKSPACE="${WORKSPACE_DIR:-}"
_SAVED_RUNTIME="${IGNITE_RUNTIME_DIR:-}"
_SAVED_CONFIG="${IGNITE_CONFIG_DIR:-}"

# watcher_common.sh を読み込み（core.sh も含む）
source "${SCRIPT_DIR}/../lib/watcher_common.sh"

# 退避した環境変数を復元
[[ -n "$_SAVED_WORKSPACE" ]] && export WORKSPACE_DIR="$_SAVED_WORKSPACE"
[[ -n "$_SAVED_RUNTIME" ]] && export IGNITE_RUNTIME_DIR="$_SAVED_RUNTIME"
[[ -n "$_SAVED_CONFIG" ]] && export IGNITE_CONFIG_DIR="$_SAVED_CONFIG"

# ─── Watcher 固有の設定読み込み ───
MY_API_TOKEN=""
MY_TARGET=""

_load_my_config() {
    local config_file="$1"
    MY_API_TOKEN=$(yaml_get "$config_file" 'api_token')
    MY_TARGET=$(yaml_get "$config_file" 'target')
}

# ─── watcher_poll() を上書き定義 ───
watcher_poll() {
    # 1. 外部サービスからイベントを取得
    local events
    events=$(curl -s -H "Authorization: Bearer $MY_API_TOKEN" \
        "https://api.example.com/events?since=$(watcher_get_last_check 'my_events')")

    # 2. 各イベントを処理
    local event_id event_title
    while IFS= read -r line; do
        event_id=$(echo "$line" | jq -r '.id')
        event_title=$(echo "$line" | jq -r '.title')

        # 重複チェック
        if watcher_is_event_processed "my_event" "$event_id"; then
            continue
        fi

        # サニタイズ
        event_title=$(_watcher_sanitize_input "$event_title" 200)

        # 3. MIME メッセージを構築・送信
        local body_yaml="event_type: \"new_event\"
event_id: \"${event_id}\"
title: \"${event_title}\"
source: \"my_service\""

        watcher_send_mime "$_WATCHER_NAME" "leader" "my_event" "$body_yaml"

        # 処理済みマーク
        watcher_mark_event_processed "my_event" "$event_id"
    done <<< "$(echo "$events" | jq -c '.[]' 2>/dev/null)"

    # 最終チェック時刻を更新
    watcher_update_last_check "my_events"
}

# ─── 初期化・固有設定の読み込み・デーモン起動 ───
watcher_init "my_watcher" "${1:-}"
_load_my_config "$_WATCHER_CONFIG_FILE"
watcher_run_daemon
```

### Step 3: 設定ファイルを作成

`config/my-watcher.yaml`:

```yaml
# My Custom Watcher 設定
interval: 120          # ポーリング間隔（秒）
api_token: "your-token-here"
target: "my-target"
```

### Step 4: watchers.yaml に登録

```yaml
watchers:
  - name: github_watcher
    description: "GitHub Issue/PR イベント監視"
    script_path: scripts/utils/github_watcher.sh
    config_file: github-watcher.yaml
    enabled: true

  - name: my_watcher
    description: "My Custom Service 監視"
    script_path: scripts/utils/my_watcher.sh
    config_file: my-watcher.yaml
    enabled: true
```

### Step 5: バリデーションと起動テスト

```bash
# バリデーション
ignite validate

# IGNITE 起動時に --with-watcher で Watcher も起動
ignite start --with-watcher
```

## テスト方法

### bats テストの構造

`tests/` ディレクトリに `test_my_watcher.bats` を作成します:

```bash
#!/usr/bin/env bats
load test_helper

setup() {
    setup_temp_dir
    export IGNITE_CONFIG_DIR="$TEST_TEMP_DIR/config"
    export IGNITE_RUNTIME_DIR="$TEST_TEMP_DIR/runtime"
    mkdir -p "$IGNITE_CONFIG_DIR" "$IGNITE_RUNTIME_DIR/state" "$IGNITE_RUNTIME_DIR/queue/leader"
}

teardown() {
    cleanup_temp_dir
}

@test "watcher_init creates PID file" {
    source "$SCRIPTS_DIR/lib/watcher_common.sh"
    watcher_init "test_watcher" "$IGNITE_CONFIG_DIR/test-watcher.yaml"

    [ -f "$IGNITE_RUNTIME_DIR/state/test_watcher.pid" ]
}

@test "watcher_is_event_processed returns 1 for new event" {
    source "$SCRIPTS_DIR/lib/watcher_common.sh"
    watcher_init "test_watcher" "$IGNITE_CONFIG_DIR/test-watcher.yaml"

    run watcher_is_event_processed "test" "event_001"
    [ "$status" -eq 1 ]
}

@test "watcher_mark_event_processed then is_processed returns 0" {
    source "$SCRIPTS_DIR/lib/watcher_common.sh"
    watcher_init "test_watcher" "$IGNITE_CONFIG_DIR/test-watcher.yaml"

    watcher_mark_event_processed "test" "event_001"
    run watcher_is_event_processed "test" "event_001"
    [ "$status" -eq 0 ]
}

@test "_watcher_sanitize_input removes shell metacharacters" {
    source "$SCRIPTS_DIR/lib/watcher_common.sh"

    result=$(_watcher_sanitize_input 'hello; rm -rf /' 256)
    [[ "$result" != *";"* ]]
    [[ "$result" == *"；"* ]]
}
```

### テスト実行

```bash
bats tests/test_my_watcher.bats
```

## 命名規則

| 種別 | パターン | 例 |
|------|---------|-----|
| 公開関数 | `watcher_*` | `watcher_init`, `watcher_poll` |
| 内部関数 | `_watcher_*` | `_watcher_sanitize_input` |
| グローバル変数 | `_WATCHER_*` | `_WATCHER_NAME`, `_WATCHER_POLL_INTERVAL` |
| 状態ファイル | `state/{name}_state.json` | `state/my_watcher_state.json` |
| PIDファイル | `state/{name}.pid` | `state/my_watcher.pid` |
| 設定ファイル | `config/{name}.yaml` | `config/my-watcher.yaml`（アンダースコア→ハイフン） |

## シグナルハンドリング

`watcher_common.sh` が以下のシグナルを自動処理します:

| シグナル | 動作 |
|---------|------|
| `SIGHUP` | 設定ファイルの再読み込みを予約。次のループ開始時に `watcher_load_config` を再実行 |
| `SIGTERM` / `SIGINT` | グレースフルシャットダウン。現在の `watcher_poll()` 完了後に安全に停止 |
| `EXIT` | PIDファイル削除 + 終了ログ出力 |

設定変更を反映するには:

```bash
kill -HUP $(cat .ignite/state/my_watcher.pid)
```

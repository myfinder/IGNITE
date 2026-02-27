# Slack Watcher

Slack チャンネル/メンション監視機能を提供します。Slack Socket Mode (WebSocket) でリアルタイムにイベントを受信し、MIME メッセージとして Leader キューに送信します。

## アーキテクチャ

Shell ラッパー + Python subprocess のハイブリッド構成を採用しています。

```
slack_watcher.sh (shell wrapper)
  ├── watcher_common.sh を source（PID, シグナル, 状態, MIME）
  ├── slack_watcher.py をバックグラウンド起動
  ├── watcher_poll() オーバーライド:
  │     1. Python プロセスのヘルスチェック（死亡時は再起動）
  │     2. spool ディレクトリ (.ignite/tmp/slack_events/) からイベント読取
  │     3. 各イベント: サニタイズ → 重複排除 → MIME 構築 → leader キュー送信
  ├── watcher_heartbeat() オーバーライド（queue_monitor 用）
  └── SIGTERM → Python 子プロセスを kill → クリーンシャットダウン

slack_watcher.py (Python Socket Mode receiver)
  ├── slack-bolt SocketModeHandler.start() でブロッキング待機
  ├── app_mention イベント → JSON ファイルを spool に atomic write
  ├── インメモリ重複排除（event_ts ベース）
  └── SIGTERM → handler.close() → 正常終了
```

**IPC**: ファイルスプール（JSON）。Python が書き込み、Shell がポーリング読取。

## セットアップ

### 1. Slack App の作成

1. [Slack API](https://api.slack.com/apps) で新しい App を作成
2. **Socket Mode** を有効化し、App-Level Token (`xapp-...`) を生成
3. **Event Subscriptions** を有効化し、イベントを追加（下記の利用パターンを参照）
4. **OAuth & Permissions** でスコープを追加（下記の利用パターンを参照）
5. ワークスペースにインストールしてトークンを取得

### 利用パターン

Slack Watcher は **Bot Token** と **User Token** の2種類のトークンに対応しています。用途に応じて選択してください。

#### パターン A: Bot として監視（Bot Token: `xoxb-`）

Bot への `@mention` を検知する標準的な使い方です。

**Slack App 設定:**
- **Bot Token Scopes**: `app_mentions:read`, `channels:history`, `groups:history`（プライベート）, `chat:write`（応答用）
- **Event Subscriptions**: `app_mention`, `message.channels`（オプション）, `message.groups`（オプション）
- プライベートチャンネルを監視するには、Bot をそのチャンネルに **招待** する必要があります

**slack-watcher.yaml:**
```yaml
events:
  app_mention: true
  channel_message: false
```

#### パターン B: ユーザーとして監視（User Token: `xoxp-`）

自分（人間ユーザー）宛の `@mention` をプライベートチャンネル含めて検知したい場合に使います。

**Slack App 設定:**
- **User Token Scopes**: `channels:history`, `groups:history`
- **Event Subscriptions** → **Subscribe to events on behalf of users** に追加: `message.channels`, `message.groups`
  - 注意: 「Subscribe to bot events」ではなく「Subscribe to events on behalf of users」セクションに登録してください
- ユーザーが参加している全チャンネル（プライベート含む）のメッセージを受信できます。Bot の招待は不要です。
- ユーザー認可フロー（OAuth）でトークンを取得してください

**slack-watcher.yaml:**
```yaml
events:
  app_mention: false       # User Token では app_mention は不要
  channel_message: true    # チャンネルメッセージから自分宛 mention を検知
mention_filter:
  enabled: true
  user_ids: ["U01XYZ789"] # 自分の Slack User ID
```

> Slack User ID はプロフィール →「…」→「メンバーIDをコピー」で取得できます。

### 2. トークン設定

`.ignite/.env` にトークンを追加:

```bash
# Bot Token の場合
SLACK_TOKEN=xoxb-your-bot-token
# User Token の場合
SLACK_TOKEN=xoxp-your-user-token

SLACK_APP_TOKEN=xapp-your-app-token
```

### 3. 設定ファイル

```bash
cp config/slack-watcher.yaml.example config/slack-watcher.yaml
```

設定項目:

| キー | デフォルト | 説明 |
|------|----------|------|
| `interval` | `5` | spool 確認間隔（秒） |
| `events.app_mention` | `true` | @mention イベントの監視（Bot Token 用） |
| `events.channel_message` | `false` | チャンネルメッセージの監視 |
| `mention_filter.enabled` | `false` | メンションフィルタの有効化（User Token 用） |
| `mention_filter.user_ids` | `[]` | フィルタ対象の Slack User ID |
| `triggers.task_keywords` | (リスト) | `slack_task` として扱うキーワード |
| `access_control.enabled` | `false` | アクセス制御の有効化 |
| `access_control.allowed_users` | `[]` | 許可する Slack ユーザー ID |
| `access_control.allowed_channels` | `[]` | 許可する Slack チャンネル ID |

### 4. watchers.yaml への登録

`config/watchers.yaml` で `slack_watcher` を有効化:

```yaml
watchers:
  - name: slack_watcher
    description: "Slack チャンネル/メンション監視"
    script_path: scripts/utils/slack_watcher.sh
    config_file: slack-watcher.yaml
    enabled: true
    auto_start: true
```

## 起動

```bash
# watchers.yaml 経由で自動起動
ignite start

# 単独起動
./scripts/utils/slack_watcher.sh

# watcher 指定で起動
ignite start --with-watcher=slack_watcher
```

## メッセージタイプ

### slack_event

情報通知。タスクキーワードを含まないメンション/メッセージ。

```yaml
type: slack_event
from: slack_watcher
to: leader
payload:
  event_type: "app_mention"
  channel_id: "C01ABC123"
  user_id: "U01XYZ789"
  text: "@ignite-bot こんにちは"
  thread_ts: ""
  event_ts: "1234567890.654321"
  source: "slack_watcher"
```

### slack_task

タスクキーワード検出時の処理リクエスト。

```yaml
type: slack_task
from: slack_watcher
to: leader
priority: high
payload:
  event_type: "app_mention"
  channel_id: "C01ABC123"
  user_id: "U01XYZ789"
  text: "@ignite-bot implement login feature"
  thread_ts: "1234567890.123456"
  event_ts: "1234567890.654321"
  source: "slack_watcher"
```

## タスクキーワード

以下のキーワードがテキストに含まれる場合、`slack_task` として Leader に送信されます:

| カテゴリ | キーワード |
|---------|-----------|
| 実装・修正 | 実装して, 修正して, implement, fix |
| レビュー | レビューして, review |
| 質疑応答・調査 | 教えて, 調べて, 説明して, どうすれば, なぜ, explain, how to, why, what is |

`config/slack-watcher.yaml` の `triggers.task_keywords` でカスタマイズ可能です。

## Python 依存管理

初回起動時に `.ignite/venv/` に自動的に Python 仮想環境が作成されます:

- `python3 -m venv` で venv 作成
- `pip install -r slack_requirements.txt` でパッケージインストール
- 2回目以降は `requirements.txt` のハッシュでキャッシュ判定し、変更がなければスキップ
- グローバル pip install は行いません

**必須**: Python 3 と pip が利用可能であること。

## トラブルシューティング

### Python レシーバーが起動しない

```bash
# Python 環境を確認
python3 --version
python3 -m pip --version

# venv を再作成
rm -rf .ignite/venv/
./scripts/utils/slack_watcher.sh
```

### トークンエラー

```bash
# .env の設定を確認
cat .ignite/.env

# SLACK_APP_TOKEN が xapp- で始まることを確認
# SLACK_TOKEN が xoxb- または xoxp- で始まることを確認
```

### イベントが届かない

1. Slack App の **Event Subscriptions** が有効か確認
2. **Socket Mode** が有効か確認
3. Bot Token 使用時: Bot がチャンネルに追加されているか確認
4. User Token 使用時: ユーザーがチャンネルに参加しているか確認
5. spool ディレクトリを確認: `ls .ignite/tmp/slack_events/`

### ログ確認

```bash
# Watcher ログ
tail -f .ignite/logs/slack_watcher.log

# ハートビート確認
cat .ignite/state/slack_watcher_heartbeat.json
```

## 関連ドキュメント

- [Custom Watcher 作成ガイド](custom-watcher.md)
- [プロトコル仕様](protocol.md)

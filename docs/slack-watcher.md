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
| `mention_filter.enabled` | `false` | **誰宛の mention を処理するか**（メンション先フィルタ、User Token 用） |
| `mention_filter.user_ids` | `[]` | メンション先として検知する Slack User ID（この ID 宛のメンションを処理対象とする。送信者は問わない） |
| `triggers.task_keywords` | (リスト) | `slack_task` として扱うキーワード |
| `access_control.enabled` | `false` | **誰からのメッセージを処理するか**（送信者フィルタ） |
| `access_control.allowed_users` | `[]` | メッセージの送信者を制限する Slack ユーザー ID |
| `access_control.allowed_channels` | `[]` | メッセージのチャンネルを制限する Slack チャンネル ID |

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

## 応答機能

Slack Watcher は受信したメッセージに対して、Leader（LLM）が応答を判断し、Slack スレッドに返信を投稿できます。

### スレッドコンテキスト取得

メンション検知時にスレッド内の会話履歴を自動取得します:

- `thread_ts` がある場合: `conversations.replies` で最新50件のメッセージを取得
- `thread_ts` がない場合（単発メンション）: スレッド取得をスキップ、テキスト単体で Leader に渡す
- 取得した会話履歴は `thread_context` フィールドとして MIME body に含まれる

### Slack への投稿

`post_to_slack.sh` を使用してスレッドに返信を投稿します:

```bash
# 直接メッセージ投稿
./scripts/utils/post_to_slack.sh --channel C01ABC --thread-ts 1234.5678 --body "応答内容"

# テンプレートを使用
./scripts/utils/post_to_slack.sh --channel C01ABC --thread-ts 1234.5678 --template acknowledge
./scripts/utils/post_to_slack.sh --channel C01ABC --thread-ts 1234.5678 --template success --context "処理結果"
./scripts/utils/post_to_slack.sh --channel C01ABC --thread-ts 1234.5678 --template error --context "エラー詳細"
./scripts/utils/post_to_slack.sh --channel C01ABC --thread-ts 1234.5678 --template progress --context "50% 完了"

# ファイルから本文読み込み
./scripts/utils/post_to_slack.sh --channel C01ABC --thread-ts 1234.5678 --body-file /tmp/resp.txt
```

テンプレートタイプ:

| タイプ | 用途 |
|--------|------|
| `acknowledge` | タスク受付時の応答 |
| `success` | 処理完了時の応答 |
| `error` | エラー発生時の応答 |
| `progress` | 進捗報告 |

### 応答フロー

```
[受信]
Slack mention → slack_watcher.py
  ├─ thread_ts あり → conversations.replies(limit=50) でスレッド全文取得
  ├─ thread_ts なし → スキップ（テキスト単体）
  └─ spool JSON に thread_messages[] を含めて書き込み

[MIME 構築]
slack_watcher.sh
  └─ spool JSON → thread_context を YAML 化 → MIME body に含めて Leader キューへ

[判断・応答]
Leader (LLM)
  ├─ thread_context + text で文脈を理解
  ├─ 回答が必要か判断
  ├─ 必要 → post_to_slack.sh でスレッドに返信
  └─ 不要 → ログ記録のみ（Slack に投稿しない）
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

## 知識ベースとスキルのカスタマイズ

Slack からの質問に対して Leader が回答する際、ワークスペースに配置した知識ベースやスクリプトを活用できます。これらは IGNITE 本体のリポジトリに含める必要はなく、ワークスペース内に配置するだけで機能します。

### 知識ベース（静的ナレッジ）

ワークスペースに `CLAUDE.md`（または `AGENTS.md`）と `knowledge/` ディレクトリを配置すると、Leader がドメイン固有の質問に回答できるようになります。

```
workspace/
├── CLAUDE.md              # ナレッジのルーティング定義
├── AGENTS.md              # CLAUDE.md への symlink（OpenCode/Codex 用）
└── knowledge/
    ├── product-a.md       # プロダクト A の仕様ドキュメント
    └── product-b.md       # プロダクト B の仕様ドキュメント
```

**CLAUDE.md の例:**
```markdown
# ワークスペース知識ベース

## 知識ベース一覧

| トピック | ファイル | キーワード |
|---------|---------|-----------|
| Product A | `knowledge/product-a.md` | プロダクトA, ログイン, API |
| Product B | `knowledge/product-b.md` | プロダクトB, 設定, デプロイ |

## 回答ルール

1. 質問内容に関連するキーワードがあれば、該当するナレッジファイルを読んで回答する
2. ナレッジに記載がない場合は「知識ベースに該当情報がありません」と正直に伝える
3. 回答は簡潔に、Slack mrkdwn 形式で構成する
```

- ナレッジファイルの更新・追加時にシステムの再起動は **不要**（per-message パターンのため、次のメッセージ処理時に最新内容が読み込まれる）
- `AGENTS.md` は `CLAUDE.md` への symlink にしておくと、CLI プロバイダーに依存せず同一の知識ベースが参照される

### スキル（動的な情報取得スクリプト）

静的なナレッジだけでは回答できない場合に、Leader が外部 API を呼び出して情報を取得するスクリプトをワークスペースに配置できます。

```
workspace/
├── CLAUDE.md
├── knowledge/
└── scripts/
    └── search_github_docs.sh   # GitHub リポジトリからドキュメントを検索
```

**例: GitHub リポジトリのドキュメントを検索するスクリプト**

`.env` に設定された `GITHUB_TOKEN`（PAT）を使い、`curl` で GitHub REST API を呼び出してリポジトリ内のドキュメントや Issue を検索します。

```bash
# 使用例
./scripts/search_github_docs.sh --repo owner/repo --query "ログイン方法"
```

CLAUDE.md にスクリプトの存在と使い方を記述しておくことで、Leader が必要に応じて自律的にスクリプトを実行し、取得した情報をもとに Slack で回答します。

## 関連ドキュメント

- [Custom Watcher 作成ガイド](custom-watcher.md)
- [プロトコル仕様](protocol.md)

# CLI プロバイダー

IGNITE は 3 種類の CLI プロバイダーをサポートしています。全プロバイダーが **per-message + session resume** パターンで統一されています。

## 設定

`system.yaml` の `cli:` セクションで切り替えます:

```yaml
cli:
  provider: claude    # opencode / claude / codex
  model: claude-opus-4-6
```

### 利用可能なプロバイダー

| プロバイダー | コマンド | 動作モデル |
|---|---|---|
| `opencode` | `opencode run --format json` | per-message + `--session` で再開 |
| `claude` | `claude -p --output-format json` | per-message + `--resume` で再開 |
| `codex` | `codex exec --json --full-auto` | per-message + `exec resume` で再開 |

## 認証方式

### OpenCode

`.ignite/.env` に API キーを設定:

```bash
# .ignite/.env
OPENAI_API_KEY=sk-...
# または
ANTHROPIC_API_KEY=sk-ant-...
```

### Claude Code

#### Max Plan ログイン済み（推奨）

`ANTHROPIC_API_KEY` を設定せずに `claude` コマンドにログインしていれば、Max Plan のサブスクリプション枠で動作します。

```bash
# ログイン（初回のみ）
claude login
```

#### API キー方式

`.ignite/.env` に `ANTHROPIC_API_KEY` を設定すると、従量課金の API 経由で動作します。

```bash
# .ignite/.env
ANTHROPIC_API_KEY=sk-ant-...
```

**注意**: API キーが設定されている場合はそちらが優先されます。Max Plan 枠を使いたい場合は API キーを設定しないでください。

### Codex CLI

`.ignite/.env` に OpenAI API キーを設定:

```bash
# .ignite/.env
OPENAI_API_KEY=sk-...
```

## レート制限

- **Claude Code (Max Plan)**: 5 時間ごとにリセットされるレート制限。制限到達時は Opus から Sonnet に自動切替。大規模運用時は API キー方式を検討。
- **OpenCode / Codex**: API キーのレート制限に依存。

## attach コマンド

`ignite attach` はプロバイダーに応じた対話型接続を実行します:

```bash
ignite attach
# → エージェント一覧から選択
# → 確認プロンプト（queue_monitor との競合注意）
```

| プロバイダー | 接続コマンド |
|---|---|
| `claude` | `claude --resume <session_id>` |
| `opencode` | `opencode --session <session_id>` |
| `codex` | `codex resume <session_id>` |

**注意**: attach 中は queue_monitor からのメッセージ送信がロック待ち状態になります。作業が終わったら速やかに切断してください。

## プロバイダー比較

| 項目 | OpenCode | Claude Code | Codex CLI |
|---|---|---|---|
| プロセスモデル | per-message | per-message | per-message |
| セッション管理 | `--session <id>` | `--resume <id>` | `exec resume <id>` |
| メッセージ送信 | 同期 | 同期 | 同期 |
| flock タイムアウト | 600 秒 | 600 秒 | 600 秒 |
| 依存コマンド | `opencode jq` | `claude jq` | `codex jq` |
| インストラクション注入 | `opencode.json` の `instructions` | `--append-system-prompt` | stdin（初回プロンプトに結合） |

## トラブルシューティング

### `CLAUDECODE` 環境変数の競合

Claude Code セッション内から IGNITE を起動すると、`CLAUDECODE` 環境変数が設定されて入れ子実行の問題が発生する場合があります。IGNITE は起動時に `unset CLAUDECODE` を行いますが、問題が続く場合は手動で環境変数を解除してください:

```bash
unset CLAUDECODE
ignite start
```

### セッション破損

セッションが破損した場合は、`ignite stop -y` で停止後に再起動してください:

```bash
ignite stop -y
ignite start
```

### 応答が遅い

全プロバイダーが per-message でプロセスを起動するため、メッセージ送信に時間がかかる場合があります。queue_monitor の flock タイムアウトは 600 秒（10 分）に設定されています。

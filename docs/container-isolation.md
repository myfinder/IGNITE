# コンテナ隔離（Podman rootless）

## 概要

IGNITE v0.8.0 以降、エージェントは Podman rootless コンテナ内で実行されます。
これにより、エージェントがホスト環境に無制限にアクセスすることを防止します。

**デフォルト OFF（opt-in）** — `isolation.enabled: true` で明示的に有効化してください。

## 動機

- エージェントがホストの `gh` CLI を使って無断で PR を作成する問題（PR #342）
- エージェントが自身の bash 環境を自己破壊する問題
- Instructions（ソフト対策）は AI が無視する → 環境レベルのハード対策が必要

## アーキテクチャ

**1ワークスペース = 1常駐コンテナ。全エージェントが同一コンテナ内で動作。**

```
ignite start
  ├─ isolation_start_container(workspace)          ← コンテナ1個起動
  │
  ├─ cli_start_agent_server("leader", ...)
  │   └─ podman exec ignite-ws-xxxx claude -p ...  ← コンテナ内で初期セッション
  ├─ cli_start_agent_server("strategist", ...)
  │   └─ podman exec ignite-ws-xxxx claude -p ...
  │
  ├─ queue_monitor → cli_send_message(session_id, message)
  │   └─ podman exec ignite-ws-xxxx claude -p --resume ...
  │
  └─ ignite stop
      ├─ (agents cleanup)
      └─ isolation_stop_container()                ← コンテナ1個停止・削除
```

## 設定

`config/system.yaml`:

```yaml
isolation:
  enabled: true              # コンテナ隔離の有効/無効
  runtime: podman            # コンテナランタイム（現在 podman のみ）
  image: ignite-agent:latest # コンテナイメージ
  resource_memory: 8g        # メモリ上限（CLI 1プロセス約500MB × 9エージェント + OS）
  resource_cpus: 4           # CPU 上限
```

## 前提条件

- **Linux のみ対応**（macOS 非対応）
- **Podman** がインストール済みであること
- **Rootless モード** を推奨

### Podman インストール

```bash
# Ubuntu/Debian
sudo apt install podman

# Fedora/RHEL
sudo dnf install podman

# Arch
sudo pacman -S podman
```

## コンテナイメージ

### 自動ビルド

初回 `ignite start` 時にイメージが存在しなければ自動ビルドされます。

### 手動ビルド

```bash
./scripts/ignite build-image
```

### イメージの内容

- Ubuntu 24.04 ベース
- bash, curl, jq, python3, git, sqlite3, Node.js 22
- CLI ツール（cli.provider に応じて claude / opencode / codex）
- **意図的に含まないもの**: `gh` CLI, `ssh` クライアント

## マウント設計

| マウント先 | モード | 理由 |
|-----------|--------|------|
| `$WORKSPACE_DIR` | rw | ワークスペース操作 |
| `$IGNITE_RUNTIME_DIR` (.ignite/) | rw | queue/state/logs/repos/tmp |
| `$IGNITE_SCRIPTS_DIR` | ro | 認証フロー（safe_git_push 等） |
| `~/.claude/` | rw | セッション状態 + ログイン認証 |
| `~/.claude.json` | rw | Claude Code グローバル設定（ファイル単位マウント） |
| `~/.anthropic/` | ro | API キーキャッシュ |
| `~/.config/opencode/` | ro | OpenCode 設定 + 認証 |

### 意図的にマウントしないもの

- `~/.ssh/` — SSH 経由の git 操作を物理的に不可能にする
- `~/.gitconfig` — コンテナ内での意図しない git 設定適用を防止

## セキュリティ機能

| 機能 | 説明 |
|------|------|
| `--userns=keep-id` | ホスト UID をそのままマッピング |
| `--security-opt no-new-privileges` | 特権昇格を防止 |
| `--network=pasta` | 高速 rootless ネットワーク |
| `--memory` / `--cpus` | リソース制限 |
| gh CLI 未インストール | エージェントによる無断 PR 作成を防止 |
| SSH 未インストール | HTTPS + Token 認証のみ |

## コンテナリカバリ

queue_monitor がコンテナの生存を監視し、クラッシュ時は自動再起動します。

## 無効化

```yaml
# config/system.yaml
isolation:
  enabled: false
```

## 動作確認手順

コンテナ隔離の変更をした際は、以下の手順で必ず実機テストを行うこと。

### 1. ユニットテスト

```bash
make test
# 全テスト（isolation 関連含む）がパスすることを確認
```

### 2. 通常モード（isolation OFF）

```bash
# ワークスペース初期化（最新設定を反映）
./scripts/ignite init --force

# system.yaml で isolation.enabled: false を確認
grep 'enabled:' .ignite/system.yaml

# 起動 → 全9体 healthy → 停止
./scripts/ignite start
./scripts/ignite status          # 9/9 healthy を確認
./scripts/ignite stop -s <session-id>

# 残存プロセスなしを確認
ps aux | grep -E 'claude.*session-id|queue_monitor' | grep -v grep
```

### 3. 隔離モード（isolation ON）

```bash
# isolation を有効化
# .ignite/system.yaml: isolation.enabled: true

# イメージ確認（なければビルド）
podman images | grep ignite-agent

# 起動 → コンテナ起動 → 全9体 healthy → 停止
./scripts/ignite start
podman ps --filter name=ignite-ws   # コンテナが running であること
./scripts/ignite status              # 9/9 healthy + コンテナ情報表示

# リソース制限の確認
podman inspect <container-name> --format '{{.HostConfig.Memory}} {{.HostConfig.NanoCpus}} {{.HostConfig.SecurityOpt}}'

# 停止 → コンテナ削除まで確認
./scripts/ignite stop -s <session-id>
podman ps -a --filter name=ignite-ws   # コンテナが完全に削除されていること
```

### 確認ポイント

| 項目 | 確認方法 |
|------|----------|
| 全9体起動 | `ignite status` で 9/9 healthy |
| コンテナ起動 | `podman ps` で ignite-ws-* が running |
| リソース制限 | `podman inspect` で memory/cpus/security-opt |
| 正常停止 | `ignite stop` 後にコンテナ・プロセスとも残存なし |
| ダッシュボード更新 | `cat .ignite/dashboard.md` でエージェントログ表示 |
| queue_monitor | `ignite status` でキューモニター running |

## トラブルシューティング

### podman がインストールされていない

```
[ERROR] podman がインストールされていません
```

→ Podman をインストールするか、`isolation.enabled: false` で無効化。

### イメージビルドに失敗

```bash
# 手動ビルド（デバッグ用）
podman build -f containers/Containerfile.agent --build-arg CLI_PROVIDER=claude -t ignite-agent:latest containers/
```

### コンテナが起動しない

```bash
# コンテナの状態確認
podman ps -a | grep ignite-ws

# ログ確認
podman logs ignite-ws-xxxxxxxx
```

### .env の変更が反映されない

`.ignite/.env` はコンテナ起動時（`podman run --env-file`）に読み込まれます。
コンテナ実行中に `.env` を変更しても `podman exec` には反映されません。

→ `.env` 変更後は `ignite stop && ignite start` でコンテナを再起動してください。

### git commit に user.name/email が必要

`.ignite/.env` に設定:

```
GIT_AUTHOR_NAME=ignite-bot
GIT_AUTHOR_EMAIL=ignite-bot@example.com
GIT_COMMITTER_NAME=ignite-bot
GIT_COMMITTER_EMAIL=ignite-bot@example.com
```

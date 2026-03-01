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

> **同一ホストで CLI プロバイダーが異なる複数ワークスペースを運用する場合**、イメージ名を分けてください。
> イメージには `cli.provider` で指定された CLI のみがインストールされるため、
> 先にビルドされたイメージが別ワークスペースで使い回されると CLI が見つからずエージェント起動に失敗します。
>
> ```yaml
> # Claude Code を使うワークスペース
> isolation:
>   image: ignite-agent-claude:latest
>
> # Codex CLI を使うワークスペース
> isolation:
>   image: ignite-agent-codex:latest
> ```

## 前提条件

- **Linux のみ対応**（macOS 非対応）
- **Podman** がインストール済みであること
- **passt** がインストール済みであること（pasta ネットワーク用）
- **Rootless モード** を推奨

### 必要パッケージの一括インストール

```bash
# Ubuntu/Debian
sudo apt install podman passt

# Fedora/RHEL
sudo dnf install podman passt

# Arch
sudo pacman -S podman passt
```

> **注意**: `passt` は Podman rootless の高速ネットワークモード（`--network=pasta`）に必要です。
> インストールされていない場合、コンテナ起動時に `unable to find network with name or ID pasta` エラーが発生します。

### cgroup 設定（GCE / クラウド VM 等）

クラウド VM など systemd user session が利用できない環境では、`podman build` 時に以下のエラーが発生します:

```
sd-bus call: Interactive authentication required.: Permission denied
```

この場合、cgroup manager を明示的に `cgroupfs` に設定してください:

```bash
mkdir -p ~/.config/containers
cat > ~/.config/containers/containers.conf <<'EOF'
[engine]
cgroup_manager = "cgroupfs"
events_logger = "file"
EOF
```

併せて lingering を有効化しておくことを推奨します:

```bash
sudo loginctl enable-linger $(id -u)
```

> **設定変更後は SSH を再接続**してください。`containers.conf` の変更は現在のシェルセッションには即時反映されません。

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

### カスタム Containerfile

追加パッケージや独自ツールを含むカスタムイメージを使用できます。

#### 指定方法（3つ）

1. **`system.yaml` で指定** — チームで共有する場合に推奨

    ```yaml
    isolation:
      containerfile: "Containerfile.custom"   # 相対パスはワークスペースルート基準
    ```

2. **`.ignite/containers/Containerfile.agent` に配置** — ワークスペースローカル

    ```bash
    mkdir -p .ignite/containers
    cp /path/to/my/Containerfile .ignite/containers/Containerfile.agent
    ```

3. **`-f` オプションで直接指定** — 一時的なテスト用

    ```bash
    ./scripts/ignite build-image -w . -f /path/to/Containerfile.custom
    ```

#### 検索順序

| 優先度 | ソース | 種別 |
|--------|--------|------|
| 1 | CLI `-f` 指定 | カスタム |
| 2 | `system.yaml` の `isolation.containerfile` | カスタム |
| 3 | `.ignite/containers/Containerfile.agent` | カスタム |
| 4 | `${IGNITE_DATA_DIR}/containers/Containerfile.agent`（インストール先） | デフォルト |
| 5 | `${SCRIPT_DIR}/../containers/Containerfile.agent`（開発時） | デフォルト |

#### ビルドコンテキストの違い

- **カスタム Containerfile**（優先度 1-3）: ビルドコンテキストは `${WORKSPACE_DIR}`（ワークスペースルート）
- **デフォルト Containerfile**（優先度 4-5）: ビルドコンテキストは Containerfile のあるディレクトリ

カスタム時はワークスペースのファイルを `COPY` できますが、ビルドコンテキストの肥大化を防ぐため
`.ignite/.containerignore` が自動生成されます（`ignite init` 時）。
ビルド時には `--ignorefile .ignite/.containerignore` が自動付与されます。

#### `.containerignore` のカスタマイズ

`.ignite/.containerignore` は手動で編集可能です。独自のパターンを追加してください。
`ignite init --update=apply` では差分ファイルとして検出されますが、`--update=force` を使わない限り上書きされません。

#### `ignite start` 経由の自動ビルド

`ignite start` の自動ビルドでは CLI `-f` オプションは使用できません。
`system.yaml` の `isolation.containerfile` または `.ignite/containers/Containerfile.agent` で指定してください。

## マウント設計

| マウント先 | モード | 理由 |
|-----------|--------|------|
| `$WORKSPACE_DIR` | rw | ワークスペース操作 |
| `$IGNITE_RUNTIME_DIR` (.ignite/) | rw | queue/state/logs/repos/tmp |
| `$IGNITE_SCRIPTS_DIR` | ro | 認証フロー（safe_git_push 等） |

### 起動時コピー（バインドマウントしないもの）

以下のファイルはバインドマウントではなく、コンテナ起動時に `podman cp` でコピーされます。

| コピー元 | 理由 |
|---------|------|
| `~/.claude/` | Claude Code セッション状態 + ログイン認証 |
| `~/.claude.json` | Claude Code グローバル設定 |
| `~/.anthropic/` | Anthropic API キーキャッシュ |
| `~/.config/opencode/` | OpenCode 設定 + 認証 |
| `~/.codex/` | Codex CLI 設定 + 認証 |

**背景**: CLI ツールは設定ファイルを非アトミックに読み書きするため、
複数コンテナがバインドマウントで同一ファイルを共有するとファイル破損が発生します（Issue #354）。
各コンテナが独立したコピーを持つことで、書き込み競合を構造的に回避しています。
コンテナ内での変更はホストに書き戻されません（次回起動時にホストから最新がコピーされます）。

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

## Podman 運用コマンド

### コンテナの確認

```bash
# 実行中のコンテナ一覧
podman ps --filter name=ignite-ws

# 停止済みを含む全コンテナ
podman ps -a --filter name=ignite-ws
```

### コンテナ内の確認

```bash
# コンテナ内でコマンド実行
podman exec ignite-ws-xxxxxxxx <command>

# CLI が正しくインストールされているか確認
podman exec ignite-ws-xxxxxxxx which claude
podman exec ignite-ws-xxxxxxxx claude --version

# 認証情報の確認
podman exec ignite-ws-xxxxxxxx ls -la ~/.claude/

# コンテナ内のシェルに入る（デバッグ用）
podman exec -it ignite-ws-xxxxxxxx bash
```

### イメージの管理

```bash
# イメージ一覧
podman images | grep ignite-agent

# イメージの削除（再ビルドしたい場合）
podman rmi ignite-agent:latest ignite-agent:v0.8.0

# CLI プロバイダー別にイメージ名を分けている場合
podman rmi ignite-agent-codex:latest ignite-agent-codex:v0.8.0
```

### コンテナの手動停止・削除

```bash
# 特定のコンテナを強制削除
podman rm -f ignite-ws-xxxxxxxx

# IGNITE 関連コンテナを全削除
podman rm -f $(podman ps -a --filter name=ignite-ws -q)
```

### リソース確認

```bash
# コンテナのリソース制限を確認
podman inspect ignite-ws-xxxxxxxx --format '{{.HostConfig.Memory}} {{.HostConfig.NanoCpus}} {{.HostConfig.SecurityOpt}}'

# コンテナのリアルタイムリソース使用量
podman stats --filter name=ignite-ws --no-stream
```

### 全リセット

```bash
# Podman の全データを初期化（イメージ・コンテナ・キャッシュを全削除）
podman system reset --force
```

> **注意**: `podman system reset` は全イメージを削除します。次回 `ignite start` 時にイメージが自動リビルドされます。

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

### CLI が見つからない（エージェント起動が全失敗）

```
[ERROR] Claude Code の初期化レスポンスが取得できませんでした
```

コンテナ内に CLI がインストールされていない可能性があります。
ビルドキャッシュが原因で CLI インストールステップがスキップされた場合に発生します。

```bash
# CLI の存在確認
podman exec ignite-ws-xxxxxxxx which claude   # → "not found" なら未インストール

# 解決: イメージを削除して再ビルド
ignite stop
podman rm -f $(podman ps -a --filter name=ignite-ws -q)
podman rmi ignite-agent:latest ignite-agent:v0.8.0
ignite start -w .   # イメージが自動リビルドされる
```

### ignite stop してもコンテナが残る

セッションが見つからない場合（エージェント起動全失敗後など）、コンテナ停止処理がスキップされることがあります（v0.8.0 で修正済み）。

```bash
# 手動でコンテナを削除
podman rm -f $(podman ps -a --filter name=ignite-ws -q)

# state ファイルも削除
rm -f .ignite/state/container_name
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

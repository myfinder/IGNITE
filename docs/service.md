# IGNITE Service（systemd統合）使用ガイド

このドキュメントでは、IGNITEをsystemdユーザーサービスとして管理する方法を説明します。

## 概要

IGNITE Serviceは、systemdのテンプレートユニットを使用してIGNITEシステムをサービスとして管理する機能です。サーバー環境でのログアウト後も継続稼働、OS再起動時の自動復旧をサポートします。

### 主な機能

- **systemd統合**: ユーザーサービスとしてIGNITEを管理
- **複数ワークスペース**: テンプレートユニット `ignite@.service` で独立管理
- **自動起動**: `enable` + `loginctl enable-linger` でOS再起動後も自動復旧
- **ジャーナルログ**: `journalctl` でログの一元管理
- **環境変数管理**: `~/.config/ignite/env` で機密情報を安全に管理
- **--daemonフラグ**: systemd `Type=forking` との連携

### アーキテクチャ

```mermaid
flowchart TB
    subgraph systemd["systemd (user)"]
        Unit["ignite@&lt;session&gt;.service<br/>Type=forking"]
        Watcher["ignite-watcher@&lt;session&gt;.service"]
    end

    subgraph IGNITE["IGNITE プロセス"]
        Start["ignite start --daemon"]
        Tmux["tmux セッション"]
        Leader["Leader"]
        SubLeaders["Sub-Leaders"]
        IGNITIANs["IGNITIANs"]

        Start -->|"PIDファイル書出し<br/>exit 0"| Tmux
        Tmux --> Leader
        Tmux --> SubLeaders
        Tmux --> IGNITIANs
    end

    subgraph Config["設定"]
        EnvFile["~/.config/ignite/env<br/>chmod 600"]
    end

    Unit -->|"ExecStart=<br/>ignite start --daemon"| Start
    Unit -->|"EnvironmentFile="| EnvFile
    systemd -->|"journalctl"| Watcher

    style Unit fill:#4ecdc4,color:#fff
    style Tmux fill:#ff6b6b,color:#fff
    style EnvFile fill:#ffeaa7,color:#333
```

## 前提条件

| 要件 | 最小バージョン | 確認コマンド |
|------|--------------|------------|
| systemd | 246+ | `systemctl --version` |
| tmux | 3.0+ | `tmux -V` |
| bash | 5.0+ | `bash --version` |
| loginctl | — | `loginctl --version` |

> **⚠️ 重要:** `loginctl enable-linger` を実行しないと、ログアウト後にサービスが停止します。

```bash
# linger を有効化（必須）
loginctl enable-linger $(whoami)

# 確認
loginctl show-user $(whoami) --property=Linger
# 出力: Linger=yes
```

## クイックスタート

```bash
# 1. ユニットファイルをインストール
ignite service install

# 2. 環境変数を設定（APIキーなど）
ignite service setup-env

# 3. サービスを有効化（自動起動設定）
ignite service enable my-project

# 4. linger を有効化（ログアウト後も維持）
loginctl enable-linger $(whoami)

# 5. サービスを開始
ignite service start my-project
```

> **📝 注意:** `ignite service install` はPR2（systemdテンプレートユニット追加）マージ後に使用可能です。現時点では `ignite start --daemon` でのdaemonモード使用を推奨します。

## サブコマンドリファレンス

### `install` — ユニットファイルのインストール

テンプレートユニットファイル `ignite@.service` を `~/.config/systemd/user/` にインストールします。

**書式:**

```bash
ignite service install [--force]
```

**オプション:**

| オプション | 説明 |
|-----------|------|
| `-y`, `--yes`, `--force` | 既存ファイルを確認なしで上書き |

**使用例:**

```bash
# 通常インストール
ignite service install

# 強制上書き
ignite service install --force
```

**出力例:**

```
ユニットファイルをインストール中...
✓ ignite@.service をインストールしました
✓ ignite-watcher@.service をインストールしました
systemd daemon-reload を実行中...
✓ daemon-reload 完了

インストール完了

次のステップ:
  1. 環境変数を設定: ignite service setup-env
  2. サービスを有効化: ignite service enable <session>
  3. linger 有効化: loginctl enable-linger <user>
```

**ユニットファイル検索パス（優先順）:**

| 優先度 | パス |
|--------|------|
| 1（最高） | `$IGNITE_DATA_DIR/templates/systemd/` |
| 2 | `$IGNITE_CONFIG_DIR/` |
| 3（最低） | `$PROJECT_ROOT/templates/systemd/` |

---

### `uninstall` — ユニットファイルのアンインストール

稼働中のサービスを停止・無効化し、ユニットファイルを削除します。

**書式:**

```bash
ignite service uninstall
```

**使用例:**

```bash
ignite service uninstall
```

**動作:**

1. 稼働中の `ignite@*.service` を検出
2. 各サービスを `stop` → `disable`
3. ユニットファイルを削除
4. `systemctl --user daemon-reload`

---

### `enable` — サービスの有効化

指定セッションのサービスを有効化します。`loginctl enable-linger` と組み合わせることで、OS再起動時に自動起動します。

**書式:**

```bash
ignite service enable <session>
```

**使用例:**

```bash
ignite service enable my-project
```

---

### `disable` — サービスの無効化

指定セッションの自動起動を無効化します。

**書式:**

```bash
ignite service disable <session>
```

**使用例:**

```bash
ignite service disable my-project
```

---

### `start` — サービスの開始

指定セッションのサービスを開始します。

**書式:**

```bash
ignite service start <session>
```

**使用例:**

```bash
ignite service start my-project
```

---

### `stop` — サービスの停止

指定セッションのサービスを停止します。

**書式:**

```bash
ignite service stop <session>
```

**使用例:**

```bash
ignite service stop my-project
```

---

### `restart` — サービスの再起動

指定セッションのサービスを再起動します。

**書式:**

```bash
ignite service restart <session>
```

**使用例:**

```bash
ignite service restart my-project
```

---

### `status` — サービスの状態表示

指定セッションまたは全IGNITEサービスの状態を表示します。

**書式:**

```bash
ignite service status [session]
```

**使用例:**

```bash
# 全サービス一覧
ignite service status

# 特定セッション
ignite service status my-project
```

**出力例（全サービス）:**

```
=== IGNITE サービス状態 ===

ignite@my-project.service loaded active running IGNITE my-project
ignite@staging.service    loaded active running IGNITE staging
```

---

### `logs` — ジャーナルログの表示

`journalctl` を使用してサービスのログを表示します。

**書式:**

```bash
ignite service logs <session> [--no-follow]
```

**オプション:**

| オプション | 説明 |
|-----------|------|
| `--no-follow` | リアルタイム追跡を無効化（デフォルトは `-f` 有効） |

**使用例:**

```bash
# リアルタイムログ表示
ignite service logs my-project

# 過去ログのみ表示
ignite service logs my-project --no-follow
```

---

### `setup-env` — 環境変数ファイルの生成

systemdサービスで使用する環境変数ファイルを対話的に生成します。

**書式:**

```bash
ignite service setup-env [--force]
```

**オプション:**

| オプション | 説明 |
|-----------|------|
| `-y`, `--yes`, `--force` | 既存ファイルを確認なしで上書き |

**使用例:**

```bash
ignite service setup-env
```

**生成ファイル:** `~/.config/ignite/env`

---

### `help` — ヘルプ表示

serviceコマンドの使用方法を表示します。

**書式:**

```bash
ignite service help
```

---

## `--daemon` フラグ

`ignite start --daemon` は、systemd `Type=forking` との連携を目的としたフラグです。

### 通常モード vs daemonモード

| 項目 | 通常モード | daemonモード (`--daemon`) |
|------|----------|------------------------|
| コマンド | `ignite start` | `ignite start --daemon` |
| tmuxセッション | 作成 | 作成 |
| 起動後の動作 | アタッチプロンプト表示 | PIDファイル書出し → `exit 0` |
| プロセス終了 | tmux detach まで維持 | 即座に終了（tmuxは残存） |
| systemd連携 | 不可 | `Type=forking` で連携可能 |
| PIDファイル | なし | `<workspace>/ignite-daemon.pid` |

### systemd Type=forking との連携

`--daemon` フラグを指定すると、`ignite start` プロセスは以下の動作をします:

1. tmuxセッションを作成・エージェントを起動
2. PIDファイル `<workspace>/ignite-daemon.pid` に自身のPIDを書出し
3. `exit 0` でプロセスを終了

systemdはこの `exit 0` を「フォーク完了」として解釈し、サービスを `active (running)` 状態に遷移させます。tmuxセッションはバックグラウンドで稼働し続けます。

### 暗黙的に有効化されるオプション

`--daemon` を指定すると、以下のオプションが自動的に有効化されます:

| オプション | 理由 |
|-----------|------|
| `--no-attach` | 非対話環境で使用するため |
| `--force` | 既存セッションを自動クリーンアップ |

### 使用例

```bash
# 手動でdaemonモードを使用（systemdなし）
ignite start --daemon -s my-project -w ~/workspace/my-project

# PIDファイルの確認
cat ~/workspace/my-project/ignite-daemon.pid

# プロセスの確認（tmuxセッション）
tmux list-sessions | grep my-project
```

---

## 環境ファイル設定

### ファイルパス

```
~/.config/ignite/env
```

> **⚠️ セキュリティ:** APIキーを含むため、必ず `chmod 600` を設定してください。

### 変数テーブル

| 変数名 | 必須 | 説明 | 例 |
|--------|------|------|-----|
| `PATH` | ✓ | 実行パス | `${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin` |
| `HOME` | ✓ | ホームディレクトリ | `/home/user` |
| `TERM` | ✓ | ターミナルタイプ | `xterm-256color` |
| `ANTHROPIC_API_KEY` | ✓ | Anthropic APIキー | `sk-ant-...` |
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | — | チーム機能有効化 | `1` |
| `XDG_CONFIG_HOME` | — | XDG設定ディレクトリ | `${HOME}/.config` |
| `XDG_DATA_HOME` | — | XDGデータディレクトリ | `${HOME}/.local/share` |

### 環境ファイルの例

```ini
# IGNITE - systemd EnvironmentFile
# chmod 600 ~/.config/ignite/env

PATH=/home/user/.local/bin:/usr/local/bin:/usr/bin:/bin
HOME=/home/user
TERM=xterm-256color

ANTHROPIC_API_KEY=sk-ant-api03-xxxxxxxxxxxx
CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1

XDG_CONFIG_HOME=/home/user/.config
XDG_DATA_HOME=/home/user/.local/share
```

---

## トラブルシューティング

### linger が有効になっていない

**症状:** ログアウト後にサービスが停止する

**原因:** `loginctl enable-linger` が実行されていない

**解決方法:**

```bash
# linger を有効化
loginctl enable-linger $(whoami)

# 確認
loginctl show-user $(whoami) --property=Linger
```

---

### ユニットファイルが見つからない

**症状:** `ignite service install` で「テンプレートユニットファイルが見つかりません」エラー

**原因:** `ignite@.service` テンプレートがインストールパスに存在しない

**解決方法:**

```bash
# テンプレートファイルの検索パスを確認
ls ${IGNITE_DATA_DIR:-~/.local/share/ignite}/templates/systemd/
ls ${PROJECT_ROOT}/templates/systemd/

# 手動コピー（テンプレートが見つかった場合）
mkdir -p ~/.config/systemd/user
cp templates/systemd/ignite@.service ~/.config/systemd/user/
systemctl --user daemon-reload
```

> **📝 注意:** `ignite service install` はPR2（systemdテンプレートユニット追加）マージ後に使用可能です。PR2マージ前は `ignite start --daemon` を使用してください。

---

### D-Bus 接続失敗

**症状:** `Failed to connect to bus: No medium found` エラー

**原因:** SSHセッションで `XDG_RUNTIME_DIR` が未設定

**解決方法:**

```bash
# 環境変数を設定
export XDG_RUNTIME_DIR="/run/user/$(id -u)"

# systemctl が動作するか確認
systemctl --user status
```

---

### 権限エラー

**症状:** `Failed to enable unit: Access denied` エラー

**原因:** ユーザーサービスの権限問題

**解決方法:**

```bash
# ユニットディレクトリの権限確認
ls -la ~/.config/systemd/user/

# 権限修正
chmod 644 ~/.config/systemd/user/ignite@.service
systemctl --user daemon-reload
```

---

### tmuxセッションが残留

**症状:** `ignite service stop` 後もtmuxセッションが残る

**原因:** systemd停止がPIDプロセスのみ終了し、tmuxは独立プロセス

**解決方法:**

```bash
# 残留セッションの確認
tmux list-sessions | grep ignite

# 手動クリーンアップ
tmux kill-session -t <session-name>

# または ignite stop を使用
ignite stop -s <session-name>
```

---

## daemon → service 移行ガイド

> **⚠️ 非推奨告知:** `nohup` / `screen` / 手動バックグラウンド実行は非推奨です。`ignite service` またはは `ignite start --daemon` を使用してください。

### 移行手順

| 手順 | 従来の方法 | 新しい方法 |
|------|----------|----------|
| 起動 | `nohup ignite start &` | `ignite service start <session>` |
| 停止 | `kill $(cat pid)` | `ignite service stop <session>` |
| ログ確認 | `tail -f nohup.out` | `ignite service logs <session>` |
| 自動起動 | cron `@reboot` | `ignite service enable <session>` |
| 状態確認 | `ps aux \| grep ignite` | `ignite service status` |

### 段階的移行

1. **Phase 1（現在）**: `ignite start --daemon` でdaemonモード使用
2. **Phase 2（PR2マージ後）**: `ignite service install` でユニットファイル導入
3. **Phase 3**: `ignite service enable` で自動起動設定、cron `@reboot` 削除

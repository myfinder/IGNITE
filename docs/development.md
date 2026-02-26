# 開発者ガイド

IGNITE の開発環境セットアップと開発ワークフローについて説明します。

## 前提条件

### 必須ツール（開発・テスト用）

| ツール | 用途 | インストール |
|--------|------|-------------|
| bash (4.0+) | シェルスクリプト実行 | OS標準 |
| curl | HTTP通信 | `apt install curl` |
| jq | JSON処理 | `apt install jq` |
| sqlite3 | メモリDB | `apt install sqlite3` |
| bats | テストフレームワーク | `apt install bats` |
| git | バージョン管理 | `apt install git` |
| GNU parallel | テスト並列実行 | `apt install parallel` |

### 任意ツール

| ツール | 用途 | インストール |
|--------|------|-------------|
| yq (v4.30+) | YAML処理 | [公式サイト](https://github.com/mikefarah/yq) |
| python3 | ユーティリティ | `apt install python3` |
| podman | コンテナ隔離 | `apt install podman` |
| shellcheck | 静的解析 | `apt install shellcheck` |

### 実行時ツール（CLI プロバイダ）

`ignite start` で実際にエージェントを起動するには、以下のいずれか1つが必要です:

| ツール | 説明 |
|--------|------|
| opencode | デフォルトの CLI プロバイダ |
| claude | Claude Code CLI |
| codex | Codex CLI |

`config/system.yaml` の `cli.provider` で使用するプロバイダを設定します。テストの実行にはこれらは不要です。

## セットアップ手順

```bash
# 1. リポジトリをクローン
git clone <repo-url>
cd ignite

# 2. 開発環境チェック
make dev

# 3. 動作確認
./scripts/ignite --help
```

`make dev` は `scripts/dev-setup.sh` を実行し、必須ツールの存在確認・既存インストールの検出・実行権限の確認を行います。

## リポジトリ直接実行

開発時は `install.sh` によるインストールは **不要** です。リポジトリチェックアウトから直接実行できます:

```bash
./scripts/ignite --help
./scripts/ignite init -w /path/to/workspace
./scripts/ignite start -w /path/to/workspace
```

`scripts/lib/core.sh` が `PROJECT_ROOT` を自動解決し、設定ファイル・インストラクション・スクリプトをリポジトリ内から読み込みます。ソースを編集すれば即座に反映されるため、二重管理の問題がありません。

## Make ターゲット

```bash
make help     # ヘルプ表示（デフォルト）
make dev      # 開発環境セットアップ（依存ツール確認）
make test     # 全テスト実行（bats 並列）
make lint     # shellcheck による静的解析
make start    # テストワークスペース (/tmp/ignite-dev-ws) で起動
make stop     # テストワークスペース停止
make clean    # テストワークスペース削除
```

## テスト

### 全テスト実行

```bash
make test
# または直接:
bats --jobs "$(($(nproc) * 8))" tests/
```

### 特定テストの実行

```bash
bats tests/test_cmd_start_init.bats
```

### テストの追加

- テストファイルは `tests/` ディレクトリに `test_*.bats` の命名規則で配置
- 既存テストのパターンに従って `setup()` / `teardown()` を定義
- ライブラリ関数のテストでは `source` でモジュールを読み込み、モック関数でスタブ化

## コンテナ隔離開発

コンテナ隔離機能を開発する場合:

1. **podman** をインストール（rootless モード推奨）
2. `config/system.yaml` で `isolation.enabled: true` を設定
3. コンテナイメージをビルド: `containers/` ディレクトリを参照

podman が利用できない環境では `isolation.enabled: false` を設定すればコンテナなしで動作します。

## コーディング規約

CLAUDE.md の「コーディング規約」セクションを参照してください。

## install.sh の位置づけ

`install.sh` は **エンドユーザー向け** のインストーラーです。`~/.local/share/ignite/` にスクリプトをコピーし、`~/.local/bin/ignite` にシンボリックリンクを作成します。

開発者はこのインストーラーを使用する必要はありません。リポジトリからの直接実行で開発できます。

## PATH 競合の注意事項

`install.sh` で既にインストール済みの環境では、`~/.local/bin/ignite` が PATH に含まれている場合があります。この場合、単に `ignite` と入力するとインストール版が実行されます。

開発中は以下のいずれかの方法で対応してください:
- `./scripts/ignite` でフルパス指定して実行
- `make start` / `make stop` など Make ターゲットを使用
- 一時的に `~/.local/bin/ignite` をリネームまたは削除

## トラブルシューティング

### `make test` で "parallel: command not found"

GNU parallel がインストールされていません:
```bash
# Ubuntu/Debian
sudo apt install parallel
# macOS
brew install parallel
```

### `bats: command not found`

bats-core をインストールしてください:
```bash
# Ubuntu/Debian
sudo apt install bats
# macOS
brew install bats-core
```

### 既存インストールと競合する

`make dev` を実行すると既存インストールの検出・警告が表示されます。開発中は `./scripts/ignite` を直接使用してください。

### shellcheck エラー

`make lint` で検出された問題を修正してください。shellcheck の警告は CI でもチェックされます。

# 既存リポジトリへの IGNITE 導入ガイド

既存のプロダクトリポジトリに IGNITE を導入し、エージェントがプロダクトのコードベースを直接操作できるようにする手順です。

## 概要

IGNITE はプロダクトリポジトリのルートに `.ignite/` ディレクトリを作成し、ワークスペースとして使用します。これにより、エージェントはプロダクトのコード・設定・ドキュメントを直接参照しながら作業できます。

### メリット

- エージェントがプロダクトの CLAUDE.md やコーディング規約を自動的に認識
- コードベース全体を検索・参照した上でタスクを実行
- PR 作成時にプロダクトの差分を直接把握
- `.ignite/` 内のランタイムデータは `.gitignore` で自動除外

## セットアップ手順

### 前提条件

- IGNITE がインストール済み（`ignite --version` で確認）
- 対象リポジトリがローカルにクローン済み

### 1. リポジトリで `ignite init` を実行

```bash
cd /path/to/your-product-repo
ignite init
```

以下のファイルが `.ignite/` 配下に生成されます：

```
your-product-repo/
├── .ignite/
│   ├── .gitignore          # ランタイムデータ除外設定
│   ├── system.yaml         # IGNITE システム設定
│   ├── characters.yaml     # キャラクター設定
│   ├── github-watcher.yaml.example
│   ├── github-app.yaml.example
│   ├── .env.example        # 環境変数テンプレート
│   ├── instructions/       # エージェントプロンプト
│   └── characters/         # キャラクター定義
├── src/                    # プロダクトのコード
├── CLAUDE.md               # プロダクトの規約（あれば）
└── ...
```

最小構成で初期化する場合：

```bash
ignite init --minimal    # system.yaml のみ
```

### 2. `.ignite/` を `.gitignore` に追加

プロダクトリポジトリのルートの `.gitignore` に追加します：

```bash
echo '.ignite/' >> .gitignore
```

> **Note**: `.ignite/.gitignore` はランタイムデータ（`queue/`, `logs/`, `state/` 等）を除外するためのものです。`.ignite/` 自体をコミットしたい場合（チーム共有）はこの手順をスキップしてください。

### 3. 設定をカスタマイズ

```bash
# システム設定を編集
vi .ignite/system.yaml
```

主な設定項目：

| 設定 | 説明 | デフォルト |
|------|------|-----------|
| `model` | 使用する LLM モデル | （system.yaml 参照） |
| `defaults.worker_count` | IGNITIANS 並列数 | 3 |
| `queue.poll_interval` | キューポーリング間隔（秒） | 10 |
| `queue.parallel_max` | メッセージ配信の最大並列数（エージェント単位） | 9 |

### 4. 環境変数を設定

```bash
cp .ignite/.env.example .ignite/.env
vi .ignite/.env
```

API キー等の秘密情報を設定します。`.env` は `.ignite/.gitignore` で自動的に除外されます。

### 5. IGNITE を起動

```bash
# リポジトリルートから起動（.ignite/ を自動検出）
ignite start

# または明示的にワークスペースを指定
ignite start -w /path/to/your-product-repo
```

### 6. タスクを投入

```bash
ignite plan "認証機能のリファクタリング" -c "JWT から OAuth2 に移行"
```

## 運用のヒント

### PR 作成を効率化する

エージェントに PR を指示する際は、具体的に伝えると応答が早くなります：

```bash
ignite plan "Issue #42 の修正を実装して PR を作成する" \
  -c "修正内容: ログイン時のバリデーションエラー。修正後に main ブランチへ PR を作成"
```

### 複数プロダクトの並行運用

プロダクトごとにセッションを分けて並行運用できます：

```bash
# プロダクト A
cd /path/to/product-a
ignite start -s product-a

# プロダクト B（別ターミナル）
cd /path/to/product-b
ignite start -s product-b
```

### ワークスペースのクリーンアップ

ランタイムデータをクリアする場合（設定ファイルは保持）：

```bash
ignite clean
```

## トラブルシューティング

### `.ignite/` が既に存在する

```bash
# 設定を上書きして再初期化
ignite init --force
```

### エージェントがプロダクトのファイルを見つけられない

ワークスペースのルートが正しく設定されているか確認してください：

```bash
ignite status
```

`ignite start` をプロダクトリポジトリのルートで実行しているか確認してください。

### 既存の設定を移行したい

`~/.config/ignite/` にグローバル設定がある場合、ワークスペースに移行できます：

```bash
ignite init --migrate
```

# Contributing to IGNITE

IGNITE プロジェクトへの貢献に興味を持っていただきありがとうございます！

## 開発環境セットアップ

### 必要なツール

以下のツールがインストールされている必要があります：

- **tmux** (v3.0以上) - ターミナルマルチプレクサ
- **claude** - Claude CLI
- **gh** - GitHub CLI
- **jq** - JSONプロセッサ
- **yq** (オプション) - YAMLプロセッサ

```bash
# Ubuntu/Debian
sudo apt install tmux jq

# macOS
brew install tmux jq yq

# GitHub CLI
# https://cli.github.com/
```

### リポジトリのセットアップ

```bash
# リポジトリをクローン
git clone https://github.com/myfinder/IGNITE.git
cd IGNITE

# インストール
./install.sh

# 動作確認
ignite --version
ignite doctor  # システム診断
```

### 開発モードでの起動

```bash
# 単独モード（開発・デバッグ用）
ignite start --leader-only

# フルモード
ignite start
```

## コーディング規約

### シェルスクリプトのスタイルガイド

1. **シェバン**: `#!/usr/bin/env bash` を使用
2. **エラーハンドリング**: `set -euo pipefail` を推奨
3. **インデント**: スペース4つ
4. **変数**: ダブルクォートで囲む `"$variable"`
5. **関数**: 小文字とアンダースコア `function_name()`

```bash
#!/usr/bin/env bash
set -euo pipefail

# 良い例
function process_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        echo "Processing: $file"
    fi
}

# 悪い例
process_file() {
    file=$1
    if [ -f $file ]; then
        echo Processing: $file
    fi
}
```

### ShellCheck の使用

すべてのシェルスクリプトは [ShellCheck](https://www.shellcheck.net/) で検証してください：

```bash
# ローカルで実行
shellcheck scripts/*.sh scripts/utils/*.sh

# CIでも自動実行されます
```

### コミットメッセージの規約

[Conventional Commits](https://www.conventionalcommits.org/) に従います：

```
<type>: <description>

[optional body]

[optional footer]
```

**Types:**
- `feat`: 新機能
- `fix`: バグ修正
- `docs`: ドキュメントのみの変更
- `refactor`: リファクタリング
- `test`: テストの追加・修正
- `ci`: CI設定の変更
- `chore`: その他の変更

**例:**
```
feat: ignite logsコマンドを追加

エージェントのログをリアルタイムで確認できる機能を追加。
-f オプションでフォロー、--tail で行数指定が可能。

Closes #46
```

## テスト

### テストの実行方法

```bash
# batsテストを実行（実装予定）
bats tests/

# 手動テスト
ignite start --leader-only
# ワークスペースでタスクを実行して動作確認
```

### 新機能追加時のテスト要件

1. 既存の機能が壊れていないことを確認
2. 可能であればbatsテストを追加
3. 手動での動作確認を実施

## PR プロセス

### ブランチ命名規則

```
<type>/<short-description>
```

**例:**
- `feat/add-logs-command`
- `fix/bot-token-retry`
- `docs/update-architecture`

### PRの作成

1. フォークからブランチを作成
2. 変更を実装
3. テストを実行
4. PRを作成

```bash
# ブランチ作成
git checkout -b feat/my-feature

# 変更をコミット
git add .
git commit -m "feat: add my feature"

# プッシュ
git push origin feat/my-feature

# PRを作成
gh pr create --title "feat: add my feature" --body "Description..."
```

### レビュープロセス

1. CIチェックが通過していることを確認
2. レビュアーからのフィードバックに対応
3. 必要に応じて追加のコミットを作成
4. 承認後にマージ

### CI要件

PRは以下のチェックを通過する必要があります：

- [ ] ShellCheck による静的解析
- [ ] 基本的なスクリプト構文チェック

## Issue 報告

### バグ報告

バグを報告する際は、以下の情報を含めてください：

1. **環境情報**
   - OS とバージョン
   - tmux バージョン
   - claude CLI バージョン

2. **再現手順**
   - 問題を再現するための具体的な手順

3. **期待される動作**
   - 本来どう動作すべきか

4. **実際の動作**
   - 実際に起きた問題

5. **ログ・スクリーンショット**
   - 関連するログやエラーメッセージ

### 機能リクエスト

新機能をリクエストする際は、以下を含めてください：

1. **概要**
   - 何を実現したいか

2. **モチベーション**
   - なぜその機能が必要か

3. **提案する解決策**
   - どのように実装するか（案があれば）

4. **代替案**
   - 他に検討した方法があれば

## 質問・サポート

- **Issue**: 質問やサポートが必要な場合は Issue を作成してください
- **Discussions**: 一般的な議論は GitHub Discussions で行います

## ライセンス

貢献したコードは、プロジェクトのライセンスに従って公開されます。

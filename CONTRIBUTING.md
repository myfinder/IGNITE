# Contributing to IGNITE

IGNITE プロジェクトへの貢献に興味を持っていただきありがとうございます！

## 開発環境セットアップ

### 必要なツール

以下のツールがインストールされている必要があります：

#### AI CLI（いずれか1つ必須）

IGNITE は複数の AI CLI プロバイダーに対応しています：

- **opencode** - OpenCode CLI (推奨)
- **claude** - Claude Code CLI (Anthropic 純正)
- **codex** - Codex CLI (代替実装)

```bash
# OpenCode CLI のインストール例
npm install -g opencode-cli

# Claude Code CLI のインストール例
# https://claude.ai/code からダウンロード

# Codex CLI のインストール例
pip install codex-cli
```

#### その他必須ツール

- **gh** - GitHub CLI
- **jq** - JSONプロセッサ
- **yq** (オプション) - YAMLプロセッサ

#### CLI プロバイダーの設定

使用する AI CLI を設定するには：

```bash
# system.yaml で CLI プロバイダーを指定
vi config/system.yaml

# 設定例：
cli:
  provider: "opencode"  # opencode | claude | codex
  timeout: 300
  retries: 3

# 設定の確認
ignite doctor  # CLI プロバイダー情報を表示
```

```bash
# Ubuntu/Debian
sudo apt install jq

# macOS
brew install jq yq

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

## マルチエージェントシステム開発ガイド

IGNITE は Leader、Sub-Leaders、IGNITIANs の階層型マルチエージェントシステムです。エージェント開発時の特有手順を理解することが重要です。

### エージェント階層構造

```
Leader (1)
├── Sub-Leaders (5)
│   ├── Strategist    - 戦略立案・タスク分解
│   ├── Coordinator   - タスク調整・品質管理
│   ├── Architect     - システム設計・技術判断
│   ├── Evaluator     - 品質評価・承認判定
│   └── Innovator     - 改善提案・最適化
└── IGNITIANs (N)     - 実働エージェント
    ├── IGNITIAN-1
    ├── IGNITIAN-2
    └── ...
```

### エージェント別開発・テスト手順

#### 1. instructions/ ディレクトリでの作業

エージェントの動作を変更する場合：

```bash
# エージェント向けプロンプトの編集
vi instructions/leader.md          # Leader 用
vi instructions/strategist.md      # Strategist 用
vi instructions/coordinator.md     # Coordinator 用
vi instructions/architect.md       # Architect 用
vi instructions/evaluator.md       # Evaluator 用
vi instructions/innovator.md       # Innovator 用
vi instructions/ignitian.md        # IGNITIAN 用

# 変更の反映（ワークスペースに再デプロイ）
ignite init -w /path/to/workspace  # instructions をコピー
```

#### 2. エージェント設定の変更

```bash
# エージェント設定の編集
vi config/agents.yaml

# システム設定の変更
vi config/system.yaml               # CLI プロバイダー等
vi config/system.yaml               # キュー設定（queue:セクション）

# characters/ でパーソナリティ調整
vi characters/leader.yaml
vi characters/strategist.yaml
vi characters/coordinator.yaml
vi characters/architect.yaml
vi characters/evaluator.yaml
vi characters/innovator.yaml
vi characters/ignitian.yaml
```

#### .claude/ 設定ディレクトリ管理

IGNITE は Claude Code CLI との統合で .claude/ ディレクトリを使用します：

```bash
# .claude/ 設定構造
.claude/
├── keybindings.json             # キーボードショートカット設定
├── settings.json                # Claude Code 設定
└── project_settings.json        # プロジェクト固有設定

# 設定例の確認
ls -la ~/.claude/                # ユーザー設定
ls -la ./.claude/               # プロジェクト設定（存在する場合）

# プロジェクト固有設定の例
cat > .claude/project_settings.json << 'EOF'
{
  "ignite": {
    "workspace_dir": ".ignite",
    "agent_count": 5,
    "default_cli": "opencode"
  }
}
EOF
```

#### config/ ディレクトリの役割

各設定ファイルの役割：

| ファイル | 目的 | 影響範囲 |
|----------|------|----------|
| `agents.yaml` | エージェント定義・能力設定 | 全エージェント |
| `system.yaml` | システム設定・CLI設定・キュー設定 | システム全体 |

```bash
# 設定変更の反映
ignite init -w /path/to/workspace  # 設定をワークスペースにコピー
ignite restart                      # サービス再起動（必要に応じて）
```

#### 3. マルチエージェント環境でのテスト

```bash
# 単独モードでの基本テスト
ignite start --leader-only

# フルモードでの統合テスト
ignite start

# 特定エージェントの動作確認
ignite logs --follow ignitian-1    # IGNITIAN-1 のログ確認
ignite logs --follow coordinator   # Coordinator のログ確認

# システム全体の状態確認
ignite status                      # 全エージェント状態
ignite doctor                      # システム診断
```

#### 4. キューシステムとメッセージフォーマット

エージェント間通信は MIME 形式のメッセージファイルで行われます：

```bash
# キューファイルの確認（実行中のワークスペース）
ls .ignite/queue/coordinator/      # Coordinator 宛てメッセージ
ls .ignite/queue/ignitian_1/       # IGNITIAN-1 宛てメッセージ

# MIME メッセージの構造例
cat .ignite/queue/coordinator/task_completed_*.mime
```

#### 5. エージェント特有のデバッグ

```bash
# SQLite メモリDB の確認
sqlite3 .ignite/state/memory.db ".schema"
sqlite3 .ignite/state/memory.db "SELECT * FROM agent_states;"

# ランタイムディレクトリの確認
ls -la .ignite/                    # 全体構造
ls -la .ignite/queue/              # キュー状況
ls -la .ignite/logs/               # ログファイル
ls -la .ignite/state/              # 状態管理
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

## systemd サービス管理

IGNITE は systemd サービスとして本番環境で動作します。サービス管理の基本的な手順を理解しておくことが重要です。

### サービスの基本操作

```bash
# サービスの起動
sudo systemctl start ignite

# サービスの停止
sudo systemctl stop ignite

# サービスの再起動
sudo systemctl restart ignite

# サービスの状態確認
sudo systemctl status ignite

# サービスの自動起動設定
sudo systemctl enable ignite

# ログの確認
sudo journalctl -u ignite -f          # リアルタイム
sudo journalctl -u ignite --since today  # 今日分のログ
```

### サービス設定の変更

```bash
# システムワイドインストール
sudo ./install.sh --system

# サービスファイルの編集（必要に応じて）
sudo systemctl edit ignite
# または直接編集
sudo vi /etc/systemd/system/ignite.service

# 設定変更後の反映
sudo systemctl daemon-reload
sudo systemctl restart ignite
```

### templates/systemd/ の活用

```bash
# テンプレートファイルの確認
ls templates/systemd/

# カスタムサービス設定の作成
cp templates/systemd/ignite.service.template /tmp/ignite.service
vi /tmp/ignite.service  # 環境に合わせて編集

# テスト環境での動作確認
sudo cp /tmp/ignite.service /etc/systemd/system/ignite-test.service
sudo systemctl start ignite-test
sudo systemctl status ignite-test
```

### トラブルシューティング

```bash
# サービスの詳細状態確認
systemctl show ignite

# 最近のエラーログ確認
sudo journalctl -u ignite -p err --since "1 hour ago"

# プロセス状況の確認
ps aux | grep ignite
pgrep -fl ignite

# ポート使用状況の確認（該当する場合）
sudo ss -tlnp | grep ignite
```

## queue_monitor システム

IGNITE のエージェント間通信は queue_monitor によって管理されるファイルベースキューシステムで実現されています。開発・デバッグ時の理解が重要です。

### キューシステムの仕組み

```bash
# キューディレクトリ構造（実行中のワークスペース）
.ignite/queue/
├── coordinator/          # Coordinator 宛てメッセージ
├── strategist/           # Strategist 宛てメッセージ
├── architect/            # Architect 宛てメッセージ
├── evaluator/            # Evaluator 宛てメッセージ
├── innovator/            # Innovator 宛てメッセージ
├── ignitian_1/           # IGNITIAN-1 宛てメッセージ
├── ignitian_2/           # IGNITIAN-2 宛てメッセージ
└── ...

# アーカイブディレクトリ（処理済み）
.ignite/archive/
├── coordinator/
├── strategist/
└── ...
```

### MIME メッセージフォーマット

エージェント間通信は標準的な MIME 形式で行われます：

```bash
# メッセージファイル例の確認
cat .ignite/queue/coordinator/task_completed_1234567890.mime

# 出力例：
# MIME-Version: 1.0
# Message-ID: <1234567890.example@ignite.local>
# From: ignitian_1
# To: coordinator
# Date: Sat, 21 Feb 2026 10:00:00 +0900
# X-IGNITE-Type: task_completed
# X-IGNITE-Priority: normal
# Content-Type: text/x-yaml; charset=utf-8
#
# type: task_completed
# from: ignitian_1
# to: coordinator
# payload:
#   task_id: "example_001"
#   status: success
```

### メッセージタイプ

| タイプ | 送信者 | 受信者 | 目的 |
|--------|--------|--------|------|
| `task_assignment` | Coordinator | IGNITIANs | タスク割り当て |
| `task_completed` | IGNITIANs | Coordinator | タスク完了報告 |
| `help_request` | IGNITIANs | Coordinator | 支援要求 |
| `issue_proposal` | IGNITIANs | Coordinator | 問題提案 |
| `strategy_proposal` | Strategist | Leader | 戦略提案 |
| `evaluation_result` | Evaluator | Coordinator | 評価結果 |

### デバッグ時のログ確認

```bash
# queue_monitor のログ確認
tail -f .ignite/logs/queue_monitor.log

# エージェント別ログの確認
tail -f .ignite/logs/coordinator.log
tail -f .ignite/logs/ignitian_1.log

# メッセージキューの状況確認
find .ignite/queue -name "*.mime" | wc -l    # 未処理メッセージ数
find .ignite/archive -name "*.mime" | wc -l  # 処理済みメッセージ数

# 特定エージェントのキューサイズ確認
ls .ignite/queue/coordinator/ | wc -l
ls .ignite/queue/ignitian_1/ | wc -l
```

### キューシステムのトラブルシューティング

```bash
# メッセージが処理されない場合
ps aux | grep queue_monitor                   # プロセス確認
sudo systemctl status ignite-queue-monitor   # サービス状態

# キューファイルの権限確認
ls -la .ignite/queue/*/

# 古いメッセージファイルの確認（タイムアウト検出）
find .ignite/queue -name "*.mime" -mmin +60  # 60分以上古いファイル

# メッセージフォーマット検証
./scripts/utils/validate_mime.sh .ignite/queue/coordinator/task_*.mime
```

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
   - opencode / claude CLI バージョン

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

## コミュニティガイドライン

### Code of Conduct (行動規範)

IGNITE プロジェクトでは、すべての参加者に対して敬意を持った交流を期待しています。

詳細な行動規範は [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) を参照してください。

**主な原則:**
- 建設的で敬意ある議論
- 多様性と包含性の尊重
- ハラスメントの禁止
- プロフェッショナルな態度の維持

### セキュリティポリシー

セキュリティに関する問題を発見した場合は、責任ある開示プロセスに従ってください。

詳細は [SECURITY.md](SECURITY.md) を参照してください。

**セキュリティ脆弱性の報告:**
1. **公開 Issue での報告は避ける**
2. セキュリティ専用連絡先への報告を推奨
3. 詳細な再現手順と影響範囲を記載
4. 開示スケジュールの調整に協力

## GitHub Discussions の活用

以下の用途で GitHub Discussions を積極的に活用してください：

- **アイデア**: 新機能・改善のブレインストーミング
- **質問**: 技術的な質問・使用方法の確認
- **ショーケース**: 作成したプロジェクトやカスタマイゼーションの共有
- **一般**: プロジェクトに関する一般的な議論

## ライセンス

貢献したコードは、プロジェクトのライセンスに従って公開されます。

# IGNITE 基本使用例

このドキュメントでは、IGNITEシステムの基本的な使用方法を実例とともに説明します。

## 例1: READMEファイルの作成

### シナリオ

新しいプロジェクトのREADME.mdを作成したい。

### 手順

**1. システム起動**

```bash
cd /path/to/ignite
ignite start
```

出力例:
```
=== IGNITE システム起動 ===

workspaceを初期化中...
✓ workspace初期化完了

tmuxセッションを作成中...
Leader (伊羽ユイ) を起動中...
Leaderの起動を待機中... (3秒)
Leaderシステムプロンプトをロード中...
Leaderに初期化メッセージを送信中...

✓ IGNITE Leader が起動しました

=== 起動完了 ===

次のステップ:
  1. tmuxセッションに接続: tmux attach -t ignite-session
  2. ダッシュボード確認: cat workspace/.ignite/dashboard.md
  3. タスク投入: ignite plan "目標"

tmuxセッションにアタッチしますか? (Y/n):
```

**2. タスク投入**

別のターミナルで:

```bash
ignite plan "READMEファイルを作成する"
```

出力例:
```
=== IGNITE タスク投入 ===

目標: READMEファイルを作成する

✓ メッセージを作成しました: workspace/.ignite/queue/leader/user_goal_1738315200123456.mime

✓ タスク 'READMEファイルを作成する' を投入しました

次のステップ:
  1. ダッシュボード確認: cat workspace/.ignite/dashboard.md
  2. ステータス確認: ignite status
  3. tmuxセッション表示: tmux attach -t ignite-session
```

**3. 進捗監視**

ダッシュボードをリアルタイム監視:

```bash
watch -n 5 cat workspace/.ignite/dashboard.md
```

表示例:
```markdown
# IGNITE Dashboard

更新日時: 2026-01-31 17:10:00

## プロジェクト概要
目標: READMEファイルを作成する

## Sub-Leaders状態
- ✓ Strategist (義賀リオ): タスク分解完了 (3タスク生成)
- ✓ Architect (祢音ナナ): 設計方針承認完了
- ⏳ Coordinator (通瀬アイナ): タスク配分中
- ⏸ Evaluator (衣結ノア): 待機中
- ⏸ Innovator (恵那ツムギ): 待機中

## IGNITIANS状態
- ✓ IGNITIAN-1: タスク完了 (README骨組み作成)
- ⏳ IGNITIAN-2: 実行中 (インストール手順作成)
- ⏳ IGNITIAN-3: 実行中 (使用例作成)
- ⏸ IGNITIAN-4~8: 待機中

## タスク進捗
- 完了: 1 / 3
- 進行中: 2
- 待機中: 0

## 最新ログ
[17:05:23] [義賀リオ] タスク分解を完了しました。論理的に3つのフェーズに分割しました。
[17:06:00] [通瀬アイナ] IGNITIAN-1, 2, 3にタスクを割り当てました。順調に進んでいます。
[17:08:12] [IGNITIAN-1] README骨組みの作成が完了しました。
[17:09:30] [通瀬アイナ] 進捗: 1/3完了。このペースで続けましょう。
```

**4. tmuxセッションで詳細確認**

```bash
tmux attach -t ignite-session
```

各ペインで各エージェントの動作を確認できます:
- Pane 0: Leader の判断プロセス
- Pane 1: Strategist のタスク分解
- Pane 4: Coordinator のタスク配分
- Pane 6-8: IGNITIANs の実行状況

**5. ステータス確認**

```bash
ignite status
```

出力例:
```
=== IGNITE システム状態 ===

✓ tmuxセッション: 実行中
  ペイン数: 9

=== ダッシュボード ===

# IGNITE Dashboard
...（ダッシュボード内容）...

=== キュー状態 ===

  leader: 0 メッセージ
  strategist: 0 メッセージ
  architect: 0 メッセージ
  evaluator: 1 メッセージ
  coordinator: 0 メッセージ
  innovator: 0 メッセージ
  ignitian_1: 0 メッセージ
  ignitian_2: 0 メッセージ
  ignitian_3: 0 メッセージ

=== レポート ===
  完了レポート: 3 件
```

**6. 完了確認**

README.mdが作成されたことを確認:

```bash
cat README.md
```

**7. システム停止**

```bash
ignite stop
```

---

## 例2: コードベースの分析と改善提案

### シナリオ

既存のプロジェクトを分析して、改善点を提案してもらいたい。

### 手順

**1. システム起動**

```bash
ignite start
```

**2. 分析タスク投入**

```bash
ignite plan \
  "プロジェクト全体を分析して改善提案を作成する" \
  -c "パフォーマンス、コード品質、保守性の観点から"
```

**3. プロセス**

このタスクの場合:

1. **Leader** がタスクを受け取り、Strategist と Architect に相談
2. **Strategist** が分析戦略を立案（どの領域を重点的に分析するか）
3. **Architect** が現在の設計を評価
4. **Coordinator** が分析タスクを IGNITIANS に配分:
   - IGNITIAN-1: コードベースの構造分析
   - IGNITIAN-2: パフォーマンスボトルネック検出
   - IGNITIAN-3: コード品質チェック
   - IGNITIAN-4: 依存関係分析
5. **Evaluator** が分析結果を評価
6. **Innovator** が改善提案を作成
7. **Leader** が提案をまとめてユーザーに報告

**4. 結果確認**

分析結果は以下で確認できます:
- `workspace/.ignite/dashboard.md` - 進捗と概要
- `workspace/.ignite/logs/` - 各エージェントのログ
- Innovatorからの改善提案メッセージ

---

## 例3: 機能実装プロジェクト

### シナリオ

新しいCLIツールを実装したい。

### 手順

**1. システム起動**

```bash
ignite start
```

**2. 実装タスク投入**

```bash
ignite plan \
  "タスク管理CLIツールを実装する" \
  -c "コマンド: add, list, complete, delete。YAMLファイルでデータ保存"
```

**3. IGNITIANs数の調整（オプション）**

通常の実装タスクはデフォルト（3並列）で十分ですが、必要に応じて調整できます:

`config/system.yaml` の `defaults.worker_count` を編集:
```yaml
defaults:
  worker_count: 4  # より複雑なタスクのため並列数を減らす
```

再起動:
```bash
ignite stop
ignite start
```

**4. プロセス**

1. **Strategist** が実装をフェーズに分解:
   - Phase 1: プロジェクト構造作成
   - Phase 2: コアロジック実装
   - Phase 3: CLIインターフェース実装
   - Phase 4: テスト作成

2. **Architect** が設計を提案:
   - ディレクトリ構造
   - モジュール分割
   - データモデル

3. **Coordinator** がタスクを配分:
   - IGNITIAN-1: プロジェクト構造作成
   - IGNITIAN-2: データモデル実装
   - IGNITIAN-3: CLI引数パーサー実装
   - IGNITIAN-4: タスク追加機能実装
   - etc.

4. **Evaluator** が各実装を検証

5. **Innovator** がコードを改善

**5. 実装確認**

作成されたファイルを確認:

```bash
# プロジェクト構造
tree task-cli/

# 実装されたコード
cat task-cli/src/main.py

# テスト
cat task-cli/tests/test_cli.py
```

**6. 動作確認**

```bash
cd task-cli
python src/main.py add "テストタスク"
python src/main.py list
```

---

## 例4: 並列データ処理

### シナリオ

100個のデータファイルを並列処理したい。

### 手順

**1. IGNITIANS数を最大化**

`config/system.yaml` の `defaults.worker_count`:
```yaml
defaults:
  worker_count: 16  # 軽量タスクのため並列数を増やす
```

**2. システム起動**

```bash
ignite start
```

**3. データ処理タスク投入**

```bash
ignite plan \
  "data/ディレクトリ内の全JSONファイルを処理して集計する" \
  -c "各ファイルのidフィールドをカウント、結果をsummary.jsonに出力"
```

**4. プロセス**

1. **Strategist** がファイルリストを取得してタスク分解
2. **Coordinator** が100個のタスクを16のIGNITIANSに均等配分
3. **IGNITIANS** が並列でファイルを処理
4. **Evaluator** が処理結果を検証
5. **Innovator** が集計スクリプトを作成して最終結果をまとめる

**5. 結果確認**

```bash
cat summary.json
```

---

## ベストプラクティス

### 1. 明確な目標設定

**良い例:**
```bash
ignite plan \
  "READMEファイルを作成する" \
  -c "プロジェクト概要、インストール手順、使用例を含める"
```

**悪い例:**
```bash
ignite plan "ドキュメント作成"
# → 曖昧すぎて、何を作成すべきか不明
```

### 2. 適切なIGNITIANS数

- **軽量タスク（ファイル操作など）**: 16並列
- **通常タスク（実装など）**: 8並列
- **重量タスク（分析など）**: 4並列

### 3. ダッシュボード監視

常にダッシュボードで全体進捗を確認:

```bash
watch -n 5 cat workspace/.ignite/dashboard.md
```

### 4. ログの活用

問題が発生した場合はログを確認:

```bash
tail -f workspace/.ignite/logs/*.log
```

### 5. tmuxセッションの活用

各エージェントの動作を確認:

```bash
tmux attach -t ignite-session
```

ペイン移動:
- `Ctrl+b o` - 次のペインへ
- `Ctrl+b ;` - 前のペインへ
- `Ctrl+b q` - ペイン番号表示

---

## トラブルシューティング

### タスクが進まない

**原因1: 依存関係のブロック**

ダッシュボードで依存関係を確認:
```bash
cat workspace/.ignite/dashboard.md
```

**原因2: IGNITIANが応答しない**

tmuxセッションで該当ペインを確認:
```bash
tmux attach -t ignite-session
# Ctrl+b q でペイン番号確認
```

**原因3: メッセージが溜まっている**

キューをクリア:
```bash
rm workspace/.ignite/queue/*/*.mime
```

### エラーメッセージが出る

ログを確認:
```bash
grep -i error workspace/.ignite/logs/*.log
```

### システムが起動しない

既存セッションを削除:
```bash
tmux kill-session -t ignite-session
ignite start
```

---

## さらなる情報

- [アーキテクチャドキュメント](../architecture.md)
- [通信プロトコル仕様](../protocol.md)
- [README](../../README.md)

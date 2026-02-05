# IGNITE 通信プロトコル仕様

## 概要

IGNITEシステムでは、すべてのエージェント間通信をYAML形式のファイルベースメッセージで行います。各エージェントは自身のキューディレクトリを監視し、新しいメッセージを処理します。

## メッセージ構造

### 基本フォーマット

```yaml
type: {message_type}          # メッセージタイプ（必須）
from: {sender}                # 送信元エージェント（必須）
to: {receiver}                # 送信先エージェント（必須）
timestamp: {ISO8601}          # タイムスタンプ（必須）
priority: {priority_level}    # 優先度（必須）
payload:                      # ペイロード（必須）
  {key}: {value}
```

### フィールド仕様

#### type
メッセージタイプを示す文字列。

**標準タイプ:**
- `user_goal` - ユーザー目標
- `strategy_request` - 戦略立案依頼
- `strategy_response` - 戦略提案
- `task_list` - タスクリスト
- `architecture_request` - 設計判断依頼
- `architecture_response` - 設計提案
- `task_assignment` - タスク割り当て
- `task_completed` - タスク完了
- `evaluation_request` - 評価依頼
- `evaluation_result` - 評価結果
- `improvement_request` - 改善依頼
- `improvement_suggestion` - 改善提案
- `improvement_completed` - 改善完了
- `progress_update` - 進捗報告
- `system_init` - システム初期化

#### from
送信元エージェントの識別子。

**有効な値:**
- `user` - ユーザー
- `leader` - Leader
- `strategist` - Strategist
- `architect` - Architect
- `evaluator` - Evaluator
- `coordinator` - Coordinator
- `innovator` - Innovator
- `ignitian_{n}` - IGNITIAN（nは番号）
- `system` - システム

#### to
送信先エージェントの識別子。fromと同じ値が有効。

#### timestamp
ISO8601形式のタイムスタンプ。

**形式:** `YYYY-MM-DDTHH:MM:SS±HH:MM`
**例:** `2026-01-31T17:00:00+09:00`

Bashでの生成:
```bash
date -Iseconds
```

#### priority
メッセージの優先度。

**有効な値:**
- `high` - 高優先度、即座に処理
- `normal` - 通常優先度
- `low` - 低優先度、時間があれば処理

#### payload
メッセージの本体。メッセージタイプによって構造が異なる。

#### メッセージライフサイクル

メッセージの処理状態は、ファイルの存在と位置で管理されます。
**statusフィールドは使用しません。**

| 状態 | 表現 |
|------|------|
| 未処理 | `queue/<agent>/` にファイルが存在 |
| 配信済み | queue_monitorが `processed/` に移動後、エージェントに通知 |
| 処理完了 | エージェントがファイルを削除 |

> **後方互換性:** statusフィールドが存在しても無視されます。

## メッセージタイプ別仕様

### user_goal

ユーザーからLeaderへの目標設定。

```yaml
type: user_goal
from: user
to: leader
timestamp: "2026-01-31T17:00:00+09:00"
priority: high
payload:
  goal: "目標の説明"
  context: "追加のコンテキスト（オプション）"
```

### strategy_request

LeaderからStrategistへの戦略立案依頼。

```yaml
type: strategy_request
from: leader
to: strategist
timestamp: "2026-01-31T17:01:00+09:00"
priority: high
payload:
  goal: "目標の説明"
  requirements:
    - "要件1"
    - "要件2"
  context: "背景情報"
```

### strategy_response

StrategistからLeaderへの戦略提案。

```yaml
type: strategy_response
from: strategist
to: leader
timestamp: "2026-01-31T17:03:00+09:00"
priority: high
payload:
  goal: "目標の説明"
  strategy:
    approach: "アプローチ名"
    phases:
      - phase: 1
        name: "フェーズ名"
        description: "説明"
  task_count: 3
  estimated_duration: 300
  risks:
    - "リスク1"
  recommendations:
    - "推奨事項1"
```

### task_list

StrategistからCoordinatorへのタスクリスト。

```yaml
type: task_list
from: strategist
to: coordinator
timestamp: "2026-01-31T17:04:00+09:00"
priority: high
payload:
  goal: "目標の説明"
  strategy_summary: "戦略の要約"
  tasks:
    - task_id: "task_001"
      title: "タスク名"
      description: "タスクの説明"
      phase: 1
      priority: high
      estimated_time: 60
      dependencies: []
      skills_required:
        - "skill1"
        - "skill2"
      deliverables:
        - "成果物1"
```

### task_assignment

CoordinatorからIGNITIANへのタスク割り当て。

```yaml
type: task_assignment
from: coordinator
to: ignitian_1
timestamp: "2026-01-31T17:06:00+09:00"
priority: high
payload:
  task_id: "task_001"
  title: "タスク名"
  description: "タスクの説明"
  instructions: |
    詳細な実行手順
  deliverables:
    - "成果物1"
  skills_required:
    - "skill1"
  estimated_time: 60
```

### task_completed

IGNITIANからCoordinatorへの完了報告。

**成功時:**
```yaml
type: task_completed
from: ignitian_1
to: coordinator
timestamp: "2026-01-31T17:07:30+09:00"
priority: normal
payload:
  task_id: "task_001"
  title: "タスク名"
  status: success
  deliverables:
    - file: "ファイル名"
      description: "説明"
      location: "パス"
  execution_time: 90
  notes: "追加情報"
```

**エラー時:**
```yaml
type: task_completed
from: ignitian_1
to: coordinator
timestamp: "2026-01-31T17:07:30+09:00"
priority: high
payload:
  task_id: "task_001"
  title: "タスク名"
  status: error
  error:
    type: "エラータイプ"
    message: "エラーメッセージ"
    details: "詳細"
  execution_time: 30
  notes: "追加情報"
```

### evaluation_request

CoordinatorからEvaluatorへの評価依頼。

```yaml
type: evaluation_request
from: coordinator
to: evaluator
timestamp: "2026-01-31T17:15:00+09:00"
priority: high
payload:
  task_id: "task_001"
  title: "タスク名"
  deliverables:
    - file: "ファイル名"
      location: "パス"
  requirements:
    - "要件1"
    - "要件2"
  criteria:
    - "基準1"
    - "基準2"
```

### evaluation_result

EvaluatorからLeaderへの評価結果。

```yaml
type: evaluation_result
from: evaluator
to: leader
timestamp: "2026-01-31T17:18:00+09:00"
priority: high
payload:
  task_id: "task_001"
  title: "タスク名"
  overall_status: "pass"  # pass, pass_with_notes, fail
  score: 95

  checks_performed:
    - check: "チェック名"
      status: "pass"  # pass, pass_with_notes, fail
      details: "詳細"

  issues_found:
    - severity: "minor"  # critical, major, minor, trivial
      description: "問題の説明"
      location: "場所"
      recommendation: "推奨対応"

  recommendations:
    - "推奨事項1"

  next_action: "approve"  # approve, request_revision, reject

```

### improvement_request

EvaluatorからInnovatorへの改善依頼。

```yaml
type: improvement_request
from: evaluator
to: innovator
timestamp: "2026-01-31T17:18:30+09:00"
priority: normal
payload:
  task_id: "task_001"
  target: "対象ファイル"
  issues:
    - issue: "問題"
      severity: "minor"
      location: "場所"
      suggested_fix: "修正案"
```

### improvement_suggestion

InnovatorからLeaderへの改善提案。

```yaml
type: improvement_suggestion
from: innovator
to: leader
timestamp: "2026-01-31T17:35:00+09:00"
priority: normal
payload:
  title: "改善提案のタイトル"
  category: "performance"  # performance, quality, process, architecture

  current_situation:
    description: "現状の説明"
    issues:
      - "問題1"

  proposed_improvement:
    description: "改善案の説明"
    approach: |
      詳細なアプローチ
    benefits:
      - "メリット1"

  implementation_plan:
    - step: 1
      action: "アクション"
      effort: "medium"  # low, medium, high

  priority: "medium"  # low, medium, high
  estimated_effort: "工数見積もり"

```

### progress_update

CoordinatorからLeaderへの進捗報告。

```yaml
type: progress_update
from: coordinator
to: leader
timestamp: "2026-01-31T17:10:00+09:00"
priority: normal
payload:
  total_tasks: 3
  completed: 1
  in_progress: 2
  pending: 0
  summary: |
    進捗の要約
```

## ファイル命名規則

メッセージファイルは以下の命名規則に従います:

```
{message_type}_{message_id}.yaml
```

`message_id` はマイクロ秒精度のUnixタイムスタンプ（`date +%s%6N`、16桁）です。

**例:**
- `user_goal_1738315200123456.yaml`
- `task_assignment_1738315260234567.yaml`
- `task_completed_1738315350345678.yaml`

Bashでの生成:
```bash
MESSAGE_FILE="workspace/queue/${TO}/${TYPE}_$(date +%s%6N).yaml"
```

## キューディレクトリ

各エージェントのキューディレクトリ:

```
workspace/queue/
├── leader/           # Leader宛て
│   └── processed/    # 配信済みメッセージ
├── strategist/       # Strategist宛て
│   └── processed/
├── architect/        # Architect宛て
│   └── processed/
├── evaluator/        # Evaluator宛て
│   └── processed/
├── coordinator/      # Coordinator宛て
│   └── processed/
├── innovator/        # Innovator宛て
│   └── processed/
├── ignitian_1/       # IGNITIAN-1宛て
│   ├── processed/
│   └── task_assignment_1770263544123456.yaml
├── ignitian_2/       # IGNITIAN-2宛て
│   └── processed/
└── ignitian_3/       # IGNITIAN-3宛て
    └── processed/
```

## メッセージ処理フロー

### 送信側

1. **メッセージ作成**
   ```bash
   cat > workspace/queue/${TO}/${TYPE}_$(date +%s%6N).yaml <<EOF
   type: ${TYPE}
   from: ${FROM}
   to: ${TO}
   timestamp: "$(date -Iseconds)"
   priority: ${PRIORITY}
   payload:
     ${PAYLOAD}
   EOF
   ```

2. **ファイル書き込み**

### 受信側

1. **キューの監視**
   ```bash
   find workspace/queue/${ROLE} -name "*.yaml" -type f -mmin -1
   ```

2. **メッセージ読み込み**
   - Readツールでファイルを読み込む

3. **メッセージ処理**
   - typeに応じて適切に処理

4. **ファイル削除**
   - 処理済みメッセージを削除または移動

## エラーハンドリング

### 不正なメッセージ

- YAMLパースエラー: ログに記録、スキップ
- 必須フィールド欠如: ログに記録、スキップ
- 不明なtype: ログに記録、スキップ

### タイムアウト

- メッセージが一定時間処理されない場合:
  - ログに警告
  - 優先度を上げて再送
  - または手動介入

### 重複メッセージ

- 同じtask_idのメッセージ:
  - timestampで最新のものを優先
  - 古いものは削除

## ベストプラクティス

### メッセージ設計

1. **明確な目的**: 各メッセージは単一の目的
2. **必要十分な情報**: 不足も過剰もない
3. **構造化**: payloadは論理的に構造化
4. **検証可能**: 必要なフィールドは必須

### パフォーマンス

1. **ポーリング間隔**: 10秒がデフォルト
2. **バッチ処理**: 複数メッセージをまとめて処理
3. **非同期**: ブロッキングを避ける

### セキュリティ

1. **入力検証**: payloadの値を検証
2. **パス検証**: ファイルパスの安全性チェック
3. **権限確認**: 操作権限の確認

## 拡張性

### 新しいメッセージタイプの追加

1. **typeを定義**: 命名規則に従う
2. **payloadスキーマを設計**: 必要なフィールドを定義
3. **送信・受信処理を実装**: 各エージェントに実装
4. **ドキュメント更新**: このファイルに追加

### カスタムフィールド

標準フィールド以外にカスタムフィールドを追加可能:

```yaml
type: task_assignment
from: coordinator
to: ignitian_1
# ... 標準フィールド ...
custom_field: "カスタム値"
metadata:
  key1: value1
  key2: value2
```

## デバッグ

### メッセージのトレース

```bash
# 最近のメッセージを確認
find workspace/queue -name "*.yaml" -mmin -5 -exec cat {} \;

# 特定タイプのメッセージを検索
find workspace/queue -name "task_assignment_*.yaml"

# メッセージ数をカウント
find workspace/queue -name "*.yaml" | wc -l
```

### ログ出力

各エージェントは処理したメッセージをログに記録:

```
[{timestamp}] [{agent}] メッセージ受信: {type} from {from}
[{timestamp}] [{agent}] メッセージ処理中: {task_id}
[{timestamp}] [{agent}] メッセージ処理完了: {task_id}
```

## まとめ

IGNITEの通信プロトコルは、シンプルで拡張性の高いファイルベースメッセージングシステムです。YAML形式により可読性が高く、デバッグが容易です。各エージェントは独立して動作し、メッセージキューを通じて協調します。

## 変更履歴

| バージョン | 変更内容 |
|------------|----------|
| v2 | statusフィールド廃止、ファイル存在モデルへ移行（Issue #116） |
| v1 | 初版 |

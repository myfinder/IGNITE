# IGNITE 通信プロトコル仕様

## 概要

IGNITEシステムでは、すべてのエージェント間通信をMIME形式（RFC 2045準拠）のファイルベースメッセージで行います。メッセージのメタデータ（送信元、送信先、タイプ、優先度等）はMIMEヘッダーに、ペイロードはYAML形式のボディに格納されます。各エージェントは自身のキューディレクトリを監視し、新しいメッセージを処理します。

## メッセージ構造

### 基本フォーマット

```
MIME-Version: 1.0
Message-ID: <{epoch}.{pid}.{hash}@ignite.local>
From: {sender}
To: {receiver}
Date: {RFC 2822 date}
X-IGNITE-Type: {message_type}
X-IGNITE-Priority: {priority_level}
Content-Type: text/x-yaml; charset=utf-8
Content-Transfer-Encoding: 8bit

{YAML body}
```

**ヘッダー部** と **ボディ部** は空行で区切られます。ボディはYAML形式で、従来の `payload:` セクションの内容がそのまま入ります。

### ヘッダーフィールド

#### 標準MIMEヘッダー

| ヘッダー | 必須 | 説明 |
|----------|------|------|
| `MIME-Version` | ○ | 常に `1.0` |
| `Message-ID` | ○ | 一意のメッセージID |
| `From` | ○ | 送信元エージェント |
| `To` | ○ | 送信先エージェント（複数はカンマ区切り） |
| `Cc` | × | CC先エージェント |
| `Date` | ○ | RFC 2822形式の日時 |
| `Content-Type` | ○ | 常に `text/x-yaml; charset=utf-8` |
| `Content-Transfer-Encoding` | ○ | 常に `8bit` |

#### X-IGNITE-* カスタムヘッダー

| ヘッダー | 必須 | 説明 |
|----------|------|------|
| `X-IGNITE-Type` | ○ | メッセージタイプ |
| `X-IGNITE-Priority` | ○ | 優先度（`high` / `normal` / `low`） |
| `X-IGNITE-Status` | × | 配信状態（queue_monitorが管理） |
| `X-IGNITE-Thread-ID` | × | スレッドID |
| `X-IGNITE-Repository` | × | 関連リポジトリ |
| `X-IGNITE-Issue` | × | 関連Issue番号 |
| `X-IGNITE-Processed-At` | × | 配信処理日時 |
| `X-IGNITE-Retry-Count` | × | リトライ回数 |

### メッセージタイプ（X-IGNITE-Type）

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
- `github_event` - GitHubイベント通知
- `github_task` - GitHubタスク（トリガー検出）
- `escalation` - エスカレーション通知
- `dead_letter` - DLQ（配信不能メッセージ）

### エージェント識別子（From / To）

- `user` - ユーザー
- `leader` - Leader
- `strategist` - Strategist
- `architect` - Architect
- `evaluator` - Evaluator
- `coordinator` - Coordinator
- `innovator` - Innovator
- `ignitian_{n}` - IGNITIAN（nは番号）
- `system` - システム
- `github_watcher` - GitHub Watcher
- `queue_monitor` - キューモニター

### 優先度（X-IGNITE-Priority）

- `critical` - 緊急（エスカレーション等）
- `high` - 高優先度、即座に処理
- `normal` - 通常優先度
- `low` - 低優先度

### メッセージライフサイクル

メッセージの処理状態は、ファイルの位置と `X-IGNITE-Status` ヘッダーで管理されます。

| 状態 | 表現 |
|------|------|
| 未処理 | `queue/<agent>/` にファイルが存在 |
| 処理中 | queue_monitorが `processed/` に移動、`X-IGNITE-Status: processing` |
| 配信済み | エージェントに通知完了、`X-IGNITE-Status: delivered` |
| 処理完了 | エージェントがファイルを削除 |

## メッセージの作成・パース

### CLIツール: ignite_mime.py

メッセージの作成・パース・更新には `scripts/lib/ignite_mime.py` を使用します。

#### メッセージ作成

```bash
python3 scripts/lib/ignite_mime.py build \
    --from coordinator --to ignitian_1 \
    --type task_assignment --priority high \
    --repo owner/repo --issue 42 \
    --body "$body_yaml" \
    -o "$message_file"
```

#### メッセージパース

```bash
python3 scripts/lib/ignite_mime.py parse message.mime
# → JSON出力（ヘッダー + ボディ）
```

#### ボディ抽出

```bash
python3 scripts/lib/ignite_mime.py extract-body message.mime
# → YAML形式のボディのみ出力
```

#### ステータス更新

```bash
python3 scripts/lib/ignite_mime.py update-status message.mime delivered \
    --processed-at "$(date -Iseconds)"
```

#### ヘッダー更新・削除

```bash
python3 scripts/lib/ignite_mime.py update-header message.mime X-IGNITE-Retry-Count 3
python3 scripts/lib/ignite_mime.py remove-header message.mime X-IGNITE-Error-Reason
```

## メッセージタイプ別仕様

以下の例はボディ（YAML）部分のみを示します。実際のメッセージにはMIMEヘッダーが付与されます。

### user_goal

ユーザーからLeaderへの目標設定。

**ボディ:**
```yaml
goal: "目標の説明"
context: "追加のコンテキスト（オプション）"
```

**作成例:**
```bash
python3 scripts/lib/ignite_mime.py build \
    --from user --to leader --type user_goal --priority high \
    --body 'goal: "READMEファイルを作成する"' \
    -o "workspace/queue/leader/processed/user_goal_$(date +%s%6N).mime"
```

### strategy_request

LeaderからStrategistへの戦略立案依頼。

**ボディ:**
```yaml
goal: "目標の説明"
requirements:
  - "要件1"
  - "要件2"
context: "背景情報"
```

### strategy_response

StrategistからLeaderへの戦略提案。

**ボディ:**
```yaml
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

**ボディ:**
```yaml
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
    deliverables:
      - "成果物1"
```

### task_assignment

CoordinatorからIGNITIANへのタスク割り当て。

**完全なMIMEメッセージ例:**
```
MIME-Version: 1.0
Message-ID: <1770263544.12345.abcdef@ignite.local>
From: coordinator
To: ignitian_1
Date: Mon, 10 Feb 2026 12:00:00 +0900
X-IGNITE-Type: task_assignment
X-IGNITE-Priority: high
X-IGNITE-Repository: owner/repo
X-IGNITE-Issue: 42
Content-Type: text/x-yaml; charset=utf-8
Content-Transfer-Encoding: 8bit

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

**ボディ（成功時）:**
```yaml
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

**ボディ（エラー時）:**
```yaml
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

**ボディ:**
```yaml
task_id: "task_001"
title: "タスク名"
deliverables:
  - file: "ファイル名"
    location: "パス"
requirements:
  - "要件1"
criteria:
  - "基準1"
```

### evaluation_result

EvaluatorからLeaderへの評価結果。

**ボディ:**
```yaml
repository: "owner/repo"
task_id: "task_001"
title: "タスク名"
overall_status: "pass"
score: 95
checks_performed:
  - check: "チェック名"
    status: "pass"
    details: "詳細"
issues_found:
  - severity: "minor"
    description: "問題の説明"
    location: "場所"
    recommendation: "推奨対応"
recommendations:
  - "推奨事項1"
next_action: "approve"
```

### improvement_request

EvaluatorからInnovatorへの改善依頼。

**ボディ:**
```yaml
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

**ボディ:**
```yaml
title: "改善提案のタイトル"
category: "performance"
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
    effort: "medium"
priority: "medium"
estimated_effort: "工数見積もり"
```

### progress_update

CoordinatorからLeaderへの進捗報告。

**ボディ:**
```yaml
repository: "owner/repo"
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
{message_type}_{message_id}.mime
```

`message_id` はマイクロ秒精度のUnixタイムスタンプ（`date +%s%6N`、16桁）です。

**例:**
- `user_goal_1738315200123456.mime`
- `task_assignment_1738315260234567.mime`
- `task_completed_1738315350345678.mime`

Bashでの生成:
```bash
MESSAGE_FILE="workspace/queue/${TO}/${TYPE}_$(date +%s%6N).mime"
python3 scripts/lib/ignite_mime.py build \
    --from "$FROM" --to "$TO" --type "$TYPE" --priority "$PRIORITY" \
    --body "$BODY_YAML" -o "$MESSAGE_FILE"
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
│   └── task_assignment_1770263544123456.mime
├── ignitian_2/       # IGNITIAN-2宛て
│   └── processed/
└── ignitian_3/       # IGNITIAN-3宛て
    └── processed/
```

## メッセージ処理フロー

### 送信側

```bash
# ignite_mime.py でMIMEメッセージを作成
python3 scripts/lib/ignite_mime.py build \
    --from "$FROM" --to "$TO" --type "$TYPE" --priority "$PRIORITY" \
    --body "$BODY_YAML" \
    -o "workspace/queue/${TO}/${TYPE}_$(date +%s%6N).mime"
```

### 受信側

1. **キューの監視**（queue_monitor.shが自動実行）
2. **メッセージ読み込み** - Readツールでファイルを読み込む
3. **メッセージ処理** - X-IGNITE-Typeに応じて適切に処理
4. **ファイル削除** - 処理済みメッセージを削除

## エラーハンドリング

### 不正なメッセージ

- MIMEパースエラー: ログに記録、スキップ
- 必須ヘッダー欠如: ログに記録、スキップ
- 不明なtype: ログに記録、スキップ

### タイムアウト・リトライ

- `X-IGNITE-Status: processing` のまま一定時間経過した場合:
  - retry_handler.shがタイムアウトを検知
  - `X-IGNITE-Retry-Count` をインクリメントし `X-IGNITE-Status: retrying` に設定
  - Exponential Backoff with Full Jitter でリトライ間隔を計算
  - リトライ上限到達時は Dead Letter Queue に移動、Leaderにエスカレーション

### Dead Letter Queue

リトライ上限（デフォルト3回）に到達したメッセージは `workspace/queue/dead_letter/` に移動されます。

## ベストプラクティス

### メッセージ設計

1. **明確な目的**: 各メッセージは単一の目的
2. **必要十分な情報**: 不足も過剰もない
3. **構造化**: ボディのYAMLは論理的に構造化
4. **cat可読性**: CTE=8bitにより、catでそのまま読める

### デバッグ

```bash
# 最近のメッセージを確認
find workspace/queue -name "*.mime" -mmin -5 -exec cat {} \;

# 特定タイプのメッセージを検索
find workspace/queue -name "task_assignment_*.mime"

# メッセージ数をカウント
find workspace/queue -name "*.mime" | wc -l

# メッセージをJSONでパース
python3 scripts/lib/ignite_mime.py parse workspace/queue/ignitian_1/processed/task.mime
```

## まとめ

IGNITEの通信プロトコルは、RFC 2045準拠のMIME形式によるファイルベースメッセージングシステムです。MIMEヘッダーによりメタデータが構造化され、YAML形式のボディにより可読性が高く、`cat` でそのまま内容を確認できます（CTE=8bit）。各エージェントは独立して動作し、メッセージキューを通じて協調します。

## 変更履歴

| バージョン | 変更内容 |
|------------|----------|
| v3 | YAML形式からMIME形式へ全面移行（Issue #223） |
| v2 | statusフィールド廃止、ファイル存在モデルへ移行（Issue #116） |
| v1 | 初版 |

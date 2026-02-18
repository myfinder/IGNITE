# エージェント間コミュニケーションフロー

IGNITE システムにおけるエージェント間のメッセージフローを図示します。

## implement フロー全体図

```mermaid
sequenceDiagram
    participant GW as GitHub Watcher
    participant L as Leader (伊羽ユイ)
    participant S as Strategist (義賀リオ)
    participant A as Architect (祢音ナナ)
    participant Ev as Evaluator (衣結ノア)
    participant In as Innovator (恵那ツムギ)
    participant C as Coordinator (通瀬アイナ)
    participant I as IGNITIAN

    GW->>L: github_task (implement)
    Note over L: action_type 判定
    L->>L: setup_repo.sh clone → ブランチ作成
    L->>L: comment_on_issue.sh (受付応答)
    L->>S: strategy_request (repository, issue_number, action_type)

    Note over S: Sub-Leaders レビュー
    S->>A: design_review_request
    S->>Ev: quality_plan_request
    S->>In: insight_request
    A->>S: design_review_response
    Ev->>S: quality_plan_response
    In->>S: insight_response

    S->>L: strategy_response (strategy + tasks[])
    Note over L: 承認判断

    L->>C: task_list (承認済み tasks, repository, issue_number)
    Note over C: action_type を記録

    C->>I: task_assignment (repository, issue_number)
    Note over I: setup_repo.sh clone → per-IGNITIAN clone
    Note over I: 実装 + commit + push
    I->>C: task_completed

    Note over C: 全 implement 完了 → create_pr 配分
    C->>I: task_assignment (create_pr)
    Note over I: create_pr.sh → PR 作成
    I->>C: task_completed (pr_url)

    C->>L: progress_update (pr_url)
    L->>L: comment_on_issue.sh (完了コメント)
```

## review フロー

```mermaid
sequenceDiagram
    participant L as Leader
    participant S as Strategist
    participant C as Coordinator
    participant I as IGNITIAN

    Note over L: github_task (review) 受信
    L->>S: strategy_request (action_type: review)
    S->>L: strategy_response (review タスク群)
    L->>C: task_list (review タスク)
    C->>I: task_assignment (review)
    Note over I: レビュー実施
    Note over I: comment_on_issue.sh で結果を GitHub に投稿
    I->>C: task_completed
    C->>L: progress_update (全タスク完了)
    Note over L: サマリーコメントを GitHub に投稿
```

## help_request / help_ack リレー

```mermaid
sequenceDiagram
    participant I as IGNITIAN
    participant C as Coordinator
    participant L as Leader

    I->>C: help_request (task_id, help_type)
    C->>I: help_ack (action: investigating)
    Note over C: severity 判定
    C->>L: help_request_forwarded (severity: high)
    Note over L: 対処方針を決定
    L->>C: help_ack (relay_to: ignitian_{n}, action: resolved)
    C->>I: help_ack (guidance: 対処方針)
    Note over I: 作業再開
```

## issue_proposal リレー

```mermaid
sequenceDiagram
    participant I as IGNITIAN
    participant C as Coordinator
    participant L as Leader

    I->>C: issue_proposal (severity, evidence)
    Note over C: severity フィルタリング
    C->>I: issue_proposal_ack (decision: received)
    alt severity: critical / major
        C->>L: issue_proposal_forwarded
        Note over L: 判断 (起票/追記/却下)
        L->>C: issue_proposal_ack (decision: created, issue_url)
        C->>I: issue_proposal_ack (decision: created, issue_url)
    else severity: minor / suggestion
        Note over C: ログ記録のみ
    end
```

## メッセージタイプ一覧

### Leader 発信

| メッセージタイプ | 送信先 | 用途 |
|---|---|---|
| `strategy_request` | Strategist | 戦略立案依頼 |
| `task_list` | Coordinator | タスク配分指示（Strategist 承認後） |
| `revision_request` | Strategist | 戦略の差し戻し |
| `help_ack` | Coordinator / Sub-Leader | ヘルプ要求への応答 |
| `issue_proposal_ack` | Coordinator / Sub-Leader | Issue提案への応答 |
| `improvement_request` | Innovator | 改善実行の指示 |
| `improvement_suggestion_ack` | Innovator | 改善提案への応答 |

### Strategist 発信

| メッセージタイプ | 送信先 | 用途 |
|---|---|---|
| `strategy_response` | Leader | 戦略提案（tasks 配列含む） |
| `design_review_request` | Architect | 設計レビュー依頼 |
| `quality_plan_request` | Evaluator | 品質プラン依頼 |
| `insight_request` | Innovator | インサイト依頼 |

### Coordinator 発信

| メッセージタイプ | 送信先 | 用途 |
|---|---|---|
| `task_assignment` | IGNITIAN | タスク割り当て |
| `revision_request` | IGNITIAN | 成果物の差し戻し |
| `progress_update` | Leader | 進捗報告（PR URL 含む場合あり） |
| `help_ack` | IGNITIAN | ヘルプ要求への応答（Leader からのリレー含む） |
| `help_request_forwarded` | Leader | IGNITIAN のヘルプ要求を転送 |
| `issue_proposal_ack` | IGNITIAN | Issue提案への応答（Leader からのリレー含む） |
| `issue_proposal_forwarded` | Leader | IGNITIAN の Issue 提案を転送 |
| `evaluation_request` | Evaluator | 判断困難ケースの相談 |

### IGNITIAN 発信

| メッセージタイプ | 送信先 | 用途 |
|---|---|---|
| `task_completed` | Coordinator | タスク完了報告 |
| `help_request` | Coordinator | ヘルプ要求 |
| `issue_proposal` | Coordinator | Issue 提案 |

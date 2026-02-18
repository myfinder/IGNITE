# Agent Communication Flow

This document illustrates the message flow between agents in the IGNITE system.

## Implement Flow (Full)

```mermaid
sequenceDiagram
    participant GW as GitHub Watcher
    participant L as Leader (Yui Iha)
    participant S as Strategist (Rio Giga)
    participant A as Architect (Nana Neon)
    participant Ev as Evaluator (Noah Iyui)
    participant In as Innovator (Tsumugi Ena)
    participant C as Coordinator (Aina Tsuse)
    participant I as IGNITIAN

    GW->>L: github_task (implement)
    Note over L: Determine action_type
    L->>L: setup_repo.sh clone → create branch
    L->>L: comment_on_issue.sh (acknowledge)
    L->>S: strategy_request (repository, issue_number, action_type)

    Note over S: Sub-Leaders review
    S->>A: design_review_request
    S->>Ev: quality_plan_request
    S->>In: insight_request
    A->>S: design_review_response
    Ev->>S: quality_plan_response
    In->>S: insight_response

    S->>L: strategy_response (strategy + tasks[])
    Note over L: Approval decision

    L->>C: task_list (approved tasks, repository, issue_number)
    Note over C: Record action_type

    C->>I: task_assignment (repository, issue_number)
    Note over I: setup_repo.sh clone → per-IGNITIAN clone
    Note over I: Implement + commit + push
    I->>C: task_completed

    Note over C: All implement tasks done → assign create_pr
    C->>I: task_assignment (create_pr)
    Note over I: create_pr.sh → Create PR
    I->>C: task_completed (pr_url)

    C->>L: progress_update (pr_url)
    L->>L: comment_on_issue.sh (completion comment)
```

## Review Flow

```mermaid
sequenceDiagram
    participant L as Leader
    participant S as Strategist
    participant C as Coordinator
    participant I as IGNITIAN

    Note over L: github_task (review) received
    L->>S: strategy_request (action_type: review)
    S->>L: strategy_response (review tasks)
    L->>C: task_list (review tasks)
    C->>I: task_assignment (review)
    Note over I: Conduct review
    Note over I: Post results to GitHub via comment_on_issue.sh
    I->>C: task_completed
    C->>L: progress_update (all tasks completed)
    Note over L: Post summary comment to GitHub
```

## help_request / help_ack Relay

```mermaid
sequenceDiagram
    participant I as IGNITIAN
    participant C as Coordinator
    participant L as Leader

    I->>C: help_request (task_id, help_type)
    C->>I: help_ack (action: investigating)
    Note over C: Severity assessment
    C->>L: help_request_forwarded (severity: high)
    Note over L: Determine resolution
    L->>C: help_ack (relay_to: ignitian_{n}, action: resolved)
    C->>I: help_ack (guidance: resolution)
    Note over I: Resume work
```

## issue_proposal Relay

```mermaid
sequenceDiagram
    participant I as IGNITIAN
    participant C as Coordinator
    participant L as Leader

    I->>C: issue_proposal (severity, evidence)
    Note over C: Severity filtering
    C->>I: issue_proposal_ack (decision: received)
    alt severity: critical / major
        C->>L: issue_proposal_forwarded
        Note over L: Decision (create/append/reject)
        L->>C: issue_proposal_ack (decision: created, issue_url)
        C->>I: issue_proposal_ack (decision: created, issue_url)
    else severity: minor / suggestion
        Note over C: Log only
    end
```

## Message Type Reference

### Leader Outbound

| Message Type | Destination | Purpose |
|---|---|---|
| `strategy_request` | Strategist | Request strategy planning |
| `task_list` | Coordinator | Task distribution (after Strategist approval) |
| `revision_request` | Strategist | Strategy revision request |
| `help_ack` | Coordinator / Sub-Leader | Response to help request |
| `issue_proposal_ack` | Coordinator / Sub-Leader | Response to issue proposal |
| `improvement_request` | Innovator | Request improvement execution |
| `improvement_suggestion_ack` | Innovator | Response to improvement suggestion |

### Strategist Outbound

| Message Type | Destination | Purpose |
|---|---|---|
| `strategy_response` | Leader | Strategy proposal (includes tasks array) |
| `design_review_request` | Architect | Design review request |
| `quality_plan_request` | Evaluator | Quality plan request |
| `insight_request` | Innovator | Insight request |

### Coordinator Outbound

| Message Type | Destination | Purpose |
|---|---|---|
| `task_assignment` | IGNITIAN | Task assignment |
| `revision_request` | IGNITIAN | Deliverable revision request |
| `progress_update` | Leader | Progress report (may include PR URL) |
| `help_ack` | IGNITIAN | Help request response (including relay from Leader) |
| `help_request_forwarded` | Leader | Forward IGNITIAN help request |
| `issue_proposal_ack` | IGNITIAN | Issue proposal response (including relay from Leader) |
| `issue_proposal_forwarded` | Leader | Forward IGNITIAN issue proposal |
| `evaluation_request` | Evaluator | Consultation for ambiguous cases |

### IGNITIAN Outbound

| Message Type | Destination | Purpose |
|---|---|---|
| `task_completed` | Coordinator | Task completion report |
| `help_request` | Coordinator | Help request |
| `issue_proposal` | Coordinator | Issue proposal |

# IGNITE Communication Protocol Specification

## Overview

In the IGNITE system, all inter-agent communication is performed via file-based messages in MIME format (RFC 2045 compliant). Message metadata (sender, receiver, type, priority, etc.) is stored in MIME headers, and the payload is stored in the body in YAML format. Each agent monitors its own queue directory and processes new messages.

## Message Structure

### Basic Format

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

The **header section** and **body section** are separated by a blank line. The body is in YAML format and contains the same content as the traditional `payload:` section.

### Header Fields

#### Standard MIME Headers

| Header | Required | Description |
|--------|----------|-------------|
| `MIME-Version` | Yes | Always `1.0` |
| `Message-ID` | Yes | Unique message ID |
| `From` | Yes | Sender agent |
| `To` | Yes | Recipient agent (comma-separated for multiple) |
| `Cc` | No | CC recipient agents |
| `Date` | Yes | Date/time in RFC 2822 format |
| `Content-Type` | Yes | Always `text/x-yaml; charset=utf-8` |
| `Content-Transfer-Encoding` | Yes | Always `8bit` |

#### X-IGNITE-* Custom Headers

| Header | Required | Description |
|--------|----------|-------------|
| `X-IGNITE-Type` | Yes | Message type |
| `X-IGNITE-Priority` | Yes | Priority (`high` / `normal` / `low`) |
| `X-IGNITE-Status` | No | Delivery status (managed by queue_monitor) |
| `X-IGNITE-Thread-ID` | No | Thread ID |
| `X-IGNITE-Repository` | No | Related repository |
| `X-IGNITE-Issue` | No | Related issue number |
| `X-IGNITE-Processed-At` | No | Delivery processing date/time |
| `X-IGNITE-Retry-Count` | No | Retry count |

### Message Types (X-IGNITE-Type)

**Standard Types:**
- `user_goal` - User goal
- `strategy_request` - Strategy planning request
- `strategy_response` - Strategy proposal
- `task_list` - Task list
- `architecture_request` - Architecture decision request
- `architecture_response` - Architecture proposal
- `task_assignment` - Task assignment
- `task_completed` - Task completion
- `evaluation_request` - Evaluation request
- `evaluation_result` - Evaluation result
- `improvement_request` - Improvement request
- `improvement_suggestion` - Improvement suggestion
- `improvement_completed` - Improvement completed
- `progress_update` - Progress report
- `github_event` - GitHub event notification
- `github_task` - GitHub task (trigger detection)
- `escalation` - Escalation notification
- `dead_letter` - DLQ (dead letter queue message)

### Agent Identifiers (From / To)

- `user` - User
- `leader` - Leader
- `strategist` - Strategist
- `architect` - Architect
- `evaluator` - Evaluator
- `coordinator` - Coordinator
- `innovator` - Innovator
- `ignitian_{n}` - IGNITIAN (n is a number)
- `system` - System
- `github_watcher` - GitHub Watcher
- `queue_monitor` - Queue Monitor

### Priority (X-IGNITE-Priority)

- `critical` - Urgent (escalations, etc.)
- `high` - High priority, process immediately
- `normal` - Normal priority
- `low` - Low priority

### Message Lifecycle

The processing state of a message is managed by the file's location and the `X-IGNITE-Status` header.

| State | Representation |
|-------|----------------|
| Unprocessed | File exists in `queue/<agent>/` |
| Processing | queue_monitor moves to `processed/`, `X-IGNITE-Status: processing` |
| Delivered | Notification to agent completed, `X-IGNITE-Status: delivered` |
| Completed | Agent deletes the file |

## Creating and Parsing Messages

### CLI Tool: ignite_mime.py

Use `scripts/lib/ignite_mime.py` for creating, parsing, and updating messages.

#### Creating Messages

```bash
python3 scripts/lib/ignite_mime.py build \
    --from coordinator --to ignitian_1 \
    --type task_assignment --priority high \
    --repo owner/repo --issue 42 \
    --body "$body_yaml" \
    -o "$message_file"
```

#### Parsing Messages

```bash
python3 scripts/lib/ignite_mime.py parse message.mime
# -> JSON output (headers + body)
```

#### Extracting Body

```bash
python3 scripts/lib/ignite_mime.py extract-body message.mime
# -> Outputs only the body in YAML format
```

#### Updating Status

```bash
python3 scripts/lib/ignite_mime.py update-status message.mime delivered \
    --processed-at "$(date -Iseconds)"
```

#### Updating/Removing Headers

```bash
python3 scripts/lib/ignite_mime.py update-header message.mime X-IGNITE-Retry-Count 3
python3 scripts/lib/ignite_mime.py remove-header message.mime X-IGNITE-Error-Reason
```

## Message Type Specifications

The following examples show only the body (YAML) portion. Actual messages include MIME headers.

### user_goal

Goal setting from User to Leader.

**Body:**
```yaml
goal: "Goal description"
context: "Additional context (optional)"
```

**Creation example:**
```bash
python3 scripts/lib/ignite_mime.py build \
    --from user --to leader --type user_goal --priority high \
    --body 'goal: "READMEファイルを作成する"' \
    -o "workspace/.ignite/queue/leader/processed/user_goal_$(date +%s%6N).mime"
```

### strategy_request

Strategy planning request from Leader to Strategist.

**Body:**
```yaml
goal: "Goal description"
requirements:
  - "Requirement 1"
  - "Requirement 2"
context: "Background information"
```

### strategy_response

Strategy proposal from Strategist to Leader.

**Body:**
```yaml
goal: "Goal description"
strategy:
  approach: "Approach name"
  phases:
    - phase: 1
      name: "Phase name"
      description: "Description"
task_count: 3
estimated_duration: 300
risks:
  - "Risk 1"
recommendations:
  - "Recommendation 1"
```

### task_list

Task list from Strategist to Coordinator.

**Body:**
```yaml
goal: "Goal description"
strategy_summary: "Strategy summary"
tasks:
  - task_id: "task_001"
    title: "Task name"
    description: "Task description"
    phase: 1
    priority: high
    estimated_time: 60
    dependencies: []
    skills_required:
      - "skill1"
    deliverables:
      - "Deliverable 1"
```

### task_assignment

Task assignment from Coordinator to IGNITIAN.

**Full MIME message example:**
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
title: "Task name"
description: "Task description"
instructions: |
  Detailed execution instructions
deliverables:
  - "Deliverable 1"
skills_required:
  - "skill1"
estimated_time: 60
```

### task_completed

Completion report from IGNITIAN to Coordinator.

**Body (on success):**
```yaml
task_id: "task_001"
title: "Task name"
status: success
deliverables:
  - file: "Filename"
    description: "Description"
    location: "Path"
execution_time: 90
notes: "Additional information"
```

**Body (on error):**
```yaml
task_id: "task_001"
title: "Task name"
status: error
error:
  type: "Error type"
  message: "Error message"
  details: "Details"
execution_time: 30
notes: "Additional information"
```

### evaluation_request

Evaluation request from Coordinator to Evaluator.

**Body:**
```yaml
task_id: "task_001"
title: "Task name"
deliverables:
  - file: "Filename"
    location: "Path"
requirements:
  - "Requirement 1"
criteria:
  - "Criterion 1"
```

### evaluation_result

Evaluation result from Evaluator to Leader.

**Body:**
```yaml
repository: "owner/repo"
task_id: "task_001"
title: "Task name"
overall_status: "pass"
score: 95
checks_performed:
  - check: "Check name"
    status: "pass"
    details: "Details"
issues_found:
  - severity: "minor"
    description: "Issue description"
    location: "Location"
    recommendation: "Recommended action"
recommendations:
  - "Recommendation 1"
next_action: "approve"
```

### improvement_request

Improvement request from Evaluator to Innovator.

**Body:**
```yaml
task_id: "task_001"
target: "Target file"
issues:
  - issue: "Issue"
    severity: "minor"
    location: "Location"
    suggested_fix: "Suggested fix"
```

### improvement_suggestion

Improvement proposal from Innovator to Leader.

**Body:**
```yaml
title: "Improvement proposal title"
category: "performance"
current_situation:
  description: "Description of current situation"
  issues:
    - "Issue 1"
proposed_improvement:
  description: "Description of proposed improvement"
  approach: |
    Detailed approach
  benefits:
    - "Benefit 1"
implementation_plan:
  - step: 1
    action: "Action"
    effort: "medium"
priority: "medium"
estimated_effort: "Effort estimate"
```

### progress_update

Progress report from Coordinator to Leader.

**Body:**
```yaml
repository: "owner/repo"
issue: 123
total_tasks: 3
completed: 1
in_progress: 2
pending: 0
summary: |
  Progress summary
```

**Required fields:**
- `repository`
- `summary`

**Optional fields:**
- `issue` - Target issue number
- `stage` - Progress stage name (e.g., `planning` / `implementation` / `review`)
- `percent` - Integer progress percentage from 0-100
- `message` - Short one-line progress message
- `total_tasks` / `completed` / `in_progress` / `pending`
- `final` - Set to `true` for final summary

**Display format (common):**
- `stage=<stage> percent=<percent> message=<message>`
- Uses `format_progress_message()` from `core.sh`

**Update frequency guidelines:**
- Minimum interval: 2 seconds
- Burst suppression: Maximum 5 times per 10 seconds
- Final summary should include `final: true` to separate it from regular updates

**Display degradation rules:**
- When `NO_COLOR` or `TERM=dumb` is set, output only the common one-line format without colors or decorations

## File Naming Convention

Message files follow this naming convention:

```
{message_type}_{message_id}.mime
```

`message_id` is a Unix timestamp with microsecond precision (`date +%s%6N`, 16 digits).

**Examples:**
- `user_goal_1738315200123456.mime`
- `task_assignment_1738315260234567.mime`
- `task_completed_1738315350345678.mime`

Generation in Bash:
```bash
MESSAGE_FILE="workspace/.ignite/queue/${TO}/${TYPE}_$(date +%s%6N).mime"
python3 scripts/lib/ignite_mime.py build \
    --from "$FROM" --to "$TO" --type "$TYPE" --priority "$PRIORITY" \
    --body "$BODY_YAML" -o "$MESSAGE_FILE"
```

## Queue Directories

Queue directory for each agent:

```
workspace/.ignite/queue/
├── leader/           # Messages for Leader
│   └── processed/    # Delivered messages
├── strategist/       # Messages for Strategist
│   └── processed/
├── architect/        # Messages for Architect
│   └── processed/
├── evaluator/        # Messages for Evaluator
│   └── processed/
├── coordinator/      # Messages for Coordinator
│   └── processed/
├── innovator/        # Messages for Innovator
│   └── processed/
├── ignitian_1/       # Messages for IGNITIAN-1
│   ├── processed/
│   └── task_assignment_1770263544123456.mime
├── ignitian_2/       # Messages for IGNITIAN-2
│   └── processed/
└── ignitian_3/       # Messages for IGNITIAN-3
    └── processed/
```

## Message Processing Flow

### Sender Side

```bash
# Create MIME message with ignite_mime.py
python3 scripts/lib/ignite_mime.py build \
    --from "$FROM" --to "$TO" --type "$TYPE" --priority "$PRIORITY" \
    --body "$BODY_YAML" \
    -o "workspace/.ignite/queue/${TO}/${TYPE}_$(date +%s%6N).mime"
```

### Receiver Side

1. **Queue monitoring** (automatically executed by queue_monitor.sh)
2. **Message reading** - Read the file using the Read tool
3. **Message processing** - Process appropriately according to X-IGNITE-Type
4. **File deletion** - Delete the processed message

## Error Handling

### Invalid Messages

- MIME parse error: Log and skip
- Missing required headers: Log and skip
- Unknown type: Log and skip

### Timeout and Retry

- When a message remains in `X-IGNITE-Status: processing` for a certain period:
  - retry_handler.sh detects the timeout
  - Increments `X-IGNITE-Retry-Count` and sets `X-IGNITE-Status: retrying`
  - Calculates retry interval using Exponential Backoff with Full Jitter
  - When retry limit is reached, moves to Dead Letter Queue and escalates to Leader

### Dead Letter Queue

Messages that reach the retry limit (default: 3 times) are moved to `workspace/.ignite/queue/dead_letter/`.

## Best Practices

### Message Design

1. **Clear purpose**: Each message serves a single purpose
2. **Sufficient information**: Neither too little nor too much
3. **Structured**: Body YAML is logically structured
4. **cat-readable**: With CTE=8bit, messages can be read directly with cat

### Debugging

```bash
# Check recent messages
find workspace/.ignite/queue -name "*.mime" -mmin -5 -exec cat {} \;

# Search for messages of a specific type
find workspace/.ignite/queue -name "task_assignment_*.mime"

# Count messages
find workspace/.ignite/queue -name "*.mime" | wc -l

# Parse a message as JSON
python3 scripts/lib/ignite_mime.py parse workspace/.ignite/queue/ignitian_1/processed/task.mime
```

## Summary

The IGNITE communication protocol is a file-based messaging system using RFC 2045 compliant MIME format. Metadata is structured through MIME headers, and the YAML-formatted body provides high readability, allowing content to be viewed directly with `cat` (CTE=8bit). Each agent operates independently and coordinates through message queues.

## Changelog

| Version | Changes |
|---------|---------|
| v3 | Full migration from YAML format to MIME format (Issue #223) |
| v2 | Deprecated status field, migrated to file existence model (Issue #116) |
| v1 | Initial version |

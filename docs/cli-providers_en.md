# CLI Providers

IGNITE supports 3 CLI providers. All providers are unified under the **per-message + session resume** pattern.

## Configuration

Switch providers in the `cli:` section of `system.yaml`:

```yaml
cli:
  provider: claude    # opencode / claude / codex
  model: claude-opus-4-6
```

### Available Providers

| Provider | Command | Operation Model |
|---|---|---|
| `opencode` | `opencode run --format json` | per-message + `--session` to resume |
| `claude` | `claude -p --output-format json` | per-message + `--resume` to resume |
| `codex` | `codex exec --json --full-auto` | per-message + `exec resume` to resume |

## Authentication

### OpenCode

Set API keys in `.ignite/.env`:

```bash
# .ignite/.env
OPENAI_API_KEY=sk-...
# or
ANTHROPIC_API_KEY=sk-ant-...
```

### Claude Code

#### Max Plan Login (Recommended)

If you are logged into `claude` without setting `ANTHROPIC_API_KEY`, it operates within your Max Plan subscription quota.

```bash
# Login (first time only)
claude login
```

#### API Key Method

Set `ANTHROPIC_API_KEY` in `.ignite/.env` for pay-per-use API access.

```bash
# .ignite/.env
ANTHROPIC_API_KEY=sk-ant-...
```

**Note**: If an API key is set, it takes priority. To use Max Plan quota, do not set an API key.

### Codex CLI

Set OpenAI API key in `.ignite/.env`:

```bash
# .ignite/.env
OPENAI_API_KEY=sk-...
```

## Rate Limits

- **Claude Code (Max Plan)**: Rate limits reset every 5 hours. When limits are reached, Claude may switch from Opus to Sonnet. For large-scale operations, consider using the API key method.
- **OpenCode / Codex**: Depends on API key rate limits.

## Attach Command

`ignite attach` executes a provider-specific interactive connection:

```bash
ignite attach
# → Select from agent list
# → Confirmation prompt (note: conflicts with queue_monitor)
```

| Provider | Connection Command |
|---|---|
| `claude` | `claude --resume <session_id>` |
| `opencode` | `opencode --session <session_id>` |
| `codex` | `codex resume <session_id>` |

**Note**: While attached, queue_monitor message sending will wait for the lock. Disconnect promptly when done.

## Provider Comparison

| Item | OpenCode | Claude Code | Codex CLI |
|---|---|---|---|
| Process Model | per-message | per-message | per-message |
| Session Management | `--session <id>` | `--resume <id>` | `exec resume <id>` |
| Message Sending | Sync | Sync | Sync |
| flock Timeout | 600 seconds | 600 seconds | 600 seconds |
| Dependencies | `opencode jq` | `claude jq` | `codex jq` |
| Instruction Injection | `opencode.json` `instructions` | `--append-system-prompt` | stdin (concatenated to initial prompt) |

## Troubleshooting

### `CLAUDECODE` Environment Variable Conflict

When launching IGNITE from within a Claude Code session, the `CLAUDECODE` environment variable may cause nested execution issues. IGNITE performs `unset CLAUDECODE` at startup, but if problems persist, manually unset the variable:

```bash
unset CLAUDECODE
ignite start
```

### Corrupted Session

If a session becomes corrupted, stop and restart:

```bash
ignite stop -y
ignite start
```

### Slow Responses

All providers spawn a process per message, so message sending may take some time. The queue_monitor flock timeout is set to 600 seconds (10 minutes).

# Slack Watcher

Provides Slack channel/mention monitoring. Receives events in real-time via Slack Socket Mode (WebSocket) and sends them as MIME messages to the Leader queue.

## Architecture

Uses a Shell wrapper + Python subprocess hybrid architecture.

```
slack_watcher.sh (shell wrapper)
  ├── Sources watcher_common.sh (PID, signals, state, MIME)
  ├── Launches slack_watcher.py in background
  ├── watcher_poll() override:
  │     1. Python process health check (restart on death)
  │     2. Read events from spool directory (.ignite/tmp/slack_events/)
  │     3. Each event: sanitize → dedup → build MIME → send to leader queue
  ├── watcher_heartbeat() override (for queue_monitor)
  └── SIGTERM → kill Python child process → clean shutdown

slack_watcher.py (Python Socket Mode receiver)
  ├── slack-bolt SocketModeHandler.start() blocking wait
  ├── app_mention event → atomic write JSON file to spool
  ├── In-memory deduplication (event_ts based)
  └── SIGTERM → handler.close() → graceful exit
```

**IPC**: File spool (JSON). Python writes, Shell polls and reads.

## Setup

### 1. Create a Slack App

1. Create a new App at [Slack API](https://api.slack.com/apps)
2. Enable **Socket Mode** and generate an App-Level Token (`xapp-...`)
3. Enable **Event Subscriptions** and add these events:
   - `app_mention` — Bot mentions
   - `message.channels` — Channel messages (optional)
4. Add scopes under **OAuth & Permissions**:
   - `app_mentions:read`
   - `channels:history` (for channel message monitoring)
   - `chat:write` (for future response features)
5. Install to workspace and obtain Bot User OAuth Token (`xoxb-...`)

### 2. Token Configuration

Add tokens to `.ignite/.env`:

```bash
SLACK_BOT_TOKEN=xoxb-your-bot-token
SLACK_APP_TOKEN=xapp-your-app-token
```

### 3. Configuration File

```bash
cp config/slack-watcher.yaml.example config/slack-watcher.yaml
```

Configuration options:

| Key | Default | Description |
|-----|---------|-------------|
| `interval` | `5` | Spool check interval (seconds) |
| `events.app_mention` | `true` | Monitor @mention events |
| `events.channel_message` | `false` | Monitor channel messages |
| `triggers.task_keywords` | (list) | Keywords that trigger `slack_task` |
| `access_control.enabled` | `false` | Enable access control |
| `access_control.allowed_users` | `[]` | Allowed Slack user IDs |
| `access_control.allowed_channels` | `[]` | Allowed Slack channel IDs |

### 4. Register in watchers.yaml

Enable `slack_watcher` in `config/watchers.yaml`:

```yaml
watchers:
  - name: slack_watcher
    description: "Slack channel/mention monitoring"
    script_path: scripts/utils/slack_watcher.sh
    config_file: slack-watcher.yaml
    enabled: true
    auto_start: true
```

## Starting

```bash
# Auto-start via watchers.yaml
ignite start

# Standalone start
./scripts/utils/slack_watcher.sh

# Start with specific watcher
ignite start --with-watcher=slack_watcher
```

## Message Types

### slack_event

Informational notification. Mentions/messages without task keywords.

```yaml
type: slack_event
from: slack_watcher
to: leader
payload:
  event_type: "app_mention"
  channel_id: "C01ABC123"
  user_id: "U01XYZ789"
  text: "@ignite-bot hello"
  thread_ts: ""
  event_ts: "1234567890.654321"
  source: "slack_watcher"
```

### slack_task

Task request when task keywords are detected.

```yaml
type: slack_task
from: slack_watcher
to: leader
priority: high
payload:
  event_type: "app_mention"
  channel_id: "C01ABC123"
  user_id: "U01XYZ789"
  text: "@ignite-bot implement login feature"
  thread_ts: "1234567890.123456"
  event_ts: "1234567890.654321"
  source: "slack_watcher"
```

## Task Keywords

When the following keywords are found in text, the message is sent as `slack_task` to the Leader:

| Category | Keywords |
|----------|----------|
| Implementation/Fix | 実装して, 修正して, implement, fix |
| Review | レビューして, review |
| Q&A/Research | 教えて, 調べて, 説明して, どうすれば, なぜ, explain, how to, why, what is |

Customizable via `triggers.task_keywords` in `config/slack-watcher.yaml`.

## Python Dependency Management

On first startup, a Python virtual environment is automatically created in `.ignite/venv/`:

- Creates venv with `python3 -m venv`
- Installs packages with `pip install -r slack_requirements.txt`
- On subsequent runs, checks `requirements.txt` hash for cache validity; skips if unchanged
- No global pip install is performed

**Required**: Python 3 and pip must be available.

## Troubleshooting

### Python receiver won't start

```bash
# Check Python environment
python3 --version
python3 -m pip --version

# Recreate venv
rm -rf .ignite/venv/
./scripts/utils/slack_watcher.sh
```

### Token errors

```bash
# Check .env configuration
cat .ignite/.env

# Verify SLACK_APP_TOKEN starts with xapp-
# Verify SLACK_BOT_TOKEN starts with xoxb-
```

### Events not arriving

1. Check that **Event Subscriptions** is enabled in Slack App settings
2. Check that **Socket Mode** is enabled
3. Verify the bot has been added to the channel
4. Check the spool directory: `ls .ignite/tmp/slack_events/`

### Log inspection

```bash
# Watcher logs
tail -f .ignite/logs/slack_watcher.log

# Heartbeat check
cat .ignite/state/slack_watcher_heartbeat.json
```

## Related Documentation

- [Custom Watcher Creation Guide](custom-watcher_en.md)
- [Protocol Specification](protocol_en.md)

# Custom Watcher Creation Guide

This document explains how to create a custom Watcher using the IGNITE Custom Watcher Framework.

## Overview

The Custom Watcher Framework is a common foundation for monitoring external service events and integrating them into the IGNITE system. Using the common functions provided by `watcher_common.sh` (daemon management, state management, MIME construction, input sanitization, etc.), each Watcher only needs to implement its event retrieval logic (`watcher_poll()`).

### Architecture

```
┌──────────────────────────────────────────────────┐
│ Custom Watcher                                    │
│                                                   │
│  watcher_poll()          ← Implemented by each   │
│    ↓                        Watcher              │
│  watcher_send_mime()     ← Provided by           │
│    ↓                        watcher_common.sh    │
│  queue/{to}/*.mime       → Processed by Leader   │
└──────────────────────────────────────────────────┘
```

### Reference Implementation

`scripts/utils/github_watcher.sh` is the most complete reference implementation. The sample code in this guide is based on patterns from github_watcher.sh.

## API Reference — watcher_common.sh

### Initialization

#### `watcher_init <watcher_name> [config_file]`

Initializes the Watcher. Performs config loading, state management initialization, PID file creation, and signal trap registration in one call.

| Argument | Description |
|----------|-------------|
| `watcher_name` | Watcher name (e.g., `slack_watcher`). Used for state file name, PID file name, and log prefix |
| `config_file` | Config file path (optional: defaults to `$IGNITE_CONFIG_DIR/{watcher-name}.yaml`, underscores converted to hyphens) |

### Configuration

#### `watcher_load_config <config_file>`

Loads common settings from a YAML config file. Automatically re-called on SIGHUP reception.

| Setting | Variable | Default |
|---------|----------|---------|
| `interval` | `_WATCHER_POLL_INTERVAL` | `60` (seconds) |

For Watcher-specific settings, use `yaml_get` or similar functions to load them independently.

### Daemon Management

#### `watcher_run_daemon`

Starts the main polling loop. Repeatedly executes the following:

1. Leader process liveness check (when `IGNITE_SESSION` is set)
2. `watcher_poll()` invocation (overridden by each Watcher)
3. `watcher_cleanup_old_events()` — automatic deletion of events older than 24 hours
4. Config reload on SIGHUP reception
5. Wait for `_WATCHER_POLL_INTERVAL` seconds (in 1-second increments for SIGTERM responsiveness)

Shutdown is controlled by the `_WATCHER_SHUTDOWN_REQUESTED` flag, safely stopping after the current `watcher_poll()` completes.

#### `watcher_shutdown`

Deletes the PID file and performs graceful shutdown. Automatically called from the EXIT trap, so explicit calls are usually unnecessary.

### MIME Message Construction

#### `watcher_send_mime <from> <to> <type> <body_yaml> [repo] [issue]`

Constructs a MIME message and enqueues it for the specified agent.

| Argument | Description |
|----------|-------------|
| `from` | Source Watcher name |
| `to` | Destination agent name (e.g., `leader`) |
| `type` | Message type (e.g., `github_event`, `slack_event`) |
| `body_yaml` | Body YAML string (**assembly is each Watcher's responsibility**) |
| `repo` | Repository (optional, e.g., `owner/repo`) |
| `issue` | Issue number (optional) |

**Return value**: Path to the generated MIME file (stdout)

> **Important**: `watcher_send_mime()` only handles MIME construction and queue insertion. Body YAML assembly must be done by each Watcher.

### State Management

#### `watcher_init_state <watcher_name>`

Initializes the state file (`state/{watcher_name}_state.json`). Automatically called from `watcher_init()`.

#### `watcher_is_event_processed <event_type> <event_id>`

Checks if an event has been processed. Return value: `0` = processed, `1` = unprocessed.

#### `watcher_mark_event_processed <event_type> <event_id>`

Records an event as processed. Added to `processed_events` with a timestamp.

#### `watcher_update_last_check <check_key>`

Updates the last check time for the specified key.

#### `watcher_get_last_check <check_key>`

Gets the last check time for the specified key. Returns `initialized_at` if never checked.

#### `watcher_cleanup_old_events`

Automatically deletes processed events older than 24 hours. Automatically called within the `watcher_run_daemon` loop.

### Input Sanitization

#### `_watcher_sanitize_input <input> [max_length]`

Sanitizes external data. Default max length is 256 characters.

Processing:
- Removes all control characters (`\x00-\x1f`, `\x7f`)
- Converts shell metacharacters and YAML special characters (`\`, `"`, `;`, `|`, `&`, `$`, `` ` ``, `<`, `>`, `(`, `)`) to fullwidth equivalents
- Applies length limit

### Functions to Implement in Custom Watchers

#### `watcher_poll` (required)

Performs one cycle of event retrieval and processing. `watcher_common.sh` provides an empty implementation, which each Watcher overrides by redefining the function.

#### `watcher_on_event <event_type> <event_data>` (planned for Phase 3)

Event callback for push-type Watchers. Currently only a stub implementation.

## watchers.yaml Configuration

### Schema

```yaml
watchers:
  - name: watcher_name        # Required: Watcher identifier (unique)
    description: "Description" # Optional: Description text
    script_path: path/to/script.sh  # Required: Script path (relative to project root)
    config_file: config-name.yaml    # Required: Config file name (under config/)
    enabled: true              # Required: Enable/disable (bool)
    auto_start: true           # Optional: Auto-start with --with-watcher=auto (default: true)
```

### Field Description

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | Yes | Unique identifier for the Watcher. Duplicates cause a validation error |
| `description` | string | No | Description of the Watcher |
| `script_path` | string | Yes | Path to the Watcher script. Relative paths are resolved from the project root (parent of config/) |
| `config_file` | string | Yes | Config file name. Placed under the `config/` directory |
| `enabled` | bool | Yes | `true` to enable, `false` to disable |
| `auto_start` | bool | No | Whether to auto-start with `--with-watcher=auto`. Default `true` |

### Validation

`validate_watchers_yaml()` validates the following:

- The `watchers` section is an array
- Each entry has the required fields (`name`, `script_path`, `config_file`, `enabled`)
- Each field has the correct type
- `name` values are not duplicated
- `script_path` file exists (warning if not found)

### Fallback

If `watchers.yaml` does not exist but `github-watcher.yaml` does, it operates as if only `github_watcher` is registered (backward compatibility).

### Registration

```bash
# 1. Copy watchers.yaml.example
cp config/watchers.yaml.example config/watchers.yaml

# 2. Add a new watcher entry
# Edit config/watchers.yaml

# 3. Run validation
ignite validate
```

## Creating a New Watcher

### Step 1: Create the Script File

```bash
touch scripts/utils/my_watcher.sh
chmod +x scripts/utils/my_watcher.sh
```

### Step 2: Implement the Basic Structure

```bash
#!/bin/bash
# my_watcher.sh — My Custom Watcher

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load watcher_common.sh
source "${SCRIPT_DIR}/../lib/watcher_common.sh"

# ─── Watcher-specific config loading ───
MY_API_TOKEN=""
MY_TARGET=""

_load_my_config() {
    local config_file="$1"
    MY_API_TOKEN=$(yaml_get "$config_file" 'api_token')
    MY_TARGET=$(yaml_get "$config_file" 'target')
}

# ─── Override watcher_poll() ───
watcher_poll() {
    # 1. Retrieve events from external service
    local events
    events=$(curl -s -H "Authorization: Bearer $MY_API_TOKEN" \
        "https://api.example.com/events?since=$(watcher_get_last_check 'my_events')")

    # 2. Process each event
    local event_id event_title
    while IFS= read -r line; do
        event_id=$(echo "$line" | jq -r '.id')
        event_title=$(echo "$line" | jq -r '.title')

        # Deduplication check
        if watcher_is_event_processed "my_event" "$event_id"; then
            continue
        fi

        # Sanitize
        event_title=$(_watcher_sanitize_input "$event_title" 200)

        # 3. Build and send MIME message
        local body_yaml="event_type: \"new_event\"
event_id: \"${event_id}\"
title: \"${event_title}\"
source: \"my_service\""

        watcher_send_mime "$_WATCHER_NAME" "leader" "my_event" "$body_yaml"

        # Mark as processed
        watcher_mark_event_processed "my_event" "$event_id"
    done <<< "$(echo "$events" | jq -c '.[]' 2>/dev/null)"

    # Update last check time
    watcher_update_last_check "my_events"
}

# ─── Initialize, load custom config, start daemon ───
watcher_init "my_watcher" "${1:-}"
_load_my_config "$_WATCHER_CONFIG_FILE"
watcher_run_daemon
```

### Step 3: Create the Config File

`config/my-watcher.yaml`:

```yaml
# My Custom Watcher configuration
interval: 120          # Polling interval (seconds)
api_token: "your-token-here"
target: "my-target"
```

### Step 4: Register in watchers.yaml

```yaml
watchers:
  - name: github_watcher
    description: "GitHub Issue/PR event monitoring"
    script_path: scripts/utils/github_watcher.sh
    config_file: github-watcher.yaml
    enabled: true

  - name: my_watcher
    description: "My Custom Service monitoring"
    script_path: scripts/utils/my_watcher.sh
    config_file: my-watcher.yaml
    enabled: true
```

### Step 5: Validate and Test

```bash
# Validate
ignite validate

# Start IGNITE with Watchers
ignite start --with-watcher
```

## Testing

### bats Test Structure

Create `test_my_watcher.bats` in the `tests/` directory:

```bash
#!/usr/bin/env bats
load test_helper

setup() {
    setup_temp_dir
    export IGNITE_CONFIG_DIR="$TEST_TEMP_DIR/config"
    export IGNITE_RUNTIME_DIR="$TEST_TEMP_DIR/runtime"
    mkdir -p "$IGNITE_CONFIG_DIR" "$IGNITE_RUNTIME_DIR/state" "$IGNITE_RUNTIME_DIR/queue/leader"
}

teardown() {
    cleanup_temp_dir
}

@test "watcher_init creates PID file" {
    source "$SCRIPTS_DIR/lib/watcher_common.sh"
    watcher_init "test_watcher" "$IGNITE_CONFIG_DIR/test-watcher.yaml"

    [ -f "$IGNITE_RUNTIME_DIR/state/test_watcher.pid" ]
}

@test "watcher_is_event_processed returns 1 for new event" {
    source "$SCRIPTS_DIR/lib/watcher_common.sh"
    watcher_init "test_watcher" "$IGNITE_CONFIG_DIR/test-watcher.yaml"

    run watcher_is_event_processed "test" "event_001"
    [ "$status" -eq 1 ]
}

@test "watcher_mark_event_processed then is_processed returns 0" {
    source "$SCRIPTS_DIR/lib/watcher_common.sh"
    watcher_init "test_watcher" "$IGNITE_CONFIG_DIR/test-watcher.yaml"

    watcher_mark_event_processed "test" "event_001"
    run watcher_is_event_processed "test" "event_001"
    [ "$status" -eq 0 ]
}

@test "_watcher_sanitize_input removes shell metacharacters" {
    source "$SCRIPTS_DIR/lib/watcher_common.sh"

    result=$(_watcher_sanitize_input 'hello; rm -rf /' 256)
    [[ "$result" != *";"* ]]
    [[ "$result" == *"；"* ]]
}
```

### Running Tests

```bash
bats tests/test_my_watcher.bats
```

## Naming Conventions

| Type | Pattern | Example |
|------|---------|---------|
| Public functions | `watcher_*` | `watcher_init`, `watcher_poll` |
| Internal functions | `_watcher_*` | `_watcher_sanitize_input` |
| Global variables | `_WATCHER_*` | `_WATCHER_NAME`, `_WATCHER_POLL_INTERVAL` |
| State files | `state/{name}_state.json` | `state/my_watcher_state.json` |
| PID files | `state/{name}.pid` | `state/my_watcher.pid` |
| Config files | `config/{name}.yaml` | `config/my-watcher.yaml` (underscores → hyphens) |

## Signal Handling

`watcher_common.sh` automatically handles the following signals:

| Signal | Behavior |
|--------|----------|
| `SIGHUP` | Schedules config file reload. Re-executes `watcher_load_config` at the start of the next loop |
| `SIGTERM` / `SIGINT` | Graceful shutdown. Safely stops after the current `watcher_poll()` completes |
| `EXIT` | PID file deletion + exit log output |

To apply config changes:

```bash
kill -HUP $(cat .ignite/state/my_watcher.pid)
```

# Container Isolation (Podman Rootless)

## Overview

Since IGNITE v0.8.0, agents run inside Podman rootless containers.
This prevents agents from having unrestricted access to the host environment.

**Enabled by default** — set `isolation.enabled: false` to explicitly disable.

## Motivation

- Agents using host's `gh` CLI to create unauthorized PRs (PR #342)
- Agents destroying their own bash environment
- Instructions (soft measures) are ignored by AI → hard environmental measures needed

## Architecture

**1 workspace = 1 long-running container. All agents run inside the same container.**

```
ignite start
  ├─ isolation_start_container(workspace)          ← Start 1 container
  │
  ├─ cli_start_agent_server("leader", ...)
  │   └─ podman exec ignite-ws-xxxx claude -p ...  ← Initial session in container
  ├─ cli_start_agent_server("strategist", ...)
  │   └─ podman exec ignite-ws-xxxx claude -p ...
  │
  ├─ queue_monitor → cli_send_message(session_id, message)
  │   └─ podman exec ignite-ws-xxxx claude -p --resume ...
  │
  └─ ignite stop
      ├─ (agents cleanup)
      └─ isolation_stop_container()                ← Stop & remove 1 container
```

## Configuration

`config/system.yaml`:

```yaml
isolation:
  enabled: true              # Enable/disable container isolation
  runtime: podman            # Container runtime (only podman supported)
  image: ignite-agent:latest # Container image
  resource_memory: 4g        # Memory limit
  resource_cpus: 4           # CPU limit
```

## Prerequisites

- **Linux only** (macOS not supported)
- **Podman** must be installed
- **Rootless mode** recommended

### Installing Podman

```bash
# Ubuntu/Debian
sudo apt install podman

# Fedora/RHEL
sudo dnf install podman

# Arch
sudo pacman -S podman
```

## Container Image

### Automatic Build

On the first `ignite start`, if the image doesn't exist, it will be built automatically.

### Manual Build

```bash
./scripts/ignite build-image
```

### Image Contents

- Ubuntu 24.04 base
- bash, curl, jq, python3, git, sqlite3, Node.js 22
- CLI tools (claude / opencode / codex depending on cli.provider)
- **Intentionally excluded**: `gh` CLI, `ssh` client

## Mount Design

| Mount Target | Mode | Reason |
|-------------|------|--------|
| `$WORKSPACE_DIR` | rw | Workspace operations |
| `$IGNITE_RUNTIME_DIR` (.ignite/) | rw | queue/state/logs/repos/tmp |
| `$IGNITE_SCRIPTS_DIR` | ro | Auth flows (safe_git_push etc.) |
| `~/.claude/` | rw | Session state + login auth |
| `~/.anthropic/` | ro | API key cache |
| `~/.config/opencode/` | ro | OpenCode config + auth |

### Intentionally Not Mounted

- `~/.ssh/` — Physically prevents SSH-based git operations
- `~/.gitconfig` — Prevents unintended git config application in container

## Security Features

| Feature | Description |
|---------|-------------|
| `--userns=keep-id` | Maps host UID directly |
| `--security-opt no-new-privileges` | Prevents privilege escalation |
| `--network=pasta` | Fast rootless networking |
| `--memory` / `--cpus` | Resource limits |
| No gh CLI | Prevents unauthorized PR creation |
| No SSH | HTTPS + Token auth only |

## Container Recovery

queue_monitor monitors container health and automatically restarts on crash.

## Disabling

```yaml
# config/system.yaml
isolation:
  enabled: false
```

## Troubleshooting

### podman not installed

```
[ERROR] podman is not installed
```

→ Install Podman or disable with `isolation.enabled: false`.

### Image build failure

```bash
# Manual build (for debugging)
podman build -f containers/Containerfile.agent --build-arg CLI_PROVIDER=claude -t ignite-agent:latest containers/
```

### Container won't start

```bash
# Check container status
podman ps -a | grep ignite-ws

# Check logs
podman logs ignite-ws-xxxxxxxx
```

### git commit requires user.name/email

Set in `.ignite/.env`:

```
GIT_AUTHOR_NAME=ignite-bot
GIT_AUTHOR_EMAIL=ignite-bot@example.com
GIT_COMMITTER_NAME=ignite-bot
GIT_COMMITTER_EMAIL=ignite-bot@example.com
```

# Container Isolation (Podman Rootless)

## Overview

Since IGNITE v0.8.0, agents run inside Podman rootless containers.
This prevents agents from having unrestricted access to the host environment.

**Disabled by default (opt-in)** — set `isolation.enabled: true` to explicitly enable.

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
  resource_memory: 8g        # Memory limit (~500MB per CLI process × 9 agents + OS)
  resource_cpus: 4           # CPU limit
```

> **When running multiple workspaces with different CLI providers on the same host**, use different image names.
> Each image only contains the CLI specified by `cli.provider`, so reusing an image built for a different
> provider will cause agent startup failures.
>
> ```yaml
> # Workspace using Claude Code
> isolation:
>   image: ignite-agent-claude:latest
>
> # Workspace using Codex CLI
> isolation:
>   image: ignite-agent-codex:latest
> ```

## Prerequisites

- **Linux only** (macOS not supported)
- **Podman** must be installed
- **passt** must be installed (for pasta networking)
- **Rootless mode** recommended

### Installing Required Packages

```bash
# Ubuntu/Debian
sudo apt install podman passt

# Fedora/RHEL
sudo dnf install podman passt

# Arch
sudo pacman -S podman passt
```

> **Note**: `passt` is required for Podman rootless fast networking (`--network=pasta`).
> Without it, container startup will fail with `unable to find network with name or ID pasta`.

### cgroup Configuration (GCE / Cloud VMs)

On cloud VMs where systemd user sessions are not available, `podman build` may fail with:

```
sd-bus call: Interactive authentication required.: Permission denied
```

To fix this, explicitly set the cgroup manager to `cgroupfs`:

```bash
mkdir -p ~/.config/containers
cat > ~/.config/containers/containers.conf <<'EOF'
[engine]
cgroup_manager = "cgroupfs"
events_logger = "file"
EOF
```

It is also recommended to enable lingering:

```bash
sudo loginctl enable-linger $(id -u)
```

> **Reconnect SSH after changing settings.** Changes to `containers.conf` are not immediately reflected in the current shell session.

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

### Copied on Startup (Not Bind-Mounted)

The following files are copied into the container via `podman cp` at startup instead of bind-mounting.

| Source | Reason |
|--------|--------|
| `~/.claude/` | Claude Code session state + login auth |
| `~/.claude.json` | Claude Code global config |
| `~/.anthropic/` | Anthropic API key cache |
| `~/.config/opencode/` | OpenCode config + auth |
| `~/.codex/` | Codex CLI config + auth |

**Background**: CLI tools perform non-atomic reads/writes on their config files.
When multiple containers bind-mount the same files, concurrent writes cause file corruption (Issue #354).
Each container gets an independent copy, structurally eliminating write conflicts.
Changes inside the container are not written back to the host (the latest version is copied from the host on next startup).

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

## Verification Steps

After making changes to container isolation, always perform these integration tests.

### 1. Unit Tests

```bash
make test
# All tests (including isolation-related) must pass
```

### 2. Normal Mode (isolation OFF)

```bash
# Initialize workspace (apply latest config)
./scripts/ignite init --force

# Confirm isolation.enabled: false in system.yaml
grep 'enabled:' .ignite/system.yaml

# Start → all 9 agents healthy → stop
./scripts/ignite start
./scripts/ignite status          # Confirm 9/9 healthy
./scripts/ignite stop -s <session-id>

# Confirm no remaining processes
ps aux | grep -E 'claude.*session-id|queue_monitor' | grep -v grep
```

### 3. Isolation Mode (isolation ON)

```bash
# Enable isolation
# .ignite/system.yaml: isolation.enabled: true

# Check image exists (build if not)
podman images | grep ignite-agent

# Start → container up → all 9 agents healthy → stop
./scripts/ignite start
podman ps --filter name=ignite-ws   # Container should be running
./scripts/ignite status              # 9/9 healthy + container info

# Verify resource limits
podman inspect <container-name> --format '{{.HostConfig.Memory}} {{.HostConfig.NanoCpus}} {{.HostConfig.SecurityOpt}}'

# Stop → confirm container removal
./scripts/ignite stop -s <session-id>
podman ps -a --filter name=ignite-ws   # Container should be fully removed
```

### Checklist

| Item | How to Verify |
|------|---------------|
| All 9 agents started | `ignite status` shows 9/9 healthy |
| Container running | `podman ps` shows ignite-ws-* as running |
| Resource limits | `podman inspect` shows memory/cpus/security-opt |
| Clean shutdown | No containers or processes remain after `ignite stop` |
| Dashboard updated | `cat .ignite/dashboard.md` shows agent logs |
| queue_monitor | `ignite status` shows queue monitor running |

## Podman Operations

### Checking Containers

```bash
# List running containers
podman ps --filter name=ignite-ws

# List all containers (including stopped)
podman ps -a --filter name=ignite-ws
```

### Inspecting Container Contents

```bash
# Run a command inside the container
podman exec ignite-ws-xxxxxxxx <command>

# Verify CLI is installed correctly
podman exec ignite-ws-xxxxxxxx which claude
podman exec ignite-ws-xxxxxxxx claude --version

# Check authentication files
podman exec ignite-ws-xxxxxxxx ls -la ~/.claude/

# Open a shell inside the container (for debugging)
podman exec -it ignite-ws-xxxxxxxx bash
```

### Image Management

```bash
# List images
podman images | grep ignite-agent

# Delete images (to force rebuild)
podman rmi ignite-agent:latest ignite-agent:v0.8.0

# When using provider-specific image names
podman rmi ignite-agent-codex:latest ignite-agent-codex:v0.8.0
```

### Manual Container Stop/Remove

```bash
# Force remove a specific container
podman rm -f ignite-ws-xxxxxxxx

# Remove all IGNITE containers
podman rm -f $(podman ps -a --filter name=ignite-ws -q)
```

### Resource Monitoring

```bash
# Check container resource limits
podman inspect ignite-ws-xxxxxxxx --format '{{.HostConfig.Memory}} {{.HostConfig.NanoCpus}} {{.HostConfig.SecurityOpt}}'

# Real-time resource usage
podman stats --filter name=ignite-ws --no-stream
```

### Full Reset

```bash
# Reset all Podman data (deletes all images, containers, and cache)
podman system reset --force
```

> **Note**: `podman system reset` deletes all images. The next `ignite start` will automatically rebuild the image.

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

### CLI not found (all agent startups fail)

```
[ERROR] Claude Code の初期化レスポンスが取得できませんでした
```

The CLI may not be installed inside the container.
This happens when build cache causes the CLI installation step to be skipped.

```bash
# Check if CLI exists
podman exec ignite-ws-xxxxxxxx which claude   # → "not found" means not installed

# Fix: delete image and rebuild
ignite stop
podman rm -f $(podman ps -a --filter name=ignite-ws -q)
podman rmi ignite-agent:latest ignite-agent:v0.8.0
ignite start -w .   # Image will be automatically rebuilt
```

### ignite stop leaves containers running

When the session is not found (e.g., after all agent startups fail), container cleanup may be skipped (fixed in v0.8.0).

```bash
# Manually remove containers
podman rm -f $(podman ps -a --filter name=ignite-ws -q)

# Also remove state file
rm -f .ignite/state/container_name
```

### .env changes not reflected

`.ignite/.env` is read at container startup (`podman run --env-file`).
Changes to `.env` while the container is running are not reflected in `podman exec` calls.

→ After changing `.env`, restart with `ignite stop && ignite start`.

### git commit requires user.name/email

Set in `.ignite/.env`:

```
GIT_AUTHOR_NAME=ignite-bot
GIT_AUTHOR_EMAIL=ignite-bot@example.com
GIT_COMMITTER_NAME=ignite-bot
GIT_COMMITTER_EMAIL=ignite-bot@example.com
```

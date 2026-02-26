# Developer Guide

This guide explains how to set up and use the IGNITE development environment.

## Prerequisites

### Required Tools (Development & Testing)

| Tool | Purpose | Installation |
|------|---------|-------------|
| bash (4.0+) | Shell script execution | OS default |
| curl | HTTP communication | `apt install curl` |
| jq | JSON processing | `apt install jq` |
| sqlite3 | Memory DB | `apt install sqlite3` |
| bats | Test framework | `apt install bats` |
| git | Version control | `apt install git` |
| GNU parallel | Parallel test execution | `apt install parallel` |

### Optional Tools

| Tool | Purpose | Installation |
|------|---------|-------------|
| yq (v4.30+) | YAML processing | [Official site](https://github.com/mikefarah/yq) |
| python3 | Utilities | `apt install python3` |
| podman | Container isolation | `apt install podman` |
| shellcheck | Static analysis | `apt install shellcheck` |

### Runtime Tools (CLI Provider)

To actually launch agents with `ignite start`, one of the following CLI providers is required:

| Tool | Description |
|------|-------------|
| opencode | Default CLI provider |
| claude | Claude Code CLI |
| codex | Codex CLI |

Configure which provider to use via `cli.provider` in `config/system.yaml`. These are not required for running tests.

## Setup

```bash
# 1. Clone the repository
git clone <repo-url>
cd ignite

# 2. Check development environment
make dev

# 3. Verify it works
./scripts/ignite --help
```

`make dev` runs `scripts/dev-setup.sh`, which checks for required tools, detects existing installations, and verifies file permissions.

## Running from Repository

During development, `install.sh` is **not required**. You can run directly from the repository checkout:

```bash
./scripts/ignite --help
./scripts/ignite init -w /path/to/workspace
./scripts/ignite start -w /path/to/workspace
```

`scripts/lib/core.sh` automatically resolves `PROJECT_ROOT` and loads configuration files, instructions, and scripts from the repository. Editing the source takes effect immediately, eliminating the need for dual management.

## Make Targets

```bash
make help     # Show help (default)
make dev      # Development environment setup (check dependencies)
make test     # Run all tests (bats, parallel)
make lint     # Static analysis with shellcheck
make start    # Start with test workspace (/tmp/ignite-dev-ws)
make stop     # Stop test workspace
make clean    # Remove test workspace
```

## Testing

### Run All Tests

```bash
make test
# Or directly:
bats --jobs "$(($(nproc) * 8))" tests/
```

### Run Specific Tests

```bash
bats tests/test_cmd_start_init.bats
```

### Adding Tests

- Place test files in `tests/` with the naming convention `test_*.bats`
- Follow existing test patterns for `setup()` / `teardown()` definitions
- For library function tests, `source` the module and use mock functions for stubs

## Container Isolation Development

To develop the container isolation feature:

1. Install **podman** (rootless mode recommended)
2. Set `isolation.enabled: true` in `config/system.yaml`
3. Build container images: see the `containers/` directory

If podman is not available, set `isolation.enabled: false` to run without containers.

## Coding Conventions

See the "Coding Conventions" section in CLAUDE.md.

## About install.sh

`install.sh` is an **end-user** installer. It copies scripts to `~/.local/share/ignite/` and creates a symlink at `~/.local/bin/ignite`.

Developers do not need to use this installer. Development can be done by running directly from the repository.

## PATH Conflict Notes

If you have previously installed IGNITE using `install.sh`, `~/.local/bin/ignite` may be in your PATH. In this case, simply typing `ignite` will run the installed version.

During development, use one of the following approaches:
- Run with full path: `./scripts/ignite`
- Use Make targets: `make start` / `make stop`
- Temporarily rename or remove `~/.local/bin/ignite`

## Troubleshooting

### "parallel: command not found" when running `make test`

GNU parallel is not installed:
```bash
# Ubuntu/Debian
sudo apt install parallel
# macOS
brew install parallel
```

### "bats: command not found"

Install bats-core:
```bash
# Ubuntu/Debian
sudo apt install bats
# macOS
brew install bats-core
```

### Conflicts with Existing Installation

Running `make dev` will detect and warn about existing installations. Use `./scripts/ignite` directly during development.

### shellcheck Errors

Fix issues detected by `make lint`. shellcheck warnings are also checked in CI.

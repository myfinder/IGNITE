# Setting Up IGNITE in an Existing Repository

This guide explains how to integrate IGNITE into an existing product repository so that agents can directly work with your codebase.

## Overview

IGNITE creates a `.ignite/` directory at the root of your product repository and uses it as its workspace. This allows agents to directly reference your product's code, configuration, and documentation while working on tasks.

### Benefits

- Agents automatically recognize your product's CLAUDE.md and coding conventions
- Tasks are executed with full codebase search and reference capabilities
- Direct access to product diffs when creating PRs
- Runtime data inside `.ignite/` is automatically excluded via `.gitignore`

## Setup Steps

### Prerequisites

- IGNITE is installed (verify with `ignite --version`)
- Target repository is cloned locally

### 1. Run `ignite init` in Your Repository

```bash
cd /path/to/your-product-repo
ignite init
```

The following files are generated under `.ignite/`:

```
your-product-repo/
├── .ignite/
│   ├── .gitignore          # Runtime data exclusion rules
│   ├── system.yaml         # IGNITE system configuration
│   ├── characters.yaml     # Character configuration
│   ├── github-watcher.yaml.example
│   ├── github-app.yaml.example
│   ├── .env.example        # Environment variable template
│   ├── instructions/       # Agent prompts
│   └── characters/         # Character definitions
├── src/                    # Your product code
├── CLAUDE.md               # Your product conventions (if any)
└── ...
```

For a minimal setup:

```bash
ignite init --minimal    # Only system.yaml
```

### 2. Add `.ignite/` to `.gitignore`

Add it to your product repository's root `.gitignore`:

```bash
echo '.ignite/' >> .gitignore
```

> **Note**: `.ignite/.gitignore` is for excluding runtime data (`queue/`, `logs/`, `state/`, etc.) within the `.ignite/` directory itself. If you want to commit `.ignite/` (for team sharing), skip this step.

### 3. Customize Configuration

```bash
# Edit system configuration
vi .ignite/system.yaml
```

Key settings:

| Setting | Description | Default |
|---------|-------------|---------|
| `model` | LLM model to use | (see system.yaml) |
| `defaults.worker_count` | IGNITIANS parallelism | 3 |

### 4. Set Up Environment Variables

```bash
cp .ignite/.env.example .ignite/.env
vi .ignite/.env
```

Configure API keys and other secrets. `.env` is automatically excluded by `.ignite/.gitignore`.

### 5. Start IGNITE

```bash
# Start from repository root (.ignite/ is auto-detected)
ignite start

# Or explicitly specify workspace
ignite start -w /path/to/your-product-repo
```

### 6. Submit a Task

```bash
ignite plan "Refactor authentication module" -c "Migrate from JWT to OAuth2"
```

## Usage Tips

### Efficient PR Creation

When instructing agents to create PRs, be specific for faster responses:

```bash
ignite plan "Implement fix for Issue #42 and create a PR" \
  -c "Fix: login validation error. Create PR to main branch after fix"
```

### Running Multiple Products in Parallel

You can run separate sessions for each product:

```bash
# Product A
cd /path/to/product-a
ignite start -s product-a

# Product B (in another terminal)
cd /path/to/product-b
ignite start -s product-b
```

### Workspace Cleanup

To clear runtime data (configuration files are preserved):

```bash
ignite clean
```

## Troubleshooting

### `.ignite/` Already Exists

```bash
# Overwrite and reinitialize
ignite init --force
```

### Agents Can't Find Product Files

Verify that the workspace root is correctly configured:

```bash
ignite status
```

Make sure you run `ignite start` from the root of your product repository.

### Migrating Existing Configuration

If you have global configuration in `~/.config/ignite/`, you can migrate it to the workspace:

```bash
ignite init --migrate
```

# GitHub App Setup Guide

This document explains how to set up a GitHub App for using GitHub integration features in IGNITE.

## Overview

### What is a GitHub App?

A GitHub App is an authentication/authorization mechanism for achieving bot-like behavior on GitHub. Unlike Personal Access Tokens (PAT), it has the following characteristics:

- **Bot-branded operations**: Comments and PRs appear with `[bot]` suffix on account name
- **Fine-grained permissions**: Configurable per repository and operation type
- **Expiring tokens**: Automatically expire after a short period for security
- **Human/Bot detection**: Can automatically identify Bot posts when events fire

### Why GitHub App is Needed

IGNITE's GitHub integration uses GitHub App for the following reasons:

1. **Bot response identification**: Clearly identify automated responses from IGNITE as Bot
2. **Infinite loop prevention**: Control to not react to own Bot posts
3. **Security**: Fine-grained access control based on principle of least privilege

## Prerequisites

The following tools must be installed:

```bash
# GitHub CLI (gh)
gh --version

# gh-token extension (for GitHub App token generation)
gh extension list | grep gh-token
```

### Installing gh-token Extension

```bash
gh extension install Link-/gh-token
```

## GitHub App Creation Steps

### 1. Access GitHub App Creation Page

Navigate to https://github.com/settings/apps/new

### 2. Configure Basic Information

| Field | Value |
|-------|-------|
| **GitHub App name** | `ignite-gh-app` or any unique name |
| **Homepage URL** | Project URL or `https://github.com/your-org/ignite` |

### 3. Webhook Settings

IGNITE uses polling to retrieve events, so Webhook is not needed.

- **Active**: Uncheck (disable)

### 4. Permission Settings

In the "Permissions" section, configure the following:

**Repository permissions:**

| Permission | Level | Description |
|------------|-------|-------------|
| **Contents** | Read and write | Read/write files, create commits |
| **Issues** | Read and write | View/comment/create Issues |
| **Pull requests** | Read and write | View/comment/create/merge PRs |
| **Metadata** | Read-only | Repository metadata (auto-configured) |

### 5. Installation Scope

For "Where can this GitHub App be installed?":

- **Only on this account**: Only your account/organization (recommended)

### 6. Create App

Click "Create GitHub App" to complete creation.

Note the **App ID** displayed after creation.

## Private Key Generation

### 1. Generate Private Key

In the "Private keys" section at the bottom of your App's settings page:

1. Click "Generate a private key"
2. A `.pem` file will be automatically downloaded

### 2. Save Private Key

```bash
# Move downloaded Private Key to .ignite/
mv ~/Downloads/ignite-gh-app.*.private-key.pem .ignite/github-app-private-key.pem

# Restrict permissions
chmod 600 .ignite/github-app-private-key.pem
```

## Installing to Repository

### 1. Install the App

On your App's settings page:

1. Click "Install App" in the left menu
2. Select target account/organization
3. Select "Only select repositories" and specify target repositories
4. Click "Install"

## Create Configuration File

### 1. Copy Template

```bash
cp config/github-app.yaml.example config/github-app.yaml
```

### 2. Enter Configuration Values

```yaml
# config/github-app.yaml
github_app:
  app_id: "123456"
  private_key_path: "github-app-private-key.pem"  # relative to .ignite/
  app_name: "your-app-name"
```

**Note**: Installation ID is not required. It is automatically retrieved from the repository during each operation.

## Using the Token Retrieval Script

### Basic Usage

```bash
# Get token by specifying repository
./scripts/utils/get_github_app_token.sh --repo owner/repo

# Output example: ghs_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

Installation ID is automatically retrieved from the repository, allowing the same GitHub App to be used across multiple Organizations/repositories.

### GitHub Operations as Bot

```bash
# Get token and set to environment variable
BOT_TOKEN=$(./scripts/utils/get_github_app_token.sh --repo owner/repo)

# Comment on Issue as Bot
GH_TOKEN="$BOT_TOKEN" gh issue comment 1 --repo owner/repo --body "Hello from IGNITE Bot!"

# Create PR as Bot
GH_TOKEN="$BOT_TOKEN" gh pr create --repo owner/repo --title "Fix bug" --body "Automated fix"
```

### Usage in Scripts

```bash
#!/bin/bash

# Assumes execution from IGNITE project root
BOT_TOKEN=$(./scripts/utils/get_github_app_token.sh --repo owner/repo)

if [[ -z "$BOT_TOKEN" ]]; then
    echo "Error: Failed to get GitHub App token"
    exit 1
fi

# Operate as Bot
GH_TOKEN="$BOT_TOKEN" gh issue comment 123 --repo owner/repo --body "Processing started"
```

## Use Cases in IGNITE

### Issue Comment as Bot

When GitHub Watcher detects a new Issue, auto-respond as Bot:

```yaml
# workspace/.ignite/queue/leader/github_event_xxx.yaml
type: github_event
from: github_watcher
to: leader
payload:
  event_type: issue_created
  repository: owner/repo
  issue_number: 123
  author: human-user
  author_type: User
  body: "There's a bug in the login feature"
```

Leader checks Issue and comments on status as Bot:

```bash
BOT_TOKEN=$(./scripts/utils/get_github_app_token.sh --repo owner/repo)
GH_TOKEN="$BOT_TOKEN" gh issue comment 123 --repo owner/repo --body "Issue received. Starting work."
```

### Human/Bot Detection Logic

GitHub Watcher determines whether the event sender is a Bot and does not react to Bot posts:

```bash
is_human_event() {
    local author_type="$1"
    local author_login="$2"

    # True only if User type and no [bot] suffix
    [[ "$author_type" == "User" ]] && [[ ! "$author_login" =~ \[bot\]$ ]]
}

# Usage example
if is_human_event "$author_type" "$author_login"; then
    # Process human post
    echo "Processing human event..."
fi
```

### Automatic PR Creation

Automatically create PR for Issue:

```bash
# Get Issue content
ISSUE_DATA=$(GH_TOKEN="$BOT_TOKEN" gh api /repos/owner/repo/issues/123)
ISSUE_TITLE=$(echo "$ISSUE_DATA" | jq -r '.title')

# Create implementation branch
git checkout -b ignite/issue-123

# ... IGNITIANs implement ...

# Commit & push
git add -A
git commit -m "fix: resolve issue #123 - ${ISSUE_TITLE}

Co-Authored-By: IGNITE Bot <noreply@ignite.local>"
git push -u origin ignite/issue-123

# Create PR as Bot
GH_TOKEN="$BOT_TOKEN" gh pr create \
    --repo owner/repo \
    --title "fix: resolve issue #123" \
    --body "Closes #123

## Summary
This PR was automatically generated by IGNITE.

## Changes
- (change details)
"
```

## Troubleshooting

### Token Retrieval Error

**Cause 1: gh-token extension not installed**

```bash
gh extension install Link-/gh-token
```

**Cause 2: Private Key file not found**

```bash
# Check path
cat config/github-app.yaml | grep private_key_path

# Verify file exists
ls -la .ignite/github-app-private-key.pem
```

**Cause 3: Incorrect App ID or Installation ID**

```bash
# Re-verify Installation ID
gh api /users/{username}/installation | jq '.id'
```

### Permission Error

**Symptom**: `Resource not accessible by integration`

**Solution**: Check GitHub App permission settings and add required permissions.
After changing permissions, reinstalling to repository may be required.

### Bot Comment Not Displayed

**Symptom**: Comment succeeds but not displayed as Bot

**Solution**: Verify `GH_TOKEN` environment variable is correctly set:

```bash
# Correct usage
GH_TOKEN="$BOT_TOKEN" gh issue comment ...

# Incorrect usage (uses normal PAT)
gh issue comment ...
```

## Security Notes

1. **Private Key protection**: Keep `.pem` file secure and never commit to repository
2. **Principle of least privilege**: Only grant minimum required permissions to App
3. **Token handling**: Tokens expire quickly, but be careful not to output to logs
4. **Configuration file**: `config/github-app.yaml` is added to `.gitignore`

## Related Documentation

- [GitHub Watcher Usage Guide](./github-watcher_en.md) - Event monitoring system usage
- [Protocol Specification](./protocol.md) - Message formats
- [Architecture](./architecture.md) - System structure details

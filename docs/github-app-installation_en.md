# GitHub App (ignite-gh-app) Installation Guide

This guide explains how to install **ignite-gh-app** to use IGNITE's GitHub integration features.

> **For developers**: If you want to create your own GitHub App, see [github-app-setup_en.md](./github-app-setup_en.md).
> This guide is for users who want to install and start using the published **ignite-gh-app**.

## 1. Prerequisites

The following tools must be installed:

- **IGNITE** must be installed (see [README](../README.md))
- **GitHub CLI (gh)** must be installed

```bash
# Verify IGNITE
ignite --version

# Verify GitHub CLI
gh --version

# Install gh-token extension (if not installed)
gh extension install Link-/gh-token
```

## 2. Overview of ignite-gh-app

### What is a GitHub App?

A GitHub App is a mechanism for achieving bot-like behavior on GitHub. With ignite-gh-app, you can:

- **Automatic Issue processing**: Mention `@ignite-gh-app` in an Issue and IGNITE will automatically start working on it
- **Automatic PR creation**: Analyze Issue content and automatically create fix PRs
- **Bot-branded responses**: Comments from IGNITE appear as `ignite-gh-app[bot]`, clearly distinguishing from human actions
- **Label-based auto-triggers**: Automatically process Issues with labels like `ignite-auto`

### Capabilities

| Feature | Description |
|---------|-------------|
| Issue monitoring | Automatically detect new Issues and comments |
| PR monitoring | Automatically detect new PRs and review comments |
| Mention response | Start implementation tasks with `@ignite-gh-app implement` |
| Automatic PR creation | Create fix PRs for Issues as Bot |
| Progress reporting | Post processing status as comments on Issues |

### Required Permissions

ignite-gh-app requests the following permissions:

| Permission | Level | Purpose |
|------------|-------|---------|
| **Contents** | Read and write | Read/write files, create commits |
| **Issues** | Read and write | View/comment/create Issues |
| **Pull requests** | Read and write | View/comment/create PRs |
| **Metadata** | Read-only | Retrieve repository metadata |

## 3. Installation Steps

### Step 1: Access the App Page

Navigate to the ignite-gh-app installation page:

**https://github.com/apps/ignite-gh-app**

Click the "Install" button.

### Step 2: Select Installation Target

Select the account or Organization to install to.

- **All repositories**: Enable for all repositories
- **Only select repositories**: Enable for specific repositories only (recommended)

> **Recommended**: Start by selecting specific repositories and add more after verifying functionality.

### Step 3: Confirm Permissions

Review the displayed permission list (see the permission table above). If acceptable, click "Install".

### Step 4: Configure IGNITE

#### 4-1. Create GitHub App Configuration File

```bash
# Copy template
cp config/github-app.yaml.example config/github-app.yaml
```

Edit the configuration file to enter the App ID and Private Key path:

```yaml
# config/github-app.yaml
github_app:
  app_id: "YOUR_APP_ID"
  private_key_path: "~/.config/ignite/github-app-private-key.pem"
  app_name: "ignite-gh-app"
```

> **Note**: The App ID can be found on the GitHub App settings page. For Private Key generation, see [github-app-setup_en.md](./github-app-setup_en.md).

#### 4-2. Configure GitHub Watcher

Set up the repositories to monitor:

```bash
# Copy template (first time only)
cp config/github-watcher.yaml.example config/github-watcher.yaml
```

Add target repositories to `config/github-watcher.yaml`:

```yaml
watcher:
  repositories:
    - repo: your-org/your-repo
    # To monitor multiple repositories:
    # - repo: your-org/another-repo
    #   base_branch: develop

  # Polling interval (seconds). Recommended: 60 seconds or more
  interval: 60
```

## 4. Verification

### Start IGNITE

Start IGNITE with the GitHub Watcher enabled:

```bash
ignite start --with-watcher
```

> **Note**: Setting `auto_start.enabled: true` in `config/github-watcher.yaml` enables automatic startup without the `--with-watcher` option.

### Mention Test

Open any Issue in the target repository and post the following comment:

```
@ignite-gh-app explain
```

If working correctly, a response comment from `ignite-gh-app[bot]` will be posted shortly.

### Auto-trigger Test

Create an Issue with the `ignite-auto` label and IGNITE will automatically start processing.

```
Title: Test Issue
Body: This Issue is for testing
Label: ignite-auto
```

## 5. Customization

The following settings can be customized in `config/github-watcher.yaml`.

### Trigger Keywords

```yaml
triggers:
  mention_pattern: "@ignite-gh-app"
  keywords:
    implement:
      - "implement"
      - "fix this"
      - "create PR"
    review:
      - "review"
      - "check this"
    explain:
      - "explain"
      - "describe"
    insights:
      - "insights"
      - "insight"
```

### Response Templates

```yaml
responses:
  # Auto-comment on task receipt
  acknowledge: true
  acknowledge_template: |
    Issue received. Starting processing.
    ---
    *Generated by IGNITE AI Team*

  # Auto-comment on success
  report_success: true
  success_template: |
    ✅ Processing completed!
    {details}
    ---
    *Generated by IGNITE AI Team*
```

### Polling Interval

```yaml
watcher:
  # Polling interval (seconds)
  # GitHub API rate limit: 5000 requests/hour (authenticated)
  # Recommended: 60 seconds or more
  interval: 60
```

### Access Control

```yaml
access_control:
  # true: Only allow whitelisted users
  enabled: true
  allowed_users:
    - "admin-user"
    - "trusted-developer"
```

## 6. Troubleshooting

### IGNITE Does Not Respond to Issues

**Checklist**:

1. **Verify Watcher is running**:
   ```bash
   ignite status
   ```
   Confirm that GitHub Watcher shows `running`.

2. **Check monitored repository settings**:
   ```bash
   cat config/github-watcher.yaml
   ```
   Verify the target repository is included in `watcher.repositories`.

3. **Verify GitHub App is installed on the repository**:
   Check the target repository's Settings > Integrations > GitHub Apps for `ignite-gh-app`.

4. **Check logs**:
   ```bash
   cat workspace/logs/github_watcher.log
   ```

### Permission Error (`Resource not accessible by integration`)

**Cause**: Required permissions are not granted to the GitHub App.

**Solution**:
1. Navigate to https://github.com/settings/installations
2. Click "Configure" for `ignite-gh-app`
3. Verify that required permissions (Contents, Issues, Pull requests) are granted under "Repository permissions"
4. After changing permissions, reinstalling to the repository may be required

### Infinite Loop (Bot Keeps Responding to Its Own Comments)

**Normally prevented automatically**: GitHub Watcher has `ignore_bot: true` set by default and does not react to Bot posts.

If this occurs:
1. Check the `ignore_bot` setting in `config/github-watcher.yaml`:
   ```yaml
   watcher:
     ignore_bot: true
   ```
2. Stop and restart IGNITE:
   ```bash
   ignite stop
   ignite start --with-watcher
   ```

## 7. Uninstallation

### Remove from GitHub

1. Navigate to https://github.com/settings/installations
2. Click "Configure" for `ignite-gh-app`
3. Click "Uninstall" at the bottom of the page

### Remove IGNITE Configuration

```bash
# Remove GitHub App configuration file
rm config/github-app.yaml

# Remove GitHub Watcher configuration file (only if not using Watcher)
rm config/github-watcher.yaml

# Remove Private Key
rm ~/.config/ignite/github-app-private-key.pem
```

> **Note**: If you continue to use GitHub Watcher, do not delete `config/github-watcher.yaml`.

## 8. Security Notes

1. **Private Key protection**: Restrict permissions on `~/.config/ignite/github-app-private-key.pem` with `chmod 600` and never commit it to a repository
2. **Principle of least privilege**: Select "Only select repositories" during installation and only install to necessary repositories
3. **Token handling**: GitHub App Tokens automatically expire after a short period, but avoid outputting them to log files
4. **Configuration file management**: `config/github-app.yaml` is added to `.gitignore` and will not be committed to the repository
5. **Access control**: Use `access_control` in `config/github-watcher.yaml` to restrict which users can trigger actions via mentions

## Related Documentation

- [GitHub App Setup Guide (for developers)](./github-app-setup_en.md) — Steps to create your own GitHub App
- [GitHub Watcher Usage Guide](./github-watcher_en.md) — Detailed event monitoring configuration
- [Architecture](./architecture.md) — System structure details
- [Protocol Specification](./protocol.md) — Message formats

# Windows (WSL2) Setup Guide

IGNITE runs with **full functionality on WSL2** with zero code changes. This guide walks you through setting up your Windows environment for IGNITE.

## Prerequisites

| Requirement | Version |
|-------------|---------|
| Windows | 10 version 2004+ (Build 19041+) or Windows 11 |
| WSL2 | Enabled (default on Windows 11) |
| Ubuntu | 22.04 LTS or later (recommended) |

> **Note**: Windows Home edition is fully supported. Hyper-V is automatically enabled as part of the WSL2 installation.

## 1. Install WSL2

Open **PowerShell as Administrator** and run:

```powershell
wsl --install
```

This command:
- Enables the WSL2 feature
- Installs the default Linux distribution (Ubuntu)

Restart your computer when prompted.

After restart, Ubuntu will launch automatically and ask you to create a username and password.

> **Tip**: If you already have WSL1, upgrade to WSL2:
> ```powershell
> wsl --set-default-version 2
> wsl --set-version Ubuntu 2
> ```

## 2. Configure .wslconfig (Recommended)

Create or edit `%USERPROFILE%\.wslconfig` (e.g. `C:\Users\YourName\.wslconfig`):

```ini
[wsl2]
memory=8GB
processors=4
localhostForwarding=true
```

Then restart WSL to apply:

```powershell
wsl --shutdown
```

| Setting | Recommended | Description |
|---------|-------------|-------------|
| `memory` | 8GB+ | IGNITE runs multiple Claude Code processes (~300-500MB each) |
| `processors` | 4+ | Parallel agent execution benefits from multiple cores |
| `localhostForwarding` | true | Access WSL2 services from Windows browser |

## 3. Install Required Software in WSL2

Open your WSL2 Ubuntu terminal and run:

```bash
# Update packages
sudo apt update && sudo apt upgrade -y

# Install required tools
sudo apt install -y tmux git jq curl

# Install GitHub CLI
# See: https://github.com/cli/cli/blob/trunk/docs/install_linux.md
(type -p wget >/dev/null || (sudo apt update && sudo apt-get install wget -y)) \
  && sudo mkdir -p -m 755 /etc/apt/keyrings \
  && out=$(mktemp) && wget -nv -O$out https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  && cat $out | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
  && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
  && sudo apt update \
  && sudo apt install gh -y

# Install yq (optional but recommended)
sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq \
  && sudo chmod +x /usr/local/bin/yq

# Authenticate with GitHub
gh auth login
```

Verify installations:

```bash
tmux -V          # tmux 3.x+
git --version    # git 2.x+
gh --version     # gh 2.x+
jq --version     # jq 1.6+
yq --version     # yq 4.x+ (optional)
```

## 4. Install Claude Code CLI

Install Claude Code inside WSL2:

```bash
# Install via npm (Node.js required)
npm install -g @anthropic-ai/claude-code

# Or install Node.js first if needed
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt install -y nodejs
npm install -g @anthropic-ai/claude-code
```

Verify:

```bash
claude --version
```

> **Note**: Claude Code CLI v2.1.34+ supports Windows natively (PowerShell + Git Bash), but running inside WSL2 provides the best experience for IGNITE, as it ensures full compatibility with tmux and Bash scripts.

## 5. Install and Run IGNITE

```bash
# Clone the repository (inside WSL2, NOT in /mnt/c/)
cd ~
git clone https://github.com/myfinder/IGNITE.git
cd IGNITE

# Start IGNITE
./scripts/ignite start
```

Or install from a release:

```bash
gh release download --repo myfinder/IGNITE --pattern '*.tar.gz'
tar xzf ignite-*.tar.gz
./install.sh
ignite start
```

## 6. File System Performance Warning

> **IMPORTANT**: Always work within the WSL2 file system (`~/`, `/home/`). **Do NOT** use Windows-mounted paths (`/mnt/c/`, `/mnt/d/`).

| Path | Performance | Use for IGNITE? |
|------|-------------|-----------------|
| `~/IGNITE/` (WSL2 ext4) | Fast (native Linux speed) | **Yes** |
| `/mnt/c/Users/.../IGNITE/` (Windows NTFS) | Very slow (9x overhead) | **No** |

Working on `/mnt/c/` causes:
- **Slow git operations** (clone, status, diff)
- **SQLite locking issues** (memory.db corruption risk)
- **File watcher failures** (inotify not supported on NTFS mounts)

If you need to access files from Windows, use the `\\wsl$\Ubuntu\home\<user>\` network path instead.

## 7. VS Code Remote WSL Integration

VS Code provides seamless integration with WSL2:

1. Install [VS Code](https://code.visualstudio.com/) on Windows
2. Install the [WSL extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-wsl)
3. Open IGNITE from WSL2:

```bash
# In WSL2 terminal
cd ~/IGNITE
code .
```

This opens VS Code on Windows, connected to the WSL2 file system. You get:
- Full IntelliSense for files inside WSL2
- Integrated terminal running in WSL2
- Git operations using WSL2's git
- Extensions run inside WSL2 for best performance

## 8. Windows Terminal Configuration

[Windows Terminal](https://aka.ms/terminal) provides the best experience for IGNITE's tmux sessions.

**Recommended settings** (Settings > Ubuntu profile):

| Setting | Recommended Value | Reason |
|---------|-------------------|--------|
| Font | Cascadia Code NF / Hack Nerd Font | Supports special characters in tmux status bar |
| Font size | 10-12 | Fits more panes on screen |
| Color scheme | One Half Dark / Tango Dark | Good contrast for tmux panes |
| Scrollback | 10000+ | Preserve agent output history |

**Useful shortcuts**:

| Shortcut | Action |
|----------|--------|
| `Ctrl+Shift+T` | New tab |
| `Alt+Shift+D` | Split pane |
| `Ctrl+Shift+W` | Close pane |
| `Ctrl+Shift+F` | Find in terminal |

> **Tip**: Pin your WSL2 Ubuntu profile as the default in Windows Terminal for quick access to IGNITE.

## 9. Troubleshooting

### WSL2 fails to install

**Symptom**: `wsl --install` fails or WSL2 is not available.

**Solution**:
```powershell
# Enable required Windows features manually
dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
# Restart, then:
wsl --set-default-version 2
```

### "Cannot access WSL2 from Windows"

**Symptom**: Cannot reach WSL2 services from Windows browser.

**Solution**: Ensure `localhostForwarding=true` is set in `.wslconfig`, then restart WSL:
```powershell
wsl --shutdown
```

### tmux display issues

**Symptom**: Characters display incorrectly in tmux.

**Solution**:
1. Install a Nerd Font (e.g., [Hack Nerd Font](https://www.nerdfonts.com/))
2. Set it as the font in Windows Terminal
3. Add to `~/.tmux.conf` if needed:
   ```bash
   set -g default-terminal "tmux-256color"
   ```

### Slow file operations

**Symptom**: Git operations or IGNITE startup is unusually slow.

**Solution**: Confirm you are working in the WSL2 file system:
```bash
# Check your current path
pwd
# Should show /home/<user>/... NOT /mnt/c/...
```

If files are on `/mnt/c/`, move them:
```bash
cp -r /mnt/c/Users/YourName/IGNITE ~/IGNITE
cd ~/IGNITE
```

### Claude Code connection issues

**Symptom**: Claude Code CLI cannot connect to API.

**Solution**: Check DNS resolution inside WSL2:
```bash
# Test connectivity
curl -s https://api.anthropic.com > /dev/null && echo "OK" || echo "FAIL"

# If DNS fails, add Google DNS
echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf
```

---

*See also: [README.md](../README.md) | [Architecture](architecture.md) | [Protocol](protocol.md)*

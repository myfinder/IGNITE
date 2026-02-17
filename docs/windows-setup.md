# Windows (WSL2) セットアップガイド

IGNITEは **WSL2 上でコード変更なしに全機能が動作** します。このガイドでは、Windows環境でIGNITEを使うための手順を説明します。

## 前提条件

| 要件 | バージョン |
|------|-----------|
| Windows | 10 version 2004以降 (Build 19041+) または Windows 11 |
| WSL2 | 有効化済み（Windows 11ではデフォルトで有効） |
| Ubuntu | 22.04 LTS 以降（推奨） |

> **Note**: Windows Home エディションでも問題なく動作します。Hyper-Vは WSL2 のインストール時に自動的に有効化されます。

## 1. WSL2 のインストール

**管理者権限のPowerShell** を開き、以下を実行します：

```powershell
wsl --install
```

このコマンドにより以下が行われます：
- WSL2 機能の有効化
- デフォルトの Linux ディストリビューション（Ubuntu）のインストール

再起動を求められた場合は、PCを再起動してください。

再起動後、Ubuntu が自動的に起動し、ユーザー名とパスワードの設定を求められます。

> **Tip**: 既に WSL1 をお使いの場合は、WSL2 にアップグレードしてください：
> ```powershell
> wsl --set-default-version 2
> wsl --set-version Ubuntu 2
> ```

## 2. .wslconfig の設定（推奨）

`%USERPROFILE%\.wslconfig`（例：`C:\Users\ユーザー名\.wslconfig`）を作成または編集します：

```ini
[wsl2]
memory=8GB
processors=4
localhostForwarding=true
```

設定を反映するため、WSL を再起動します：

```powershell
wsl --shutdown
```

| 設定項目 | 推奨値 | 理由 |
|---------|--------|------|
| `memory` | 8GB以上 | IGNITEは複数のClaude Codeプロセスを実行（各約300-500MB） |
| `processors` | 4以上 | エージェントの並列実行に複数コアが有効 |
| `localhostForwarding` | true | Windows ブラウザから WSL2 のサービスにアクセス可能に |

## 3. 必要なソフトウェアのインストール

WSL2 の Ubuntu ターミナルを開き、以下を実行します：

```bash
# パッケージを更新
sudo apt update && sudo apt upgrade -y

# 必要なツールをインストール
sudo apt install -y git jq curl

# GitHub CLI のインストール
# 参考: https://github.com/cli/cli/blob/trunk/docs/install_linux.md
(type -p wget >/dev/null || (sudo apt update && sudo apt-get install wget -y)) \
  && sudo mkdir -p -m 755 /etc/apt/keyrings \
  && out=$(mktemp) && wget -nv -O$out https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  && cat $out | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
  && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
  && sudo apt update \
  && sudo apt install gh -y

# yq のインストール（任意だが推奨）
sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq \
  && sudo chmod +x /usr/local/bin/yq

# GitHub 認証
gh auth login
```

インストールの確認：

```bash
git --version    # git 2.x+
gh --version     # gh 2.x+
jq --version     # jq 1.6+
yq --version     # yq 4.x+（任意）
```

## 4. OpenCode CLI のインストール

WSL2 内で OpenCode をインストールします：

```bash
# 公式インストーラーで導入
curl -fsSL https://opencode.ai/install | bash
```

確認：

```bash
opencode --version
```

> **Note**: IGNITE のデフォルト CLI プロバイダーは OpenCode です。Claude Code を代替として使用する場合は、`npm install -g @anthropic-ai/claude-code` でインストールし、`config/system.yaml` の `cli.provider` を `claude` に変更してください。

> **Ollama（ローカルLLM）を使う場合**: WSL2 内で `ollama serve` を起動し、`config/system.yaml` の `cli.model` を `ollama/qwen3-coder:30b` 等に設定してください。API Key は不要です。詳細は [Ollama 公式ドキュメント](https://docs.ollama.com/integrations/opencode) を参照。

## 5. IGNITE のインストールと起動

```bash
# リポジトリをクローン（WSL2内で実行。/mnt/c/ は使わないこと）
cd ~
git clone https://github.com/myfinder/IGNITE.git
cd IGNITE

# IGNITE を起動
./scripts/ignite start
```

リリースからインストールする場合：

```bash
gh release download --repo myfinder/IGNITE --pattern '*.tar.gz'
tar xzf ignite-*.tar.gz
./install.sh
ignite start
```

## 6. ファイルシステム性能に関する重要な注意

> **重要**: 作業は必ず WSL2 のファイルシステム内（`~/`, `/home/`）で行ってください。Windows のマウントパス（`/mnt/c/`, `/mnt/d/`）は**絶対に使わないでください**。

| パス | 性能 | IGNITE での使用 |
|------|------|----------------|
| `~/IGNITE/`（WSL2 ext4） | 高速（Linuxネイティブ速度） | **推奨** |
| `/mnt/c/Users/.../IGNITE/`（Windows NTFS） | 非常に遅い（約9倍のオーバーヘッド） | **使用禁止** |

`/mnt/c/` 上で作業すると以下の問題が発生します：
- **git操作が極端に遅い**（clone, status, diff）
- **SQLiteのロック問題**（memory.db の破損リスク）
- **ファイル監視の失敗**（NTFSマウントでは inotify が非対応）

Windows からファイルにアクセスしたい場合は、エクスプローラーで `\\wsl$\Ubuntu\home\<ユーザー名>\` のネットワークパスを使用してください。

## 7. VS Code Remote WSL 連携

VS Code は WSL2 とシームレスに連携できます：

1. Windows に [VS Code](https://code.visualstudio.com/) をインストール
2. [WSL 拡張機能](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-wsl) をインストール
3. WSL2 から IGNITE を開く：

```bash
# WSL2 ターミナルで
cd ~/IGNITE
code .
```

これにより Windows 上の VS Code が WSL2 のファイルシステムに接続されます：
- WSL2 内のファイルに対する IntelliSense が利用可能
- 統合ターミナルが WSL2 内で動作
- Git 操作は WSL2 の git を使用
- 拡張機能が WSL2 内で実行され最適なパフォーマンスを発揮

## 8. Windows Terminal の設定

[Windows Terminal](https://aka.ms/terminal) は IGNITE の実行に適した環境を提供します。

**推奨設定**（設定 > Ubuntu プロファイル）：

| 設定 | 推奨値 | 理由 |
|------|--------|------|
| フォント | Cascadia Code NF / Hack Nerd Font | 特殊文字に対応 |
| フォントサイズ | 10-12 | 画面を有効活用 |
| 配色 | One Half Dark / Tango Dark | コントラストが良好 |
| スクロールバック | 10000以上 | エージェントの出力履歴を保持 |

**便利なショートカット**：

| ショートカット | 動作 |
|--------------|------|
| `Ctrl+Shift+T` | 新しいタブ |
| `Alt+Shift+D` | ペイン分割 |
| `Ctrl+Shift+W` | ペインを閉じる |
| `Ctrl+Shift+F` | ターミナル内検索 |

> **Tip**: Windows Terminal で WSL2 Ubuntu プロファイルをデフォルトに設定すると、すぐに IGNITE にアクセスできて便利です。

## 9. トラブルシューティング

### WSL2 のインストールに失敗する

**症状**: `wsl --install` が失敗する、または WSL2 が利用できない。

**対処法**:
```powershell
# Windows の機能を手動で有効化
dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
# 再起動後:
wsl --set-default-version 2
```

### Windows から WSL2 にアクセスできない

**症状**: Windows のブラウザから WSL2 のサービスに接続できない。

**対処法**: `.wslconfig` に `localhostForwarding=true` が設定されていることを確認し、WSL を再起動します：
```powershell
wsl --shutdown
```

### ファイル操作が遅い

**症状**: Git 操作や IGNITE の起動が異常に遅い。

**対処法**: WSL2 のファイルシステム内で作業しているか確認します：
```bash
# 現在のパスを確認
pwd
# /home/<ユーザー名>/... と表示されるべき。/mnt/c/... ではないこと
```

ファイルが `/mnt/c/` にある場合は移動してください：
```bash
cp -r /mnt/c/Users/ユーザー名/IGNITE ~/IGNITE
cd ~/IGNITE
```

### Claude Code の接続に問題がある

**症状**: Claude Code CLI が API に接続できない。

**対処法**: WSL2 内の DNS 解決を確認します：
```bash
# 接続テスト
curl -s https://api.anthropic.com > /dev/null && echo "OK" || echo "FAIL"

# DNS に問題がある場合、Google DNS を追加
echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf
```

---

*参照: [README.md](../README.md) | [アーキテクチャ](architecture.md) | [プロトコル](protocol.md)*

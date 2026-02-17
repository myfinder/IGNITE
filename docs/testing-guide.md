# IGNITE テストガイド

このドキュメントでは、IGNITE の動作確認手順を説明します。

## 前提条件

### 必須ツール

```bash
# Ubuntu/Debian (Codespace 含む)
sudo apt install bats

# opencode
curl -fsSL https://opencode.ai/install | bash

# GitHub CLI (未インストールの場合)
# https://cli.github.com/

# オプション
sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && sudo chmod +x /usr/local/bin/yq
```

### IGNITE のインストール

```bash
cd /path/to/IGNITE
bash scripts/install.sh --skip-deps --force
```

## 1. ユニットテスト (bats)

```bash
# 全テスト実行
bats tests/

# 特定テストファイルのみ
bats tests/test_cmd_start_init.bats
bats tests/test_security.bats
```

## 2. dry-run による起動確認

実際のエージェントサーバー起動をスキップし、初期化フローを検証します。

```bash
# ワークスペース初期化
ignite init -w /tmp/test-workspace

# dry-run 実行
scripts/ignite start --dry-run --skip-validation -n -w /tmp/test-workspace
```

### カラー出力の確認

```bash
# 非対話環境 (パイプ) → エスケープシーケンスが出ないこと
scripts/ignite start --dry-run --skip-validation -n -w /tmp/test-workspace 2>&1 | cat -v | grep -c '\^\['

# NO_COLOR=1 → エスケープシーケンスが出ないこと
NO_COLOR=1 scripts/ignite start --dry-run --skip-validation -n -w /tmp/test-workspace

# 通常ターミナル (TTY) → カラーが出ること（直接ターミナルで実行）
scripts/ignite start --dry-run --skip-validation -n -w /tmp/test-workspace
```

## 3. systemd サービスの動作確認

### Codespace での systemd セットアップ

Codespace はデフォルトで systemd が無効です。以下の手順で有効化できます。

```bash
# 1. dbus-user-session パッケージのインストール
sudo apt-get install -y dbus-user-session

# 2. systemd のマーカーディレクトリを作成
sudo mkdir -p /run/systemd/system

# 3. ユーザーランタイムディレクトリを準備
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
sudo mkdir -p "$XDG_RUNTIME_DIR"
sudo chown "$(id -u):$(id -g)" "$XDG_RUNTIME_DIR"

# 4. cgroup の委任設定
sudo chown -R "$(id -u):$(id -g)" /sys/fs/cgroup/init 2>/dev/null || true
echo "+cpu +memory +pids" | sudo tee /sys/fs/cgroup/init/cgroup.subtree_control 2>/dev/null || true

# 5. systemd --user を起動
/usr/lib/systemd/systemd --user &disown
sleep 5

# 6. 環境変数を設定（以降のシェルコマンドで使用）
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"

# 7. 動作確認
systemctl --user is-system-running
# → "running" と表示されれば OK
```

> **注意**: この手順は Codespace セッション毎に必要です（永続化されません）。

### サービスの起動テスト

```bash
# 環境変数を設定（Codespace の場合）
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"

# 1. ワークスペース初期化
ignite init -w /tmp/test-workspace

# 2. systemd ユニットファイルをインストール
ignite service install --force

# 3. 環境変数ファイルを生成
ignite service setup-env test-session --force

# 4. ワークスペースパスを追記
echo "IGNITE_WORKSPACE=/tmp/test-workspace" >> ~/.config/ignite/env.test-session

# 5. サービス起動
ignite service start test-session

# 6. 状態確認
systemctl --user status ignite@test-session.service

# 7. サービス再起動
ignite service restart test-session

# 8. ログ確認
tail -f /tmp/test-workspace/.ignite/logs/queue_monitor.log
```

### サービスの停止・クリーンアップ

```bash
ignite service stop test-session
systemctl --user reset-failed ignite@test-session.service 2>/dev/null
```

## 4. queue_monitor のプログレス表示確認

サービス起動中に progress_update メッセージをキューに投入して、表示機能を確認します。

```bash
QUEUE_DIR="/tmp/test-workspace/.ignite/queue/leader"

# MIME 形式の progress_update メッセージを作成
cat > "$QUEUE_DIR/progress_update_$(date +%s%6N).mime" << 'MIME'
MIME-Version: 1.0
From: sub-leader-1
To: leader
Date: Mon, 16 Feb 2026 00:00:00 +0000
X-IGNITE-Type: progress_update
Content-Type: text/x-yaml; charset=utf-8

type: progress_update
from: sub-leader-1
to: leader
  repository: myfinder/IGNITE
  issue_id: "123"
  tasks_completed: 3
  tasks_total: 10
  summary: "テスト用プログレスメッセージ"
MIME

# キュー監視の次のポーリング（デフォルト10秒間隔）を待つ
sleep 12

# 結果確認
cat /tmp/test-workspace/.ignite/state/progress_update_latest.txt
tail -5 /tmp/test-workspace/.ignite/logs/queue_monitor.log
```

期待される出力:

```
Progress Update
- Repository: myfinder/IGNITE
- Issue: 123
- Tasks: 3/10
- Summary: テスト用プログレスメッセージ
- Time: 2026-02-16 00:00:12 UTC
```

## 5. format_progress_message の単体確認

```bash
source scripts/lib/core.sh
format_progress_message "planning" "25" "設計中"
# → stage=planning percent=25 message=設計中

format_progress_message
# → stage=working percent=0 message=
```

# v0.1.14 - プロトコル刷新 & 並列作業基盤強化

IGNITE v0.1.14 では、メッセージプロトコルの根本改善と並列作業基盤の強化を中心に、6つのPRをリリースします。

---

## ⚠️ Breaking Protocol Changes

### statusフィールド廃止 → ファイル存在モデル移行 (PR #117 / Issue #116)

メッセージキューの状態管理方式を根本的に変更しました。従来の `status` フィールドによる配信制御を廃止し、**ファイルの存在位置**で状態を管理する「ファイル存在モデル」に移行しました。

**Why**: LLMエージェントが `status: queued` の代わりに `status: pending` を書くなど、プロトコル違反が頻発していました。PR #114 で自動修正基盤を導入しましたが、根本原因は「エージェントが正しいstatus値を書く必要がある」というプロトコル設計自体にありました。ファイル存在モデルでは、エージェントがstatusフィールドを書く必要がなくなり、違反が構造的に発生しなくなります。

**How**: `queue_monitor.sh` は `status` フィールドを一切参照しなくなりました。キューディレクトリ直下の `.yaml` ファイルを未処理メッセージとして検出し、`processed/` サブディレクトリに `mv` してから処理します（at-most-once配信保証）。メモリ内の `PROCESSED_FILES` 連想配列も廃止され、ディレクトリ構造による永続的な状態管理に置き換えられました。

**変更範囲**: scripts 4ファイル + instructions 7ファイル + docs 6ファイル（計17ファイル）

#### マイグレーションガイド

**Before (v0.1.13以前)**:
```yaml
# メッセージYAMLに status フィールドが必須
type: task_assignment
from: coordinator
to: ignitian_1
timestamp: "2026-02-05T12:00:00+09:00"
priority: high
payload:
  task_id: "task_001"
  title: "タスク名"
status: queued          # ← この行が必須だった
```

**After (v0.1.14)**:
```yaml
# status フィールドは不要（書いても無視される）
type: task_assignment
from: coordinator
to: ignitian_1
timestamp: "2026-02-05T12:00:00+09:00"
priority: high
payload:
  task_id: "task_001"
  title: "タスク名"
# status フィールドなし — ファイルが queue/ にあれば未処理、processed/ にあれば処理済み
```

**後方互換性**: `status` フィールドが存在しても無視されます。既存のメッセージテンプレートやスクリプトは修正なしで動作します。

---

## ✨ Features

### per-IGNITIAN 作業ディレクトリ分離 (PR #118 / Issue #111)

複数のIGNITIANが同一リポジトリの異なるIssueに並列で作業する際に発生するリポジトリ競合を解消しました。`IGNITE_WORKER_ID` 環境変数に基づき、IGNITIAN ごとに独立したクローンディレクトリを使用します。

- `setup_repo.sh` の `repo_to_path()` が `${repo_name}_ignitian_${WORKER_ID}` パスを生成
- primary clone が存在する場合、`git clone --no-hardlinks` でローカルから高速clone + origin URL再設定
- `.git` ディレクトリが完全に独立し、git lockファイル競合も解消
- `IGNITE_WORKER_ID` 未設定時は従来動作を維持（後方互換性）

### create_pr.sh --botフラグ対応 (PR #110 / Issue #87)

`create_pr.sh` の `create_branch` 関数に `--bot` フラグによる非対話モードを追加。tmux環境でのハングを解消。

---

## ♻️ Refactoring

### scripts/ignite 13モジュール分割 (PR #115 / Issue #101)

約2700行の単一ファイル `scripts/ignite` を13モジュールに分割し、52行のエントリポイントから各モジュールを `source` する4層構造に再構成しました。

**Why**: 2700行を超える単一ファイルは、複数エージェントが同時に異なる機能を修正する際にマージコンフリクトが頻発し、保守性・開発効率の低下を招いていました。

**How**: 機能を依存関係に基づいて4層に分類し、`scripts/lib/` 配下の13モジュールに分割しました。

| Layer | モジュール | 役割 |
|-------|-----------|------|
| Layer 0 | `core.sh` | 定数・ユーティリティ |
| Layer 1 | `session.sh`, `agent.sh`, `cost_utils.sh` | 基盤サービス |
| Layer 2 | `cmd_help.sh` | ヘルプ（他コマンドに非依存） |
| Layer 3 | `cmd_start.sh`, `cmd_stop.sh`, `cmd_status.sh`, `cmd_plan.sh`, `cmd_cost.sh`, `cmd_work_on.sh`, `commands.sh` | コマンド群 |

外部からの振る舞いに変更はありません。全7種テストPASS（行数確認・モジュール存在確認・44関数過不足確認）。

---

## 🔧 Improvements

### プロトコル違反耐性基盤 — DLQ + リトライ (PR #114 / Issue #113)

LLMエージェントが生成する不正なメッセージ（非標準ファイル名、不正status値）を `queue_monitor.sh` がシステム側で自動吸収する機能を追加しました。

- `normalize_filename()`: 非標準ファイル名をYAML内の `type:` + `timestamp:` から正規化リネーム
- 未知のstatus値を自動修正（`queued` に補正）
- 元の時系列順を保持（YAMLタイムスタンプからエポックマイクロ秒を算出）

> **Note**: この基盤は PR #117 のstatusフィールド廃止により「status自動修正」部分は不要になりましたが、ファイル名正規化機能は引き続き有効です。PR #114（基盤導入）→ PR #117（根本改善）の段階的アプローチにより、安全にプロトコルを刷新できました。

---

## 🐛 Bug Fixes

### costsコスト表示バグ修正 (PR #112 / Issue #103)

`ignite cost` コマンドでコストが表示されない不具合を修正。`CLAUDE_PROJECTS_DIR` の計算基準を `PROJECT_ROOT` から `WORKSPACE_DIR` に変更し、Claude Code のセッションファイルパスと一致させました。

---

## Full Changelog

- PR #110: fix: avoid interactive prompt in create_branch (#87)
- PR #112: fix: compute CLAUDE_PROJECTS_DIR from WORKSPACE_DIR (#103)
- PR #114: fix: queue_monitor.sh にメッセージプロトコル違反の自動修正機能を追加 (#113)
- PR #115: refactor: scripts/ignite のモジュール分割リファクタリング (#101)
- PR #117: fix: statusフィールド廃止 — ファイル存在モデルへ移行 (#116)
- PR #118: fix: per-IGNITIAN リポジトリ分離で並列作業時の競合を解消 (#111)

# AGENTS.md

IGNITE プロジェクトの AI エージェント向けガイドです。

## プロジェクト概要

IGNITE は bash ベースのマルチエージェントオーケストレーションシステムです。OpenCode (ヘッドレスモード) + systemd で構成されます。

## リポジトリ構成

```
scripts/
  ignite              # メインエントリポイント
  lib/                # コアモジュール (.sh)
  utils/              # ユーティリティスクリプト
  schema.sql          # メモリDB スキーマ
  schema_migrate.sh   # マイグレーション
config/               # デフォルト設定ファイル (.yaml)
instructions/         # エージェント向けプロンプト
characters/           # キャラクター定義
templates/systemd/    # systemd ユニットファイル
tests/                # bats テスト
docs/                 # ドキュメント
```

## 開発ワークフロー

### 依存関係

- **必須**: opencode, curl, jq
- **任意**: yq (v4.30+), sqlite3, python3

### テスト

```bash
# 全テスト実行（並列）
bats --jobs "$(($(nproc) * 8))" tests/

# 特定テストファイル
bats tests/test_cmd_start_init.bats
```

PR を出す前に必ず `bats --jobs "$(($(nproc) * 8))" tests/` を実行してください。
並列実行には GNU parallel が必要です（`apt install parallel` / `brew install parallel`）。

### 動作確認

systemd サービスの起動テストや queue_monitor のプログレス表示確認など、
詳細な手順は [docs/testing-guide.md](docs/testing-guide.md) を参照してください。

## コーディング規約

- シェルスクリプト: インデント4スペース、変数は `"$var"` でクォート
- 関数名: 小文字 + アンダースコア (`function_name`)
- ガードパターン: `[[ -n "${__LIB_NAME_LOADED:-}" ]] && return; __LIB_NAME_LOADED=1`
- コミットメッセージ: Conventional Commits (`feat:`, `fix:`, `docs:` 等)

## メッセージ形式

エージェント間通信は MIME 形式を使用します。詳細は [docs/protocol.md](docs/protocol.md) を参照してください。

## ドキュメント規約

- `docs/` 配下にドキュメントを作成する際は、日本語版と英語版の両方を用意すること
- ファイル命名規則:
  - 日本語版: `docs/<name>.md`
  - 英語版: `docs/<name>_en.md`
- 例: `docs/startup-parallelization.md` / `docs/startup-parallelization_en.md`

## セルフチェックルール

コード変更後は**最低3回**のセルフチェックを行うこと:

1. **1回目**: 変更対象の直接的な修正漏れを `grep` で検索（狭いパターン）
2. **2回目**: 関連する間接的な参照を広いパターンで検索（instructions/, config/, tests/ 含む）
3. **3回目**: さらに広いパターン（単語単位）で全体を横断検索し、見落としがないか確認

特にリネーム・削除・依存関係の変更時は、以下を必ず確認すること:
- `scripts/` 内の実行コード
- `instructions/` 内のエージェント向けプロンプト
- `config/` 内の設定ファイル・テンプレート
- `tests/` 内のテストコード
- `install.sh` や `cli_provider.sh` の依存関係リスト

## バージョンアップ・リリースフロー

### バージョンバンプ手順

1. `scripts/lib/core.sh` の `VERSION="x.y.z"` を更新
2. インストール先に同期: `cp scripts/lib/core.sh ~/.local/share/ignite/scripts/lib/core.sh`
3. コミット: `git commit -m "chore: bump version to vX.Y.Z"`
4. main に push

### リリース作成の注意事項

**リリースアーカイブ（tar.gz）は CI workflow が自動生成する。`gh release create` で手動リリースを先に作ると workflow がアセットをアップロードできなくなる。**

正しい手順:
1. バージョンバンプコミットを main に push
2. **タグのみ作成して push**: `git tag v0.6.2 && git push origin v0.6.2`
3. `.github/workflows/release.yml` がタグ push を検知し、自動で:
   - `scripts/build.sh` でアーカイブをビルド
   - `scripts/smoke_test.sh --ci` でスモークテスト
   - `softprops/action-gh-release` でリリース作成 + アセットアップロード
4. workflow 完了後、`gh release edit v0.6.2 --notes-file notes.md` でリリースノートを上書き

**やってはいけないこと:**
- `gh release create` でリリースを先に作成する（workflow の `softprops/action-gh-release` が既存リリースへのアセット追加で認証エラーになる）

**タグ打ち直し時の注意:**
- タグを削除→再作成した場合、CI の `softprops/action-gh-release` がリリースを再作成し、**リリースノートが自動生成ノートで上書きされる**
- タグ打ち直し時は必ず workflow 完了後に `gh release edit` でリリースノートを再適用すること

### ワークスペースへの反映

`install.sh --upgrade` → `ignite init -w /path/to/workspace` の順で、最新のインストラクション・設定がワークスペースにコピーされる。
- `install.sh --upgrade`: ソース → `~/.local/share/ignite/` にコピー
- `ignite init`: `~/.local/share/ignite/instructions/` → `.ignite/instructions/` にコピー（上書き）
- `ignite start`（`setup_workspace_config`）: `.ignite/instructions/` が**存在しない場合のみ**コピー（既存は上書きしない）

## 重要な注意事項

- CLI プロバイダーは **OpenCode ヘッドレスモード** 専用です（`opencode serve` で HTTP API 経由で管理）
- 設定ファイルの読み込みは `scripts/lib/yaml_utils.sh` の関数を使用してください
- セキュリティ: ユーザー入力は必ず `sanitize_*` 関数でサニタイズすること
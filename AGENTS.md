# AGENTS.md

IGNITE プロジェクトの AI エージェント向けガイドです。

## プロジェクト概要

IGNITE は bash ベースのマルチエージェントオーケストレーションシステムです。tmux + AI CLI (OpenCode/Claude) + systemd で構成されます。

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

- **必須**: tmux, opencode (または claude), gh
- **任意**: yq (v4.30+), sqlite3, python3

### テスト

```bash
# 全テスト実行
bats tests/

# 特定テストファイル
bats tests/test_cmd_start_init.bats
```

PR を出す前に必ず `bats tests/` を実行してください。

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

## 重要な注意事項

- デフォルト CLI プロバイダーは **OpenCode** です（`config/system.yaml` の `cli.provider`）
- 設定ファイルの読み込みは `scripts/lib/yaml_utils.sh` の関数を使用してください
- セキュリティ: ユーザー入力は必ず `sanitize_*` 関数でサニタイズすること

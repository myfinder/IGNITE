# 起動フロー依存グラフと並列化範囲

## 目的

起動フローの依存関係と排他資源を整理し、並列化可能範囲と不可理由を明文化する。

## 依存グラフ（概要）

```
setup_workspace
  -> setup_workspace_config
    -> cli_load_config
      -> validate configs (optional)
        -> init runtime dirs/db/dashboard
          -> agent server start
            -> leader start
              -> sub-leaders start (optional)
                -> ignitians start (optional)
                  -> runtime.yaml / sessions.yaml
                    -> watcher start (optional)
                      -> queue_monitor start
```

## 排他資源（競合ポイント）

- **セッション管理**
  - エージェントサーバーの起動・停止は逐次化が必要
- **runtime ディレクトリ配下**
  - `dashboard.md`, `runtime.yaml`, `state/` などは同時書き込み競合の可能性
- **ログファイル**
  - `logs/*.log` への同時追記は順序依存があるため並列化不可
- **一時ファイル**
  - `tmp/` 配下を共有する場合は命名衝突防止が必要

## 並列化可能範囲

- **Sub-Leaders/IGNITIANS の起動**
  - opencode serve の起動・ヘルスチェック待機・セッション作成は並列化可能

- **Watcher/queue_monitor 起動**
  - エージェントプロセス確立後なら並列起動可能
  - ただしログファイルの初期ヘッダ追記は排他制御が必要

- **コスト追跡/セッション情報の記録**
  - `runtime.yaml`/`sessions.yaml` の生成完了後は並列化可能

## 並列化不可理由・例外条件

- **setup_workspace_config の前**
  - config/ runtime/ instructions の切替前に並列化すると設定が混線する

- **エージェントサーバー起動の前後**
  - エージェントサーバーの起動は単一操作として直列化が必要

- **dashboard.md 初期化**
  - 初期生成は単発で完了させる必要があり、並列化不可

- **例外条件**
  - `--dry-run` 時はエージェントサーバー/Watcher/Monitor を起動しないため並列化不要
  - `agent_mode=leader` の場合は Sub-Leaders/IGNITIANS が対象外

## コメント（運用指針）

- 並列化は **エージェントサーバー起動と共有ファイル初期化の後** に限定する
- ログ/ダッシュボード/状態ファイルの更新は **単一書き込み経路** に集約する

# Issue 269: 認証フローと優先順位仕様

## 優先順位（固定）
1. GitHub App（Installation Token）
2. PAT（`IGNITE_GITHUB_TOKEN`）
3. どちらも無い場合はエラー

## 認証フロー

### GitHub App
- `github-app.yaml` を読み込み、Installation Token を取得
- 取得したトークンを短時間キャッシュ（TTL: 55分）
- 期限切れや認証エラー時はキャッシュを無効化し再取得

### PAT
- `IGNITE_GITHUB_TOKEN` を環境変数で受け取る
- 保存しない（ディスクやログに出力しない）
- GitHub App が取得できない場合のフォールバック

## 失敗時のフォールバックとユーザー向けエラー
- GitHub App 取得失敗 → PAT があれば利用
- PAT も未設定 → エラー表示
  - 設定案内: `github-app.yaml` の作成、もしくは `IGNITE_GITHUB_TOKEN` の設定

## 最小権限・保存・失効/更新

### 最小権限
- GitHub App: 必要リポジトリに限定してインストール
- PAT: fine-grained を優先し、必要なスコープ/リポジトリに限定

### 保存方針
- PAT は永続化しない
- GitHub App の Private Key は `config/` 配下に限定して保管（権限 600）
- Installation Token はメモリ内のみで保持

### 失効/更新
- 露出疑い時は即時失効・再発行
- 定期ローテーション（90日以内を推奨）

## JWT/Installation Token キャッシュと rate limit
- Installation Token は TTL 55分でキャッシュ
- 認証エラー時にキャッシュを破棄して再取得
- API rate limit を考慮し、再取得はリトライ間隔付きで実施

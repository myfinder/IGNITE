# Issue 269: gh依存の影響範囲リスト

## 変更必須

### CLI / API 依存
- GitHub API 呼び出し（gh api）
  - 監視・トリガー取得: `/scripts/utils/github_watcher.sh:247-248,458-599,765-770`
  - Issue/PR 参照: `/scripts/utils/create_pr.sh:92`
  - Issue/PR 参照: `/scripts/lib/cmd_work_on.sh:73,100`
  - コメント投稿/重複チェック: `/scripts/utils/comment_on_issue.sh:173-231`

- PR作成（gh pr create）
  - `/scripts/utils/create_pr.sh:219-224`

- Repo 情報取得（gh repo view）
  - `/scripts/utils/create_pr.sh:315`
  - `/scripts/utils/comment_on_issue.sh:306`
  - `/scripts/lib/cmd_work_on.sh:73`

- Repo clone（gh repo clone）
  - `/scripts/utils/setup_repo.sh:221-223`

### 認証依存
- GitHub App トークン生成（gh / gh-token 拡張）
  - `gh` CLI の存在チェック: `/scripts/utils/get_github_app_token.sh:56-58`
  - `gh-token` 拡張チェック: `/scripts/utils/get_github_app_token.sh:63-66`
  - JWT 生成: `/scripts/utils/get_github_app_token.sh:135-138`
  - Installation ID 取得: `/scripts/utils/get_github_app_token.sh:149-151`
  - App Token 生成: `/scripts/utils/get_github_app_token.sh:201-202`

### 共通ヘルパー
- gh API ラッパー `_gh_api`
  - `/scripts/utils/github_helpers.sh:416-431`

### 依存関係
- gh CLI / gh-token 拡張が必須
  - `/scripts/utils/get_github_app_token.sh:56-66`
  - `/scripts/install.sh:110-113,139-140`

## 変更任意

### 設定/依存に関する案内（docs/instructions）
- gh CLI 前提の説明が多数あるため、実装置換に合わせて更新が必要
  - `/docs/github-watcher.md:34,47,370-377,413`
  - `/docs/github-watcher_en.md:34,47,370-377,413`
  - `/docs/github-app-setup.md:29-39,156-176,232-248,265-306`
  - `/docs/github-app-setup_en.md:29-39`
  - `/docs/github-app-installation_en.md:13-23`
  - `/docs/windows-setup.md:80-95,134`
  - `/docs/windows-setup_en.md:80-95,134`

### 手順/ポリシー文書
- ghコマンド利用を前提にした運用/注意点の記述
  - `/instructions/leader.md:496,563,638-699,862`
  - `/instructions/innovator.md:446`
  - `/instructions/evaluator.md:716`
  - `/instructions/architect.md:467`
  - `/instructions/ignitian.md:510,915`

## 非対象

### コメントや補足のみ（直接的な実装依存ではない）
- gh CLI 認証失効に関するコメント
  - `/scripts/lib/cmd_start.sh:316`

## 影響範囲の観点整理

- 機能: GitHub API 取得、PR作成、repo clone、Issue/PRコメント投稿
- CLI: gh api / gh pr create / gh repo view / gh repo clone
- 認証: gh-token 拡張での GitHub App トークン生成
- 設定: gh CLI 必須のドキュメント・運用指針
- 依存関係: gh CLI / gh-token 拡張の必須指定（install.sh）

#!/bin/bash
set -e
set -u

# エラートラップ
trap 'echo "❌ エラーが発生しました (line $LINENO)"' ERR

# カラー定義
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# スクリプトのディレクトリを取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo -e "${BLUE}=== IGNITE システム起動 ===${NC}"
echo ""

# プロジェクトルートに移動
cd "$PROJECT_ROOT"

# 既存のセッションチェック
if tmux has-session -t ignite-session 2>/dev/null; then
    echo -e "${YELLOW}⚠ 既存のignite-sessionが見つかりました${NC}"
    read -p "既存のセッションを終了して再起動しますか? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        tmux kill-session -t ignite-session
        echo -e "${GREEN}✓ 既存セッションを終了しました${NC}"
    else
        echo -e "${YELLOW}既存セッションにアタッチします${NC}"
        tmux attach -t ignite-session
        exit 0
    fi
fi

# workspaceの初期化
echo -e "${BLUE}workspaceを初期化中...${NC}"
mkdir -p workspace/queue/{leader,strategist,architect,evaluator,coordinator,innovator,ignitians}
mkdir -p workspace/reports
mkdir -p workspace/context
mkdir -p workspace/logs

# .claude/prompts/ ディレクトリの準備
echo -e "${BLUE}.claude/prompts/ にシステムプロンプトをコピー中...${NC}"
mkdir -p .claude/prompts
cp instructions/*.md .claude/prompts/

# 初期ダッシュボードの作成
echo -e "${BLUE}初期ダッシュボードを作成中...${NC}"
cat > workspace/dashboard.md <<EOF
# IGNITE Dashboard

更新日時: $(date '+%Y-%m-%d %H:%M:%S')

## システム状態
⏳ Leader (伊羽ユイ): 起動中...

## 現在のタスク
タスクなし - システム起動中

## 最新ログ
[$(date '+%H:%M:%S')] システム起動を開始しました
EOF

echo -e "${GREEN}✓ workspace初期化完了${NC}"
echo ""

# tmuxセッション作成
echo -e "${BLUE}tmuxセッションを作成中...${NC}"
tmux new-session -d -s ignite-session -n ignite -x 200 -y 50

# Leader ペイン (pane 0)
echo -e "${BLUE}Leader (伊羽ユイ) を起動中...${NC}"
tmux send-keys -t ignite-session:0.0 \
    "cd '$PROJECT_ROOT' && claude-code --dangerously-skip-permissions" Enter

# 起動待機
echo -e "${YELLOW}Leaderの起動を待機中... (3秒)${NC}"
sleep 3

# Leaderにプロンプトをロード
echo -e "${BLUE}Leaderシステムプロンプトをロード中...${NC}"
tmux send-keys -t ignite-session:0.0 \
    "/prompt leader" Enter

# さらに待機（プロンプトロード時間）
sleep 2

# 初期メッセージの送信
echo -e "${BLUE}Leaderに初期化メッセージを送信中...${NC}"
cat > workspace/queue/leader/system_init_$(date +%s).yaml <<EOF
type: system_init
from: system
to: leader
timestamp: "$(date -Iseconds)"
priority: high
payload:
  message: "システムが起動しました。初期化を完了してください。"
  action: "initialize_dashboard"
status: pending
EOF

# Leaderに新しいメッセージがあることを通知
tmux send-keys -t ignite-session:0.0 \
    "echo '📨 新しいメッセージがあります: workspace/queue/leader/'" Enter

echo ""
echo -e "${GREEN}✓ IGNITE Leader が起動しました${NC}"
echo ""
echo -e "${BLUE}=== 起動完了 ===${NC}"
echo ""
echo "次のステップ:"
echo -e "  1. tmuxセッションに接続: ${YELLOW}tmux attach -t ignite-session${NC}"
echo -e "  2. ダッシュボード確認: ${YELLOW}cat workspace/dashboard.md${NC}"
echo -e "  3. タスク投入: ${YELLOW}bash scripts/ignite_plan.sh \"目標\"${NC}"
echo ""
echo "tmuxセッション操作:"
echo -e "  - デタッチ: ${YELLOW}Ctrl+b d${NC}"
echo -e "  - セッション終了: ${YELLOW}bash scripts/ignite_stop.sh${NC}"
echo ""

# オプション: 自動アタッチ
read -p "tmuxセッションにアタッチしますか? (Y/n): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    tmux attach -t ignite-session
fi

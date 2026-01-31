#!/bin/bash
set -e
set -u

# カラー定義
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# スクリプトのディレクトリを取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# プロジェクトルートに移動
cd "$PROJECT_ROOT"

# 引数チェック
if [ $# -eq 0 ]; then
    echo -e "${RED}❌ エラー: 目標を指定してください${NC}"
    echo ""
    echo "使用方法:"
    echo "  $0 \"目標の内容\""
    echo ""
    echo "例:"
    echo "  $0 \"READMEファイルを作成する\""
    echo "  $0 \"シンプルなCLIツールを実装する\""
    exit 1
fi

GOAL="$1"
CONTEXT="${2:-}"

# セッションの存在確認
if ! tmux has-session -t ignite-session 2>/dev/null; then
    echo -e "${RED}❌ ignite-session が見つかりません${NC}"
    echo -e "${YELLOW}先に起動してください: bash scripts/ignite_start.sh${NC}"
    exit 1
fi

echo -e "${BLUE}=== IGNITE タスク投入 ===${NC}"
echo ""
echo -e "${BLUE}目標:${NC} $GOAL"
if [ -n "$CONTEXT" ]; then
    echo -e "${BLUE}コンテキスト:${NC} $CONTEXT"
fi
echo ""

# タイムスタンプとメッセージID生成
TIMESTAMP=$(date -Iseconds)
MESSAGE_ID=$(date +%s)

# Leaderへメッセージ送信
MESSAGE_FILE="workspace/queue/leader/user_goal_${MESSAGE_ID}.yaml"

if [ -n "$CONTEXT" ]; then
    cat > "$MESSAGE_FILE" <<EOF
type: user_goal
from: user
to: leader
timestamp: "${TIMESTAMP}"
priority: high
payload:
  goal: "${GOAL}"
  context: "${CONTEXT}"
status: pending
EOF
else
    cat > "$MESSAGE_FILE" <<EOF
type: user_goal
from: user
to: leader
timestamp: "${TIMESTAMP}"
priority: high
payload:
  goal: "${GOAL}"
status: pending
EOF
fi

echo -e "${GREEN}✓ メッセージを作成しました: $MESSAGE_FILE${NC}"

# Leaderに通知（tmux send-keys）
tmux send-keys -t ignite-session:0.0 \
    "echo ''" Enter

tmux send-keys -t ignite-session:0.0 \
    "echo '📨 ════════════════════════════════════════'" Enter

tmux send-keys -t ignite-session:0.0 \
    "echo '📨 新しいタスクが投入されました！'" Enter

tmux send-keys -t ignite-session:0.0 \
    "echo '📨 目標: ${GOAL}'" Enter

tmux send-keys -t ignite-session:0.0 \
    "echo '📨 メッセージファイル: ${MESSAGE_FILE}'" Enter

tmux send-keys -t ignite-session:0.0 \
    "echo '📨 ════════════════════════════════════════'" Enter

tmux send-keys -t ignite-session:0.0 \
    "echo ''" Enter

echo ""
echo -e "${GREEN}✓ タスク '${GOAL}' を投入しました${NC}"
echo ""
echo "次のステップ:"
echo -e "  1. ダッシュボード確認: ${YELLOW}cat workspace/dashboard.md${NC}"
echo -e "  2. ステータス確認: ${YELLOW}bash scripts/ignite_status.sh${NC}"
echo -e "  3. tmuxセッション表示: ${YELLOW}tmux attach -t ignite-session${NC}"

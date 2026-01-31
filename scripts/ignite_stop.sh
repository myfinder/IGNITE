#!/bin/bash
set -e
set -u

# カラー定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}=== IGNITE システム停止 ===${NC}"
echo ""

# セッションの存在確認
if ! tmux has-session -t ignite-session 2>/dev/null; then
    echo -e "${RED}❌ ignite-session が見つかりません${NC}"
    exit 1
fi

# 確認
read -p "IGNITE システムを停止しますか? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}キャンセルしました${NC}"
    exit 0
fi

# セッション終了
echo -e "${YELLOW}tmuxセッションを終了中...${NC}"
tmux kill-session -t ignite-session

echo -e "${GREEN}✓ IGNITE システムを停止しました${NC}"

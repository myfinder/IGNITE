#!/bin/bash

# カラー定義
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# スクリプトのディレクトリを取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"

echo -e "${BLUE}=== IGNITE システム状態 ===${NC}"
echo ""

# tmuxセッション確認
if tmux has-session -t ignite-session 2>/dev/null; then
    echo -e "${GREEN}✓ tmuxセッション: 実行中${NC}"

    # ペイン数確認
    PANE_COUNT=$(tmux list-panes -t ignite-session | wc -l)
    echo -e "${BLUE}  ペイン数: ${PANE_COUNT}${NC}"
else
    echo -e "${RED}❌ tmuxセッション: 停止${NC}"
    exit 1
fi

echo ""

# ダッシュボード表示
if [ -f "workspace/dashboard.md" ]; then
    echo -e "${BLUE}=== ダッシュボード ===${NC}"
    echo ""
    cat workspace/dashboard.md
    echo ""
else
    echo -e "${YELLOW}⚠ ダッシュボードが見つかりません${NC}"
fi

# キュー状態
echo -e "${BLUE}=== キュー状態 ===${NC}"
echo ""

for queue_dir in workspace/queue/*; do
    if [ -d "$queue_dir" ]; then
        queue_name=$(basename "$queue_dir")
        message_count=$(find "$queue_dir" -name "*.yaml" -type f 2>/dev/null | wc -l)

        if [ "$message_count" -gt 0 ]; then
            echo -e "${YELLOW}  $queue_name: $message_count メッセージ${NC}"
        else
            echo -e "${GREEN}  $queue_name: 0 メッセージ${NC}"
        fi
    fi
done

echo ""

# レポート状態
if [ -d "workspace/reports" ]; then
    REPORT_COUNT=$(find workspace/reports -name "*.yaml" -type f 2>/dev/null | wc -l)
    echo -e "${BLUE}=== レポート ===${NC}"
    echo -e "  完了レポート: ${REPORT_COUNT} 件"
    echo ""
fi

# 最新ログ
echo -e "${BLUE}=== 最新ログ (直近5件) ===${NC}"
echo ""

if [ -d "workspace/logs" ] && [ "$(ls -A workspace/logs 2>/dev/null)" ]; then
    for log_file in workspace/logs/*.log; do
        if [ -f "$log_file" ]; then
            echo -e "${BLUE}$(basename "$log_file"):${NC}"
            tail -n 5 "$log_file" 2>/dev/null | sed 's/^/  /'
            echo ""
        fi
    done
else
    echo -e "${YELLOW}  ログファイルなし${NC}"
    echo ""
fi

echo -e "${BLUE}=== コマンド ===${NC}"
echo -e "  ダッシュボード監視: ${YELLOW}watch -n 5 cat workspace/dashboard.md${NC}"
echo -e "  tmuxアタッチ: ${YELLOW}tmux attach -t ignite-session${NC}"
echo -e "  システム停止: ${YELLOW}bash scripts/ignite_stop.sh${NC}"

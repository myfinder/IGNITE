#!/bin/bash
# ユーティリティ: メッセージ送信

set -e
set -u

# 使用方法チェック
if [ $# -lt 4 ]; then
    echo "使用方法: $0 <type> <from> <to> <payload_yaml_or_string>"
    echo ""
    echo "例:"
    echo "  $0 test_message user leader 'message: \"Hello\"'"
    echo "  $0 task_assignment coordinator ignitian_0 'task_id: task_001"
    echo "    title: READMEを作成'"
    exit 1
fi

TYPE="$1"
FROM="$2"
TO="$3"
PAYLOAD="$4"
PRIORITY="${5:-normal}"

# タイムスタンプ生成
TIMESTAMP=$(date -Iseconds)
MESSAGE_ID=$(date +%s)

# 宛先ディレクトリ
QUEUE_DIR="${WORKSPACE_DIR:-workspace}/queue/${TO}"

if [ ! -d "$QUEUE_DIR" ]; then
    echo "❌ エラー: $QUEUE_DIR が存在しません"
    exit 1
fi

# メッセージファイル作成
MESSAGE_FILE="${QUEUE_DIR}/${TYPE}_${MESSAGE_ID}.yaml"

cat > "$MESSAGE_FILE" <<EOF
type: ${TYPE}
from: ${FROM}
to: ${TO}
timestamp: "${TIMESTAMP}"
priority: ${PRIORITY}
payload:
  ${PAYLOAD}
status: queued
EOF

echo "✓ メッセージを送信しました: $MESSAGE_FILE"

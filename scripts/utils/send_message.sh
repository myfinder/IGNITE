#!/bin/bash
# ユーティリティ: メッセージ送信（MIME形式）
# ignite_mime.py build の薄いラッパー

set -e
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IGNITE_MIME="${SCRIPT_DIR}/../lib/ignite_mime.py"

# =============================================================================
# ヘルプ
# =============================================================================
show_help() {
    cat << 'HELP'
使用方法:
  send_message.sh <type> <from> <to> [options]

位置引数（必須）:
  type    メッセージタイプ（例: task_assignment, task_completed）
  from    送信元エージェント名
  to      送信先エージェント名

オプション:
  --body <string>       ペイロード（インライン文字列）
  --body-file <path>    ペイロード（ファイルパス、"-" でstdin）
  --priority <level>    優先度（デフォルト: normal）
  --repo <owner/name>   リポジトリ名
  --issue <number>      Issue番号
  --thread-id <id>      スレッドID
  --in-reply-to <msgid> 返信先Message-ID
  -h, --help            このヘルプを表示

後方互換（位置引数のみ）:
  send_message.sh <type> <from> <to> <payload> [priority]

例:
  # 新インターフェース（推奨）
  send_message.sh task_completed ignitian_1 coordinator \
    --body-file payload.yaml --priority high --repo myfinder/IGNITE --issue 246

  # 新インターフェース（stdin経由）
  echo "task_id: task_001" | send_message.sh task_completed ignitian_1 coordinator --body-file -

  # 旧インターフェース（後方互換）
  send_message.sh task_completed ignitian_1 coordinator 'task_id: "task_001"' high
HELP
}

# =============================================================================
# 引数パース
# =============================================================================

if [[ $# -lt 3 ]]; then
    show_help
    exit 1
fi

# 位置引数（必須）
TYPE="$1"
FROM="$2"
TO="$3"
shift 3

# デフォルト値
BODY=""
BODY_FILE=""
PRIORITY="normal"
REPO=""
ISSUE=""
THREAD_ID=""
IN_REPLY_TO=""

# 残りの引数をパース
if [[ $# -gt 0 ]]; then
    # オプション引数か位置引数かを判定
    if [[ "$1" == --* ]] || [[ "$1" == "-h" ]]; then
        # 新インターフェース: オプション引数
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --body)
                    BODY="$2"
                    echo "警告: --body はエスケープ問題が発生しやすいため --body-file の使用を推奨します" >&2
                    shift 2
                    ;;
                --body-file)
                    BODY_FILE="$2"
                    shift 2
                    ;;
                --priority)
                    PRIORITY="$2"
                    shift 2
                    ;;
                --repo)
                    REPO="$2"
                    shift 2
                    ;;
                --issue)
                    ISSUE="$2"
                    shift 2
                    ;;
                --thread-id)
                    THREAD_ID="$2"
                    shift 2
                    ;;
                --in-reply-to)
                    IN_REPLY_TO="$2"
                    shift 2
                    ;;
                -h|--help)
                    show_help
                    exit 0
                    ;;
                *)
                    echo "❌ エラー: 不明なオプション: $1" >&2
                    show_help
                    exit 1
                    ;;
            esac
        done
    else
        # 旧インターフェース: 位置引数（後方互換）
        BODY="$1"
        PRIORITY="${2:-normal}"
    fi
fi

# =============================================================================
# 宛先ディレクトリ解決
# =============================================================================
QUEUE_DIR="${WORKSPACE_DIR:-workspace}/queue/${TO}"

if [[ ! -d "$QUEUE_DIR" ]]; then
    echo "❌ エラー: $QUEUE_DIR が存在しません" >&2
    exit 1
fi

# =============================================================================
# MIME メッセージ生成（ignite_mime.py build に委譲）
# =============================================================================
MESSAGE_ID=$(date +%s%6N)
MESSAGE_FILE="${QUEUE_DIR}/${TYPE}_${MESSAGE_ID}.mime"

# ignite_mime.py build の引数を構築
MIME_ARGS=(
    --from "$FROM"
    --to "$TO"
    --type "$TYPE"
    --priority "$PRIORITY"
    -o "$MESSAGE_FILE"
)

[[ -n "$REPO" ]] && MIME_ARGS+=(--repo "$REPO")
[[ -n "$ISSUE" ]] && MIME_ARGS+=(--issue "$ISSUE")
[[ -n "$THREAD_ID" ]] && MIME_ARGS+=(--thread-id "$THREAD_ID")
[[ -n "$IN_REPLY_TO" ]] && MIME_ARGS+=(--in-reply-to "$IN_REPLY_TO")

# ペイロードの渡し方を決定
if [[ -n "$BODY_FILE" ]]; then
    # --body-file 経由（推奨パス: エスケープ問題を根本回避）
    MIME_ARGS+=(--body-file "$BODY_FILE")
elif [[ -n "$BODY" ]]; then
    # --body インライン（旧互換）: 一時ファイル経由で安全に渡す
    TMPFILE=$(mktemp)
    trap 'rm -f "$TMPFILE"' EXIT
    printf '%s' "$BODY" > "$TMPFILE"
    MIME_ARGS+=(--body-file "$TMPFILE")
fi

# ignite_mime.py build 実行
if ! python3 "$IGNITE_MIME" build "${MIME_ARGS[@]}"; then
    echo "❌ エラー: MIMEメッセージの生成に失敗しました" >&2
    exit 1
fi

echo "✓ メッセージを送信しました: $MESSAGE_FILE"

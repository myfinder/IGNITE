#!/usr/bin/env bash
# dev-setup.sh - IGNITE 開発環境セットアップスクリプト
# リポジトリチェックアウト直後に実行して開発環境を確認・準備する
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# カラー定義
if [[ -n "${NO_COLOR:-}" ]] || ! [[ -t 1 ]] || [[ "${TERM:-}" == "dumb" ]]; then
    GREEN='' RED='' YELLOW='' CYAN='' BOLD='' NC=''
else
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
fi

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }

errors=0

echo -e "${BOLD}${CYAN}=== IGNITE 開発環境セットアップ ===${NC}"
echo ""

# =========================================================================
# 必須ツールチェック
# =========================================================================
echo -e "${BOLD}必須ツール:${NC}"

required_tools=(bash curl jq sqlite3 bats git parallel)
for tool in "${required_tools[@]}"; do
    if command -v "$tool" &>/dev/null; then
        version=$("$tool" --version 2>&1 | head -1 || true)
        ok "$tool ($version)"
    else
        fail "$tool が見つかりません"
        errors=$((errors + 1))
    fi
done

echo ""

# =========================================================================
# 任意ツールチェック
# =========================================================================
echo -e "${BOLD}任意ツール:${NC}"

optional_tools=(yq python3 podman shellcheck)
for tool in "${optional_tools[@]}"; do
    if command -v "$tool" &>/dev/null; then
        version=$("$tool" --version 2>&1 | head -1 || true)
        ok "$tool ($version)"
    else
        warn "$tool が見つかりません（なくても動作します）"
    fi
done

echo ""

# =========================================================================
# 実行時ツールチェック（CLI プロバイダ）
# =========================================================================
echo -e "${BOLD}CLI プロバイダ（実行時に1つ必要）:${NC}"

cli_found=0
for tool in opencode claude codex; do
    if command -v "$tool" &>/dev/null; then
        version=$("$tool" --version 2>&1 | head -1 || true)
        ok "$tool ($version)"
        cli_found=1
    else
        warn "$tool が見つかりません"
    fi
done
if [[ $cli_found -eq 0 ]]; then
    warn "CLI プロバイダが見つかりません（ignite start の実行には1つ必要）"
fi

echo ""

# =========================================================================
# 必須ツール不足時はエラー終了
# =========================================================================
if [[ $errors -gt 0 ]]; then
    echo -e "${RED}必須ツールが ${errors} 個不足しています。インストールしてから再実行してください。${NC}"
    exit 1
fi

# =========================================================================
# 既存インストールの検出・警告
# =========================================================================
echo -e "${BOLD}インストール状態:${NC}"

if [[ -f "${HOME}/.local/bin/ignite" ]]; then
    warn "既存インストールを検出: ${HOME}/.local/bin/ignite"
    warn "PATH の優先順位により、リポジトリの ./scripts/ignite ではなく"
    warn "インストール版が実行される可能性があります。"
    warn "開発中は ./scripts/ignite または make コマンドを使用してください。"
else
    ok "既存インストールなし（PATH 競合の心配なし）"
fi

echo ""

# =========================================================================
# リポジトリ直接実行確認
# =========================================================================
echo -e "${BOLD}リポジトリ直接実行:${NC}"

if [[ -x "${PROJECT_ROOT}/scripts/ignite" ]]; then
    ok "./scripts/ignite は実行可能です"
else
    warn "./scripts/ignite に実行権限がありません。付与します..."
    chmod +x "${PROJECT_ROOT}/scripts/ignite"
    ok "実行権限を付与しました"
fi

echo ""

# =========================================================================
# 使い方ガイド
# =========================================================================
echo -e "${BOLD}${CYAN}=== セットアップ完了 ===${NC}"
echo ""
echo "利用可能な make ターゲット:"
echo "  make help    ヘルプ表示"
echo "  make dev     開発環境セットアップ（このスクリプト）"
echo "  make test    全テスト実行（bats）"
echo "  make lint    shellcheck による静的解析"
echo "  make start   テストワークスペースで起動"
echo "  make stop    テストワークスペース停止"
echo "  make clean   テストワークスペース削除"
echo ""
echo "直接実行:"
echo "  ./scripts/ignite --help"
echo ""

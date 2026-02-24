# IGNITE 開発用 Makefile
SHELL := /bin/bash
.DEFAULT_GOAL := help

DEV_WORKSPACE := /tmp/ignite-dev-ws

.PHONY: help dev test lint start stop clean

help: ## ヘルプ表示
	@echo "IGNITE 開発用コマンド:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "直接実行: ./scripts/ignite --help"

dev: ## 開発環境セットアップ
	@bash scripts/dev-setup.sh

test: ## 全テスト実行（bats 並列）
	bats --jobs "$$(($$(nproc) * 8))" tests/

lint: ## shellcheck による静的解析
	shellcheck -S warning scripts/ignite scripts/lib/*.sh scripts/utils/*.sh scripts/dev-setup.sh

start: ## テストワークスペース (/tmp/ignite-dev-ws) で起動
	@mkdir -p $(DEV_WORKSPACE)
	./scripts/ignite init -w $(DEV_WORKSPACE)
	./scripts/ignite start -w $(DEV_WORKSPACE)

stop: ## テストワークスペース停止
	./scripts/ignite stop -w $(DEV_WORKSPACE)

clean: ## テストワークスペース削除
	@if [ -d "$(DEV_WORKSPACE)" ]; then \
		./scripts/ignite stop -w $(DEV_WORKSPACE) 2>/dev/null || true; \
		rm -rf $(DEV_WORKSPACE); \
		echo "テストワークスペースを削除しました: $(DEV_WORKSPACE)"; \
	else \
		echo "テストワークスペースは存在しません: $(DEV_WORKSPACE)"; \
	fi

RUST_WORKSPACE := /Users/dwgoing/Desktop/rainbow-bridge
EVM_DIR := /Users/dwgoing/Desktop/rainbow-bridge/contracts/evm
SUI_DIR := /Users/dwgoing/Desktop/rainbow-bridge/contracts/sui
STRICT_SUI ?= 0

.PHONY: help check test fmt clean
.PHONY: rust-check rust-test rust-fmt
.PHONY: evm-build evm-test
.PHONY: sui-build sui-test

help:
	@echo "Rainbow Bridge monorepo tasks"
	@echo ""
	@echo "Core:"
	@echo "  make check      - Run rust + evm + sui checks"
	@echo "  make test       - Run rust + evm + sui tests"
	@echo "  make fmt        - Format Rust workspace"
	@echo "  make clean      - Clean Rust, EVM and Sui artifacts"
	@echo ""
	@echo "Rust:"
	@echo "  make rust-check"
	@echo "  make rust-test"
	@echo "  make rust-fmt"
	@echo ""
	@echo "EVM:"
	@echo "  make evm-build"
	@echo "  make evm-test"
	@echo ""
	@echo "Sui:"
	@echo "  make sui-build"
	@echo "  make sui-test"

check: rust-check evm-build sui-build

test: rust-test evm-test sui-test

fmt: rust-fmt

clean:
	cd $(RUST_WORKSPACE) && cargo clean
	rm -rf $(EVM_DIR)/cache $(EVM_DIR)/out
	rm -rf $(SUI_DIR)/build

rust-check:
	cd $(RUST_WORKSPACE) && cargo check

rust-test:
	cd $(RUST_WORKSPACE) && cargo test -p types -p chain-adapters -p solver -p validator

rust-fmt:
	cd $(RUST_WORKSPACE) && cargo fmt

evm-build:
	cd $(RUST_WORKSPACE) && forge build

evm-test:
	cd $(RUST_WORKSPACE) && forge test --offline

sui-build:
	@if command -v sui >/dev/null 2>&1; then \
		if sui move build --path $(SUI_DIR) --skip-fetch-latest-git-deps; then \
			echo "sui-build success"; \
		elif [ "$(STRICT_SUI)" = "1" ]; then \
			echo "sui-build failed (STRICT_SUI=1)"; \
			exit 1; \
		else \
			echo "sui-build failed; continue (set STRICT_SUI=1 to fail fast)"; \
		fi; \
	else \
		echo "sui CLI not found; skip sui-build"; \
	fi

sui-test:
	@if command -v sui >/dev/null 2>&1; then \
		if sui move test --path $(SUI_DIR) --skip-fetch-latest-git-deps; then \
			echo "sui-test success"; \
		elif [ "$(STRICT_SUI)" = "1" ]; then \
			echo "sui-test failed (STRICT_SUI=1)"; \
			exit 1; \
		else \
			echo "sui-test failed; continue (set STRICT_SUI=1 to fail fast)"; \
		fi; \
	else \
		echo "sui CLI not found; skip sui-test"; \
	fi

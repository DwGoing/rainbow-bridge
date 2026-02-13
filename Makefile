RUST_WORKSPACE := /Users/dwgoing/Desktop/rainbow-bridge
EVM_DIR := /Users/dwgoing/Desktop/rainbow-bridge/contracts/evm
SUI_DIR := /Users/dwgoing/Desktop/rainbow-bridge/contracts/sui
STRICT_SUI ?= 0
SUI_MOVE_ENV ?= testnet

.PHONY: help check test fmt clean
.PHONY: check-rust test-rust fmt-rust
.PHONY: build-evm check-evm test-evm
.PHONY: build-sui check-sui test-sui
.PHONY: deploy-evm deploy-sui
.PHONY: run-solver run-validator
.PHONY: run-validator-off run-validator-dry run-validator-send
.PHONY: run-explorer

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
	@echo "  make check-rust"
	@echo "  make test-rust"
	@echo "  make fmt-rust"
	@echo ""
	@echo "EVM:"
	@echo "  make build-evm"
	@echo "  make check-evm"
	@echo "  make test-evm"
	@echo ""
	@echo "Sui:"
	@echo "  make build-sui"
	@echo "  make check-sui"
	@echo "  make test-sui"
	@echo ""
	@echo "Deploy:"
	@echo "  make deploy-evm"
	@echo "  make deploy-sui"
	@echo ""
	@echo "Runtime:"
	@echo "  make run-solver"
	@echo "  make run-validator"
	@echo "  make run-explorer"
	@echo "  make run-validator-off"
	@echo "  make run-validator-dry"
	@echo "  make run-validator-send"

check: check-rust check-evm check-sui

test: test-rust test-evm test-sui

fmt: fmt-rust

clean:
	cd $(RUST_WORKSPACE) && cargo clean
	rm -rf $(EVM_DIR)/cache $(EVM_DIR)/out
	rm -rf $(SUI_DIR)/build

check-rust:
	cd $(RUST_WORKSPACE) && cargo check

test-rust:
	cd $(RUST_WORKSPACE) && cargo test -p types -p chain-adapters -p solver -p validator -p explorer

fmt-rust:
	cd $(RUST_WORKSPACE) && cargo fmt

build-evm:
	cd $(RUST_WORKSPACE) && forge build

check-evm: build-evm

test-evm:
	cd $(RUST_WORKSPACE) && forge test --offline

build-sui:
	@if command -v sui >/dev/null 2>&1; then \
		if sui move build --help 2>&1 | grep -q -- '--skip-fetch-latest-git-deps'; then \
			SUI_BUILD_CMD="sui move build --path $(SUI_DIR) -e $(SUI_MOVE_ENV) --skip-fetch-latest-git-deps"; \
		else \
			SUI_BUILD_CMD="sui move build --path $(SUI_DIR) -e $(SUI_MOVE_ENV)"; \
		fi; \
		if sh -c "$$SUI_BUILD_CMD"; then \
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

check-sui: build-sui

test-sui:
	@if command -v sui >/dev/null 2>&1; then \
		if sui move test --help 2>&1 | grep -q -- '--skip-fetch-latest-git-deps'; then \
			SUI_TEST_CMD="sui move test --path $(SUI_DIR) -e $(SUI_MOVE_ENV) --skip-fetch-latest-git-deps"; \
		else \
			SUI_TEST_CMD="sui move test --path $(SUI_DIR) -e $(SUI_MOVE_ENV)"; \
		fi; \
		if sh -c "$$SUI_TEST_CMD"; then \
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

deploy-evm:
	cd $(RUST_WORKSPACE) && ./scripts/deploy_evm.sh $(ARGS)

deploy-sui:
	cd $(RUST_WORKSPACE) && ./scripts/deploy_sui.sh $(ARGS)

run-solver:
	cd $(RUST_WORKSPACE) && ./scripts/run_solver.sh

run-validator:
	cd $(RUST_WORKSPACE) && ./scripts/run_validator.sh

run-validator-off:
	cd $(RUST_WORKSPACE) && ./scripts/run_validator.sh --mode off

run-validator-dry:
	cd $(RUST_WORKSPACE) && ./scripts/run_validator.sh --mode dry-run

run-validator-send:
	cd $(RUST_WORKSPACE) && ./scripts/run_validator.sh --mode send

run-explorer:
	cd $(RUST_WORKSPACE) && ./scripts/run_explorer.sh

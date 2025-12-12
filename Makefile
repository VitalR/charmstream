APP_BIN ?= $(shell charms app build)
BITCOIN_CHAIN ?= testnet4
SPELL_CREATE := spells/create-stream.yaml
SPELL_CLAIM := spells/claim-stream.yaml
BUILD_DIR := .build

.PHONY: build check-create check-claim prove-create prove-claim broadcast-create broadcast-claim

build:
	@echo "Building WASM with charms app build"
	@charms app build

check-create: $(SPELL_CREATE)
	@mkdir -p $(BUILD_DIR)
	@echo "Checking create-stream spell"
	@envsubst < $(SPELL_CREATE) | charms spell check --prev-txs="$${PREV_TXS:?provide PREV_TXS}" --app-bins=$(APP_BIN)

check-claim: $(SPELL_CLAIM)
	@mkdir -p $(BUILD_DIR)
	@echo "Checking claim-stream spell"
	@envsubst < $(SPELL_CLAIM) | charms spell check --prev-txs="$${PREV_TXS:?provide PREV_TXS}" --app-bins=$(APP_BIN)

prove-create: $(SPELL_CREATE)
	@mkdir -p $(BUILD_DIR)
	@echo "Proving create-stream spell"
	@envsubst < $(SPELL_CREATE) | charms spell prove --prev-txs="$${PREV_TXS:?provide PREV_TXS}" --app-bins=$(APP_BIN) > $(BUILD_DIR)/create.raw
	@echo "Raw tx saved to $(BUILD_DIR)/create.raw"

prove-claim: $(SPELL_CLAIM)
	@mkdir -p $(BUILD_DIR)
	@echo "Proving claim-stream spell"
	@envsubst < $(SPELL_CLAIM) | charms spell prove --prev-txs="$${PREV_TXS:?provide PREV_TXS}" --app-bins=$(APP_BIN) > $(BUILD_DIR)/claim.raw
	@echo "Raw tx saved to $(BUILD_DIR)/claim.raw"

broadcast-create:
	@bitcoin-cli -chain=$(BITCOIN_CHAIN) sendrawtransaction $$(cat $(BUILD_DIR)/create.raw)

broadcast-claim:
	@bitcoin-cli -chain=$(BITCOIN_CHAIN) sendrawtransaction $$(cat $(BUILD_DIR)/claim.raw)


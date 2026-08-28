-include .env
export

.PHONY: build test fmt oracle-info deploy-sepolia deploy-base claim-preview

build:
	forge build

test:
	forge test -vv

fmt:
	forge fmt

# Derive the OOv3 address and live bond from UMA's Finder instead of trusting a
# hardcoded address. Set FINDER for your chain from UMA's docs first.
oracle-info:
	@test -n "$(FINDER)" || (echo "set FINDER=<uma finder address for this chain>" && exit 1)
	@echo "OOv3:"
	@cast call $(FINDER) "getImplementationAddress(bytes32)(address)" \
		$$(cast --format-bytes32-string "OptimisticOracleV3") --rpc-url $(RPC_URL)
	@echo "default currency:"
	@cast call $(OOV3) "defaultCurrency()(address)" --rpc-url $(RPC_URL)
	@echo "minimum bond:"
	@cast call $(OOV3) "getMinimumBond(address)(uint256)" \
		$$(cast call $(OOV3) "defaultCurrency()(address)" --rpc-url $(RPC_URL)) --rpc-url $(RPC_URL)

deploy-sepolia:
	forge script script/Deploy.s.sol:Deploy \
		--rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--private-key $(PRIVATE_KEY) \
		--broadcast --verify -vvv

deploy-base:
	forge script script/Deploy.s.sol:Deploy \
		--rpc-url $(BASE_RPC_URL) \
		--private-key $(PRIVATE_KEY) \
		--broadcast --verify -vvv

# Read back the exact string UMA voters will judge.
claim-preview:
	@cast call $(MARKET) "claimPreview(bool)(string)" true --rpc-url $(BASE_RPC_URL)

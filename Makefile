# include .env file and export its env vars
# (-include to ignore error if it does not exist)
-include .env

all: clean remove install update solc build 

# Install proper solc version.
solc:; nix-env -f https://github.com/dapphub/dapptools/archive/master.tar.gz -iA solc-static-versions.solc_0_8_10

# Clean the repo
clean  :; forge clean

# Remove modules
remove :; rm -rf .gitmodules && rm -rf .git/modules/* && rm -rf lib && touch .gitmodules && git add . && git commit -m "modules"

# Install the Modules
install :; 
	forge install dapphub/ds-test 
	forge install OpenZeppelin/openzeppelin-contracts

# Update Dependencies
update:; forge update

# Builds
build  :; forge clean && forge build --optimize --optimize-runs 1000000

setup-yarn:
	yarn 

local-node: setup-yarn
	yarn hardhat node

deploy-counter:
	forge create Counter --private-key ${PRIVATE_KEY} --rpc-url ${ETH_RPC_URL} --constructor-args [0xF1417616b8fCafE7E6426143EbBD3EDd4B96e2ec,0xbc53b3b6eEB1a3D27afa2Cc27879D0eFF61E79c2]

deploy-registry:
	forge create RelayRegistry --private-key ${PRIVATE_KEY} --rpc-url ${ETH_RPC_URL} --constructor-args 200000000 1 10 6500000 90000 2 0 2000000000 200000000000 20000000000000000 ${REGISTRAR_ADDRESS}

deploy-registrar:
	forge create RelayRegistrar --private-key ${PRIVATE_KEY} --rpc-url ${ETH_RPC_URL}
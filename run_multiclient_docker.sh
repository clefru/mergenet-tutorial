#!/bin/bash

set -e

LIGHTHOUSE_DOCKER_IMAGE=sigp/lighthouse:rayonism
TEKU_DOCKER_IMAGE=mkalinin/teku:rayonism
NETHERMIND_IMAGE=nethermind/nethermind:latest
GETH_IMAGE=ethereum/client-go:latest

VALIDATORS_MNEMONIC="lumber kind orange gold firm achieve tree robust peasant april very word ordinary before treat way ivory jazz cereal debate juice evil flame sadness"
ETH1_MNEMONIC="enforce patient ridge volume question system myself moon world glass later hello tissue east chair suspect remember check chicken bargain club exit pilot sand"
PRYSM_BULK_KEYSTORE_PASS="foobar"

# Ensure necessary env vars are present.
if [ -z "$TESTNET_NAME" ]; then
    echo TESTNET_NAME is not set, exiting
    exit 1
fi

TESTNET_PATH="${PWD}/testnets/$TESTNET_NAME"
mkdir -p "$TESTNET_PATH"

# Pull client images
docker pull $LIGHTHOUSE_DOCKER_IMAGE
docker pull $TEKU_DOCKER_IMAGE
docker pull $NETHERMIND_IMAGE
docker pull $GETH_IMAGE

# Create venv for scripts
python -m venv venv
. venv/bin/activate
pip install -r requirements.txt

# Configure testnet
mkdir -p "$TESTNET_PATH/public"
mkdir -p "$TESTNET_PATH/private"
mkdir -p "$TESTNET_PATH/nodes"

echo "Preparing keystores"

eth2-val-tools keystores \
  --out-loc "$TESTNET_PATH/private/validator0" \
  --prysm-pass="$PRYSM_BULK_KEYSTORE_PASS" \
  --source-min=0 \
  --source-max=32 \
  --source-mnemonic="$VALIDATORS_MNEMONIC"

eth2-val-tools keystores \
  --out-loc "$TESTNET_PATH/private/validator1" \
  --prysm-pass="$PRYSM_BULK_KEYSTORE_PASS" \
  --source-min=32 \
  --source-max=64 \
  --source-mnemonic="$VALIDATORS_MNEMONIC"

ETH1_GENESIS_TIMESTAMP=$(date +%s)
ETH2_GENESIS_DELAY=600

echo "configuring testnet, genesis: $ETH1_GENESIS_TIMESTAMP (eth1) + $ETH2_GENESIS_DELAY (eth2 delay) = $((ETH1_GENESIS_TIMESTAMP + ETH2_GENESIS_DELAY))"
cat > "$TESTNET_PATH/private/mergenet.yaml" << EOT
mnemonic: ${ETH1_MNEMONIC}
eth1_premine:
  "m/44'/60'/0'/0/0": 10000000ETH
  "m/44'/60'/0'/0/1": 10000000ETH
  "m/44'/60'/0'/0/2": 10000000ETH
chain_id: 700
deposit_contract_address: "0x4242424242424242424242424242424242424242"
# either 'minimal' or 'mainnet'
eth2_base_config: minimal
eth2_fork_version: "0x00000700"
eth1_genesis_timestamp: ${ETH1_GENESIS_TIMESTAMP}
# Tweak this. actual_genesis_timestamp = eth1_genesis_timestamp + eth2_genesis_delay
eth2_genesis_delay: 600
EOT


echo "configuring chains"
# Configure Eth1 chain
python generate_eth1_conf.py "$TESTNET_PATH/private/mergenet.yaml" > "$TESTNET_PATH/public/eth1_config.json"
# Configure Eth1 chain for Nethermind
python generate_eth1_nethermind_conf.py "$TESTNET_PATH/private/mergenet.yaml" > "$TESTNET_PATH/public/eth1_nethermind_config.json"
# Configure Eth2 chain
python generate_eth2_conf.py "$TESTNET_PATH/private/mergenet.yaml" > "$TESTNET_PATH/public/eth2_config.yaml"

echo "configuring genesis validators"
cat > "$TESTNET_PATH/private/genesis_validators.yaml" << EOT
# a 24 word BIP 39 mnemonic
- mnemonic: "${VALIDATORS_MNEMONIC}"
  count: 64  # 64 for minimal config, 16384 for mainnet config
EOT

echo "generating genesis BeaconState"
eth2-testnet-genesis merge \
  --eth1-config "$TESTNET_PATH/public/eth1_config.json" \
  --eth2-config "$TESTNET_PATH/public/eth2_config.yaml" \
  --mnemonics "$TESTNET_PATH/private/genesis_validators.yaml" \
  --state-output "$TESTNET_PATH/public/genesis.ssz" \
  --tranches-dir "$TESTNET_PATH/private/tranches"

echo "preparing geth initial state"
NODE_NAME=catalyst0
mkdir "$TESTNET_PATH/nodes/$NODE_NAME"
docker run \
  --name "$NODE_NAME" \
  --rm \
  -u $(id -u):$(id -g) \
  -v "$TESTNET_PATH/nodes/$NODE_NAME:/gethdata" \
  -v "$TESTNET_PATH/public/eth1_config.json:/networkdata/eth1_config.json" \
  --net host \
  $GETH_IMAGE \
  --catalyst \
  --datadir "/gethdata/chaindata" \
  init "/networkdata/eth1_config.json"

# Run eth1 nodes

# Go-ethereum
# Note: networking is disabled on Geth in merge mode (at least for now)
echo "starting geth node"
NODE_NAME=catalyst0
docker run \
  --name "$NODE_NAME" \
  --net host \
  -u $(id -u):$(id -g) \
  -v "$TESTNET_PATH/nodes/$NODE_NAME:/gethdata" \
  -itd $GETH_IMAGE \
  --catalyst \
  --http --http.api net,eth,consensus \
  --http.port 8500 \
  --http.addr 0.0.0.0 \
  --nodiscover \
  --miner.etherbase 0x1000000000000000000000000000000000000000 \
  --datadir "/gethdata/chaindata"

# Nethermind
# Note: networking is active, the transaction pool propagation is active on nethermind
echo "starting nethermind node"
NODE_NAME=nethermind0
mkdir "$TESTNET_PATH/nodes/$NODE_NAME"
docker run \
  --name $NODE_NAME \
  --net host \
  -u $(id -u):$(id -g) \
  -v "$TESTNET_PATH/public/eth1_nethermind_config.json:/networkdata/eth1_nethermind_config.json" \
  -v "$TESTNET_PATH/nodes/$NODE_NAME:/nethermind" \
  -itd $NETHERMIND_IMAGE \
  -c catalyst \
  --Init.ChainSpecPath "/networkdata/eth1_nethermind_config.json" \
  --JsonRpc.Port 8501 \
  --JsonRpc.Host 0.0.0.0 \
  --Merge.BlockAuthorAccount 0x1000000000000000000000000000000000000000

# Run eth2 beacon nodes

# Teku
echo "starting teku beacon node"
NODE_NAME=teku0bn
mkdir "$TESTNET_PATH/nodes/$NODE_NAME"
docker run \
  --name $NODE_NAME \
  --net host \
  -u $(id -u):$(id -g) \
  -v "$TESTNET_PATH/nodes/$NODE_NAME:/beacondata" \
  -v "$TESTNET_PATH/public/eth2_config.yaml:/networkdata/eth2_config.yaml" \
  -v "$TESTNET_PATH/public/genesis.ssz:/networkdata/genesis.ssz" \
  -itd $TEKU_DOCKER_IMAGE \
  --network "/networkdata/eth2_config.yaml" \
  --data-path "/beacondata" \
  --p2p-enabled=false \
  --initial-state "/networkdata/genesis.ssz" \
  --eth1-endpoint "http://127.0.0.1:8500" \
  --metrics-enabled=true --metrics-interface=0.0.0.0 --metrics-port=8000 \
  --p2p-discovery-enabled=false \
  --p2p-peer-lower-bound=0 \
  --p2p-port=9000 \
  --rest-api-enabled=true \
  --rest-api-docs-enabled=true \
  --rest-api-interface=0.0.0.0 \
  --rest-api-port=4000 \
  --Xdata-storage-non-canonical-blocks-enabled=true

# Lighthouse
echo "starting lighthouse beacon node"
NODE_NAME=lighthouse0bn
mkdir "$TESTNET_PATH/nodes/$NODE_NAME"
docker run \
  --name $NODE_NAME \
  --net host \
  -u $(id -u):$(id -g) \
  -v "$TESTNET_PATH/nodes/$NODE_NAME:/beacondata" \
  -v "$TESTNET_PATH/public/eth2_config.yaml:/networkdata/eth2_config.yaml" \
  -v "$TESTNET_PATH/public/genesis.ssz:/networkdata/genesis.ssz" \
  -itd $LIGHTHOUSE_DOCKER_IMAGE \
  lighthouse \
  --datadir "/beacondata" \
  --testnet-deposit-contract-deploy-block 0 \
  --testnet-genesis-state "/networkdata/genesis.ssz" \
  --testnet-yaml-config "/networkdata/eth2_config.yaml" \
  beacon_node \
  --eth1-endpoints "http://127.0.0.1/8501" \
  --http \
  --http-address 0.0.0.0 \
  --http-port 4001 \
  --metrics \
  --metrics-address 0.0.0.0 \
  --metrics-port 8001 \
  --listen-address 0.0.0.0 \
  --port 9001

# Prysm
# TODO

# Nimbus
# TODO

# validators

# Teku
echo "starting teku validator client"
NODE_NAME=teku0vc
NODE_PATH="$TESTNET_PATH/nodes/$NODE_NAME"
if [ -d "$NODE_PATH" ]
then
  echo "$NODE_NAME already has existing data"
else
  echo "creating data for $NODE_NAME"
  mkdir -p "$NODE_PATH"
  cp -r "$TESTNET_PATH/private/validator0/teku-keys" "$NODE_PATH/keys"
  cp -r "$TESTNET_PATH/private/validator0/teku-secrets" "$NODE_PATH/secrets"
fi

docker run \
  --name $NODE_NAME \
  --net host \
  -u $(id -u):$(id -g) \
  -v "$TESTNET_PATH/nodes/$NODE_NAME:/validatordata" \
  -v "$TESTNET_PATH/public/eth2_config.yaml:/networkdata/eth2_config.yaml" \
  -v "$TESTNET_PATH/public/genesis.ssz:/networkdata/genesis.ssz" \
  -itd $TEKU_DOCKER_IMAGE \
  validator-client \
  --network "/networkdata/eth2_config.yaml" \
  --data-path "/validatordata" \
  --beacon-node-api-endpoint "http://127.0.0.1:4000" \
  --validators-graffiti="teku" \
  --validator-keys "/validatordata/keys:/validatordata/secrets"


# Lighthouse
echo "starting lighthouse validator client"
NODE_NAME=lighthouse0vc
NODE_PATH="$TESTNET_PATH/nodes/$NODE_NAME"
if [ -d "$NODE_PATH" ]
then
  echo "$NODE_NAME already has existing data"
else
  echo "creating data for $NODE_NAME"
  mkdir -p "$NODE_PATH"
  cp -r "$TESTNET_PATH/private/validator1/keys" "$NODE_PATH/keys"
  cp -r "$TESTNET_PATH/private/validator1/secrets" "$NODE_PATH/secrets"
fi

docker run \
  --name $NODE_NAME \
  --net host \
  -u $(id -u):$(id -g) \
  -v "$TESTNET_PATH/nodes/$NODE_NAME:/validatordata" \
  -v "$TESTNET_PATH/public/eth2_config.yaml:/networkdata/eth2_config.yaml" \
  -v "$TESTNET_PATH/public/genesis.ssz:/networkdata/genesis.ssz" \
  -itd $LIGHTHOUSE_DOCKER_IMAGE \
  lighthouse \
  --testnet-deposit-contract-deploy-block 0 \
  --testnet-genesis-state "/networkdata/genesis.ssz" \
  --testnet-yaml-config "/networkdata/eth2_config.yaml" \
  validator_client \
  --init-slashing-protection \
  --beacon-nodes "127.0.0.1:4001" \
  --graffiti="lighthouse" \
  --validators-dir "/validatordata/keys" \
  --secrets-dir "/validatordata/secrets"
#!/bin/sh
# Entry point used by ci-dev.
# Same failure propagation as prepare.sh, for both the full node and light client.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/prepare_common.sh
. "$SCRIPT_DIR/scripts/prepare_common.sh"

export_build_env

WORKDIR=${PREPARE_WORKDIR:-$SCRIPT_DIR}
CLIENT_DIR=${PREPARE_CLIENT_DIR:-}
CKB_RPC_URL=${PREPARE_CKB_RPC_URL:-http://127.0.0.1:8114}
LIGHT_RPC_URL=${PREPARE_RPC_URL:-http://127.0.0.1:9000}
RPC_ATTEMPTS=${PREPARE_RPC_ATTEMPTS:-12}
RPC_SLEEP=${PREPARE_RPC_SLEEP:-5}
CKB_BIN_REL=ckb/target/release/ckb
LIGHT_BIN_REL=ckb-light-client/target/release/ckb-light-client

if [ -z "$PREPARE_SKIP_CLONE" ]; then
    mkdir -p "$WORKDIR/tmp" || prepare_fail "cannot create $WORKDIR/tmp"
    run_checked "git clone startBlockchain" git clone https://github.com/gpBlockchain/startBlockchain.git "$WORKDIR/tmp/startBlockchain"
    CLIENT_DIR=$WORKDIR/tmp/startBlockchain/ckbDevWithIndexAndLightClient
fi

if [ -z "$CLIENT_DIR" ]; then
    prepare_fail "PREPARE_CLIENT_DIR is required when PREPARE_SKIP_CLONE is set"
fi

cd "$CLIENT_DIR" || prepare_fail "cannot cd to $CLIENT_DIR"

run_checked "nested prepare.sh" sh prepare.sh
require_binary "$CLIENT_DIR/$CKB_BIN_REL"
require_binary "$CLIENT_DIR/$LIGHT_BIN_REL"

run_checked "nested start.sh" sh start.sh
require_binary "$CLIENT_DIR/$CKB_BIN_REL"
require_binary "$CLIENT_DIR/$LIGHT_BIN_REL"

if [ -f "$CLIENT_DIR/status.sh" ]; then
    sh status.sh || true
fi

if ! wait_rpc_ready "$CKB_RPC_URL" "$RPC_ATTEMPTS" "$RPC_SLEEP"; then
    if [ -f "$CLIENT_DIR/ckb/target/release/dev.log" ]; then
        echo "----- ckb dev.log -----" >&2
        cat "$CLIENT_DIR/ckb/target/release/dev.log" >&2 || true
    fi
    exit 1
fi

if ! wait_rpc_ready "$LIGHT_RPC_URL" "$RPC_ATTEMPTS" "$RPC_SLEEP"; then
    if [ -f "$CLIENT_DIR/ckb-light-client/target/release/node.log" ]; then
        echo "----- ckb-light-client node.log -----" >&2
        cat "$CLIENT_DIR/ckb-light-client/target/release/node.log" >&2 || true
    fi
    exit 1
fi

echo "prepare ckb dev and Light Client finish"

#!/bin/sh
# Entry point used by ci-ckb / ci-data (and roll-back).
# Check nested script exit codes, the release binary, and RPC readiness.
# Do not use set -e: a failed pkill inside a child must not be our only signal,
# and we must not abort on other tolerated non-zero commands we do not run here.
# If a child swallows a cargo failure, require_binary still fails the entry.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/prepare_common.sh
. "$SCRIPT_DIR/scripts/prepare_common.sh"

export_build_env

WORKDIR=${PREPARE_WORKDIR:-$SCRIPT_DIR}
CLIENT_DIR=${PREPARE_CLIENT_DIR:-}
RPC_URL=${PREPARE_RPC_URL:-http://127.0.0.1:9000}
RPC_ATTEMPTS=${PREPARE_RPC_ATTEMPTS:-12}
RPC_SLEEP=${PREPARE_RPC_SLEEP:-5}
BINARY_REL=ckb-light-client/target/release/ckb-light-client

if [ -z "$PREPARE_SKIP_CLONE" ]; then
    mkdir -p "$WORKDIR/tmp" || prepare_fail "cannot create $WORKDIR/tmp"
    run_checked "git clone startBlockchain" git clone https://github.com/gpBlockchain/startBlockchain.git "$WORKDIR/tmp/startBlockchain"
    CLIENT_DIR=$WORKDIR/tmp/startBlockchain/ckbLightClient
fi

if [ -z "$CLIENT_DIR" ]; then
    prepare_fail "PREPARE_CLIENT_DIR is required when PREPARE_SKIP_CLONE is set"
fi

cd "$CLIENT_DIR" || prepare_fail "cannot cd to $CLIENT_DIR"

run_checked "nested prepare.sh" sh prepare.sh
require_binary "$CLIENT_DIR/$BINARY_REL"

run_checked "nested start.sh" sh start.sh
require_binary "$CLIENT_DIR/$BINARY_REL"

if [ -f "$CLIENT_DIR/status.sh" ]; then
    # Keep the existing status probe for logs, but do not trust its exit code.
    sh status.sh || true
fi

if ! wait_rpc_ready "$RPC_URL" "$RPC_ATTEMPTS" "$RPC_SLEEP"; then
    if [ -f "$CLIENT_DIR/ckb-light-client/target/release/node.log" ]; then
        echo "----- ckb-light-client node.log -----" >&2
        cat "$CLIENT_DIR/ckb-light-client/target/release/node.log" >&2 || true
    fi
    exit 1
fi

if [ -f "$CLIENT_DIR/ckb-light-client/target/release/node.log" ]; then
    cat "$CLIENT_DIR/ckb-light-client/target/release/node.log" || true
fi

echo "prepare ckb Light Client finish"

#!/bin/sh
# Fast stub regression for repo-local prepare entrypoints.
# Does not clone startBlockchain or build the product.

set -u
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PASS=0
FAIL=0

assert_exit() {
    _label=$1
    _expect=$2
    _actual=$3
    if [ "$_actual" -eq "$_expect" ]; then
        echo "PASS: $_label (exit $_actual)"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $_label (expected exit $_expect, got $_actual)"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    _label=$1
    _needle=$2
    _haystack=$3
    case "$_haystack" in
        *"$_needle"*)
            echo "PASS: $_label"
            PASS=$((PASS + 1))
            ;;
        *)
            echo "FAIL: $_label (missing: $_needle)"
            echo "----- output -----"
            echo "$_haystack"
            FAIL=$((FAIL + 1))
            ;;
    esac
}

make_stub_tree() {
    _dir=$1
    mkdir -p "$_dir/ckb-light-client/target/release"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$_dir/prepare.sh"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$_dir/start.sh"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$_dir/status.sh"
    chmod +x "$_dir/prepare.sh" "$_dir/start.sh" "$_dir/status.sh"
}

make_dev_stub_tree() {
    _dir=$1
    mkdir -p "$_dir/ckb/target/release" "$_dir/ckb-light-client/target/release"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$_dir/prepare.sh"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$_dir/start.sh"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$_dir/status.sh"
    chmod +x "$_dir/prepare.sh" "$_dir/start.sh" "$_dir/status.sh"
}

# Write a tiny HTTP JSON-RPC stub. Pid and port go to files; server stdio is
# redirected so this function can be used without hanging the test shell.
start_rpc_stub() {
    _portfile=$1
    _pidfile=$2
    : > "$WORKDIR/rpc-stub.log"
    python3 - "$_portfile" >>"$WORKDIR/rpc-stub.log" 2>&1 &
    echo $! > "$_pidfile"
    # The - argument is consumed after we pass the portfile via argv, but we
    # also need the program text. Use a sidecar file to avoid heredoc+& issues.
}

# Implement the server as a sidecar script created once.
install_rpc_stub_script() {
    cat > "$WORKDIR/rpc_stub.py" << 'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

portfile = sys.argv[1]

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "result": {"number": "0x0"}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, fmt, *args):
        return

httpd = HTTPServer(("127.0.0.1", 0), Handler)
with open(portfile, "w") as f:
    f.write(str(httpd.server_address[1]))
httpd.serve_forever()
PY
}

start_rpc_stub() {
    _portfile=$1
    _pidfile=$2
    rm -f "$_portfile"
    python3 "$WORKDIR/rpc_stub.py" "$_portfile" >>"$WORKDIR/rpc-stub.log" 2>&1 &
    echo $! > "$_pidfile"
    python3 -c "import os,sys,time
p=sys.argv[1]
for _ in range(100):
    if os.path.isfile(p) and os.path.getsize(p)>0:
        raise SystemExit(0)
    time.sleep(0.05)
raise SystemExit(1)" "$_portfile" || echo "FAIL: rpc stub did not publish port" >&2
}

WORKDIR=$(mktemp -d)
install_rpc_stub_script
trap 'rm -rf "$WORKDIR"; if [ -n "${RPC_PID:-}" ]; then kill "$RPC_PID" 2>/dev/null || true; fi; if [ -n "${RPC_PID2:-}" ]; then kill "$RPC_PID2" 2>/dev/null || true; fi' EXIT

echo "===== 1) nested prepare.sh non-zero is propagated ====="
T1=$WORKDIR/t1
make_stub_tree "$T1"
printf '%s\n' '#!/bin/sh' 'exit 2' > "$T1/prepare.sh"
chmod +x "$T1/prepare.sh"
ST=0
OUT=$(PREPARE_SKIP_CLONE=1 PREPARE_CLIENT_DIR="$T1" PREPARE_RPC_ATTEMPTS=1 PREPARE_RPC_SLEEP=0 \
    sh "$REPO_DIR/prepare.sh" 2>&1) || ST=$?
ST=${ST:-0}
assert_exit "prepare.sh build failure exit" 2 "$ST"
assert_contains "prepare.sh reports nested prepare exit" "nested prepare.sh exited with 2" "$OUT"

echo "===== 2) prepare succeeds but binary missing ====="
T2=$WORKDIR/t2
make_stub_tree "$T2"
ST=0
OUT=$(PREPARE_SKIP_CLONE=1 PREPARE_CLIENT_DIR="$T2" PREPARE_RPC_ATTEMPTS=1 PREPARE_RPC_SLEEP=0 \
    sh "$REPO_DIR/prepare.sh" 2>&1) || ST=$?
ST=${ST:-0}
assert_exit "prepare.sh missing binary exit" 1 "$ST"
assert_contains "prepare.sh reports missing binary" "required binary missing" "$OUT"

echo "===== 3) start.sh non-zero after a present binary ====="
T3=$WORKDIR/t3
make_stub_tree "$T3"
printf '#!/bin/sh\nexit 0\n' > "$T3/ckb-light-client/target/release/ckb-light-client"
chmod +x "$T3/ckb-light-client/target/release/ckb-light-client"
printf '%s\n' '#!/bin/sh' 'exit 3' > "$T3/start.sh"
chmod +x "$T3/start.sh"
ST=0
OUT=$(PREPARE_SKIP_CLONE=1 PREPARE_CLIENT_DIR="$T3" PREPARE_RPC_ATTEMPTS=1 PREPARE_RPC_SLEEP=0 \
    sh "$REPO_DIR/prepare.sh" 2>&1) || ST=$?
ST=${ST:-0}
assert_exit "prepare.sh start failure exit" 3 "$ST"
assert_contains "prepare.sh reports nested start exit" "nested start.sh exited with 3" "$OUT"

echo "===== 4) RPC not ready after binary and start ====="
T4=$WORKDIR/t4
make_stub_tree "$T4"
printf '#!/bin/sh\nexit 0\n' > "$T4/ckb-light-client/target/release/ckb-light-client"
chmod +x "$T4/ckb-light-client/target/release/ckb-light-client"
ST=0
OUT=$(PREPARE_SKIP_CLONE=1 PREPARE_CLIENT_DIR="$T4" \
    PREPARE_RPC_URL="http://127.0.0.1:1" \
    PREPARE_RPC_ATTEMPTS=2 PREPARE_RPC_SLEEP=0 \
    sh "$REPO_DIR/prepare.sh" 2>&1) || ST=$?
ST=${ST:-0}
assert_exit "prepare.sh RPC not ready exit" 1 "$ST"
assert_contains "prepare.sh reports RPC not ready" "RPC not ready at http://127.0.0.1:1" "$OUT"

echo "===== 5) happy path with RPC stub ====="
T5=$WORKDIR/t5
make_stub_tree "$T5"
printf '#!/bin/sh\nexit 0\n' > "$T5/ckb-light-client/target/release/ckb-light-client"
chmod +x "$T5/ckb-light-client/target/release/ckb-light-client"
PORTFILE=$WORKDIR/rpc.port
PIDFILE=$WORKDIR/rpc.pid
start_rpc_stub "$PORTFILE" "$PIDFILE"
RPC_PID=$(cat "$PIDFILE")
PORT=$(cat "$PORTFILE")
ST=0
OUT=$(PREPARE_SKIP_CLONE=1 PREPARE_CLIENT_DIR="$T5" \
    PREPARE_RPC_URL="http://127.0.0.1:$PORT" \
    PREPARE_RPC_ATTEMPTS=5 PREPARE_RPC_SLEEP=0 \
    sh "$REPO_DIR/prepare.sh" 2>&1) || ST=$?
ST=${ST:-0}
assert_exit "prepare.sh happy path exit" 0 "$ST"
assert_contains "prepare.sh happy path finish" "prepare ckb Light Client finish" "$OUT"
kill "$RPC_PID" 2>/dev/null || true
RPC_PID=

echo "===== 6) RUSQLITE is forwarded to nested prepare.sh ====="
T6=$WORKDIR/t6
make_stub_tree "$T6"
printf '#!/bin/sh\nexit 0\n' > "$T6/ckb-light-client/target/release/ckb-light-client"
chmod +x "$T6/ckb-light-client/target/release/ckb-light-client"
printf '%s\n' '#!/bin/sh' 'printf "nested-rusqlite=[%s]\n" "${RUSQLITE-UNSET}" > rusqlite.seen' 'exit 0' > "$T6/prepare.sh"
chmod +x "$T6/prepare.sh"
PORTFILE=$WORKDIR/rpc2.port
PIDFILE=$WORKDIR/rpc2.pid
start_rpc_stub "$PORTFILE" "$PIDFILE"
RPC_PID=$(cat "$PIDFILE")
PORT=$(cat "$PORTFILE")
RUSQLITE=1 PREPARE_SKIP_CLONE=1 PREPARE_CLIENT_DIR="$T6" \
    PREPARE_RPC_URL="http://127.0.0.1:$PORT" \
    PREPARE_RPC_ATTEMPTS=5 PREPARE_RPC_SLEEP=0 \
    sh "$REPO_DIR/prepare.sh" >/dev/null 2>&1 || true
SEEN=$(cat "$T6/rusqlite.seen" 2>/dev/null || echo missing)
assert_contains "RUSQLITE=1 reaches nested prepare.sh" "nested-rusqlite=[1]" "$SEEN"

printf '%s\n' '#!/bin/sh' 'printf "nested-rusqlite=[%s]\n" "${RUSQLITE-UNSET}" > rusqlite.seen' 'exit 0' > "$T6/prepare.sh"
chmod +x "$T6/prepare.sh"
RUSQLITE= PREPARE_SKIP_CLONE=1 PREPARE_CLIENT_DIR="$T6" \
    PREPARE_RPC_URL="http://127.0.0.1:$PORT" \
    PREPARE_RPC_ATTEMPTS=5 PREPARE_RPC_SLEEP=0 \
    sh "$REPO_DIR/prepare.sh" >/dev/null 2>&1 || true
SEEN=$(cat "$T6/rusqlite.seen" 2>/dev/null || echo missing)
assert_contains "empty RUSQLITE reaches nested prepare.sh" "nested-rusqlite=[]" "$SEEN"
kill "$RPC_PID" 2>/dev/null || true
RPC_PID=

echo "===== 7) prepare_dev.sh missing ckb binary ====="
T7=$WORKDIR/t7
make_dev_stub_tree "$T7"
printf '#!/bin/sh\nexit 0\n' > "$T7/ckb-light-client/target/release/ckb-light-client"
chmod +x "$T7/ckb-light-client/target/release/ckb-light-client"
ST=0
OUT=$(PREPARE_SKIP_CLONE=1 PREPARE_CLIENT_DIR="$T7" PREPARE_RPC_ATTEMPTS=1 PREPARE_RPC_SLEEP=0 \
    sh "$REPO_DIR/prepare_dev.sh" 2>&1) || ST=$?
ST=${ST:-0}
assert_exit "prepare_dev.sh missing ckb binary exit" 1 "$ST"
assert_contains "prepare_dev.sh reports missing ckb" "required binary missing" "$OUT"

echo "===== 8) prepare_dev.sh happy path ====="
T8=$WORKDIR/t8
make_dev_stub_tree "$T8"
printf '#!/bin/sh\nexit 0\n' > "$T8/ckb/target/release/ckb"
printf '#!/bin/sh\nexit 0\n' > "$T8/ckb-light-client/target/release/ckb-light-client"
chmod +x "$T8/ckb/target/release/ckb" "$T8/ckb-light-client/target/release/ckb-light-client"
PORTFILEA=$WORKDIR/rpcA.port
PORTFILEB=$WORKDIR/rpcB.port
PIDFILEA=$WORKDIR/rpcA.pid
PIDFILEB=$WORKDIR/rpcB.pid
start_rpc_stub "$PORTFILEA" "$PIDFILEA"
start_rpc_stub "$PORTFILEB" "$PIDFILEB"
RPC_PID=$(cat "$PIDFILEA")
RPC_PID2=$(cat "$PIDFILEB")
PORTA=$(cat "$PORTFILEA")
PORTB=$(cat "$PORTFILEB")
ST=0
OUT=$(PREPARE_SKIP_CLONE=1 PREPARE_CLIENT_DIR="$T8" \
    PREPARE_CKB_RPC_URL="http://127.0.0.1:$PORTA" \
    PREPARE_RPC_URL="http://127.0.0.1:$PORTB" \
    PREPARE_RPC_ATTEMPTS=5 PREPARE_RPC_SLEEP=0 \
    sh "$REPO_DIR/prepare_dev.sh" 2>&1) || ST=$?
ST=${ST:-0}
assert_exit "prepare_dev.sh happy path exit" 0 "$ST"
assert_contains "prepare_dev.sh happy path finish" "prepare ckb dev and Light Client finish" "$OUT"
kill "$RPC_PID" "$RPC_PID2" 2>/dev/null || true
RPC_PID=
RPC_PID2=

echo
echo "passed=$PASS failed=$FAIL"
if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
exit 0

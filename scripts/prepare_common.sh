# Shared helpers for repo-local prepare entrypoints.
# POSIX sh. Do not enable set -e here: callers must tolerate
# non-fatal commands (for example pkill when no process exists).
# Nested startBlockchain scripts may swallow cargo failures; callers
# must still require the built binary and a ready RPC.

prepare_fail() {
    echo "error: $*" >&2
    exit 1
}

run_checked() {
    # usage: run_checked LABEL command [args...]
    _prepare_label=$1
    shift
    "$@"
    _prepare_status=$?
    if [ "$_prepare_status" -ne 0 ]; then
        echo "error: ${_prepare_label} exited with ${_prepare_status}" >&2
        exit "$_prepare_status"
    fi
}

require_binary() {
    # usage: require_binary PATH
    if [ ! -f "$1" ]; then
        echo "error: required binary missing: $1" >&2
        exit 1
    fi
    if [ ! -x "$1" ]; then
        echo "error: required binary is not executable: $1" >&2
        exit 1
    fi
}

wait_rpc_ready() {
    # usage: wait_rpc_ready URL [attempts] [sleep_seconds]
    _prepare_url=$1
    _prepare_attempts=${2:-12}
    _prepare_sleep=${3:-5}
    _prepare_i=1
    _prepare_payload='{"jsonrpc":"2.0","method":"get_tip_header","params":[],"id":1}'
    while [ "$_prepare_i" -le "$_prepare_attempts" ]; do
        _prepare_body=$(curl -sS -m 3 -X POST -H "Content-Type: application/json" \
            -d "$_prepare_payload" "$_prepare_url" 2>/dev/null || true)
        case "$_prepare_body" in
            *'"result"'*)
                echo "rpc ready: ${_prepare_url}"
                return 0
                ;;
        esac
        if [ "$_prepare_i" -lt "$_prepare_attempts" ]; then
            sleep "$_prepare_sleep"
        fi
        _prepare_i=$((_prepare_i + 1))
    done
    echo "error: RPC not ready at ${_prepare_url} after ${_prepare_attempts} attempt(s)" >&2
    return 1
}

# Map CI matrix rusqlite true/false to the env the nested startBlockchain
# prepare.sh already understands:
#   RUSQLITE non-empty -> cargo build --release --no-default-features --features sqlite
#   RUSQLITE empty     -> cargo build --release  (default rocksdb)
export_build_env() {
    # Keep values as provided; just ensure they are exported to children.
    if [ -n "${CKB_LIGHT_CLIENT_URL+x}" ]; then
        export CKB_LIGHT_CLIENT_URL
    fi
    if [ -n "${CKB_LIGHT_CLIENT_BRANCH+x}" ]; then
        export CKB_LIGHT_CLIENT_BRANCH
    fi
    # RUSQLITE may be legitimately empty for the rocksdb path.
    export RUSQLITE
}

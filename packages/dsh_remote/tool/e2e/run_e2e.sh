#!/usr/bin/env bash
# End-to-end check of dsh_remote against the real upstream stack, fully
# isolated in a temp dir (own HOME and DSH_HOME, loopback only):
#
#   ds-harness-remote apps/server (self-hosted, password login, Relay only)
#     <- Host: `dsh web` + ds-harness-remote@$PLUGIN_VERSION plugin from npm
#     <- Client: test/live_remote_test.dart (this package), no model prompts
#
# Usage: tool/e2e/run_e2e.sh [--keep]
# Env:   UPSTREAM   ds-harness-remote checkout (default ../../.refs/ds-harness-remote-upstream)
#        DSH_BIN    dsh launcher for the Host (default: dsh on PATH)
#        PLUGIN_VERSION (default 0.5.20)
#        PLUGIN_SPEC  anything `dsh plugin add` accepts, e.g. a packed upstream
#                     tarball (default ds-harness-remote@$PLUGIN_VERSION)
# Needs: node >= 22, npm, network access to the npm registry, dart.
set -euo pipefail

PKG="$(cd "$(dirname "$0")/../.." && pwd)"
UPSTREAM="${UPSTREAM:-$PKG/../../.refs/ds-harness-remote-upstream}"
DSH_BIN="${DSH_BIN:-dsh}"
PLUGIN_VERSION="${PLUGIN_VERSION:-0.5.20}"
PLUGIN_SPEC="${PLUGIN_SPEC:-ds-harness-remote@$PLUGIN_VERSION}"
KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1
ORIG_HOME="$HOME"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dsh-remote-e2e.XXXXXX")"
SERVER_PID=""
HOST_PID=""
cleanup() {
  [[ -n "$HOST_PID" ]] && kill "$HOST_PID" 2>/dev/null || true
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
  wait 2>/dev/null || true
  if [[ "$KEEP" == 1 ]]; then echo "kept $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

log() { printf '[e2e] %s\n' "$*"; }
wait_for() { # file pattern seconds
  for _ in $(seq 1 $(( $3 * 4 ))); do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 0.25; done
  echo "timed out waiting for '$2' in $1" >&2; tail -20 "$1" >&2; return 1
}

# 1. Self-hosted Server, bundled from the upstream sources.
log "building self-hosted Server from $UPSTREAM"
mkdir -p "$WORK/server/src/server" "$WORK/server/src/protocol" "$WORK/home" "$WORK/dsh-home" "$WORK/work"
cp "$UPSTREAM"/apps/server/src/*.ts "$WORK/server/src/server/"
cp "$UPSTREAM"/packages/protocol/src/*.ts "$WORK/server/src/protocol/"
echo '{"name":"e2e-server","private":true,"type":"module"}' > "$WORK/server/package.json"
(cd "$WORK/server" && HOME="$WORK/home" npm install --silent --no-audit --no-fund \
  --registry=https://registry.npmjs.org/ ws@8.18.3 zod@3.24.1 esbuild@0.24.2 >/dev/null)
(cd "$WORK/server" && ./node_modules/.bin/esbuild src/server/main.ts --bundle --platform=node --format=esm \
  --target=node22 --alias:@dsh-remote/protocol=./src/protocol/index.ts --outfile=dist/main.js --log-level=warning \
  --banner:js="import { createRequire } from 'module'; const require = createRequire(import.meta.url);")

PORT="$(node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')"
SERVER_URL="http://127.0.0.1:$PORT"
ACCOUNT="e2e-owner@example.test"
PASSWORD="e2e-$(node -e 'console.log(require("crypto").randomBytes(18).toString("base64url"))')"
(cd "$WORK/server" && DSH_SERVER_ACCOUNT="$ACCOUNT" DSH_SERVER_PASSWORD="$PASSWORD" DSH_SERVER_PUBLIC_URL="$SERVER_URL" \
  DSH_SERVER_PORT="$PORT" DSH_SERVER_HOST=127.0.0.1 DSH_SERVER_DATA_FILE="$WORK/server-data/state.json" \
  exec node dist/main.js >"$WORK/server.log" 2>&1) &
SERVER_PID=$!
wait_for "$WORK/server.log" "listening" 20
log "Server at $SERVER_URL"

# 2. Host: isolated DSH profile with the plugin pointed at the local Server.
export HOME="$WORK/home" DSH_HOME="$WORK/dsh-home"
log "installing $PLUGIN_SPEC into an isolated profile"
(cd "$WORK" && "$DSH_BIN" plugin --profile web add -w --no-optional "$PLUGIN_SPEC" >"$WORK/plugin-install.log" 2>&1) \
  || { tail -30 "$WORK/plugin-install.log" >&2; exit 1; }
cat >"$DSH_HOME/profiles/web/cordis.patch.yml" <<EOF
- id: ds-harness-remote
  config:
    enabled: true
    role: host
    serverUrl: $SERVER_URL
    deviceName: E2E Host
    terminal: { enabled: false }
    codex: { enabled: false }
    cursor: { enabled: false }
    acp: { enabled: false }
EOF
node "$PKG/tool/e2e/provision-host.mjs" "$SERVER_URL" "$ACCOUNT" "$PASSWORD" "$DSH_HOME" "E2E Host" >"$WORK/host.json"
(cd "$WORK/work" && exec env -u DEEPSEEK_API_KEY "$DSH_BIN" web --host 127.0.0.1 --port 0 --no-open >"$WORK/host.log" 2>&1) &
HOST_PID=$!
wait_for "$WORK/host.log" "server control connection online" 90
log "Host online ($("$DSH_BIN" --version))"

# 3. Client: the live test through the Relay.
log "running test/live_remote_test.dart"
(cd "$PKG" && DSH_REMOTE_LIVE_SERVER="$SERVER_URL" DSH_REMOTE_LIVE_EMAIL="$ACCOUNT" DSH_REMOTE_PASSWORD="$PASSWORD" \
  DSH_REMOTE_LIVE_CWD="$WORK/work" HOME="$ORIG_HOME" dart test -t live test/live_remote_test.dart -r expanded)
log "ok"

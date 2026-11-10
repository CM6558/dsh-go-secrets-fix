#!/usr/bin/env bash
# Provisions and deploys dshgo-share on our Cloudflare account. Touches only
# its own resources:
#   R2 bucket dshgo-share (+ its lifecycle rules), KV namespace
#   dshgo-share-quota, Worker dshgo-share (+ its ADMIN_KEY secret), and one
#   Workers Custom Domain (go.<zone>, else s.<zone>), which creates its own DNS
#   record. Never reads or changes other Workers, DNS records or zone settings.
#
#   CF_TOKEN_FILE=<file> scripts/provision.sh check    read-only: what exists, which domain
#   CF_TOKEN_FILE=<file> scripts/provision.sh apply    create what's missing, deploy, e2e
#   CF_TOKEN_FILE=<file> scripts/provision.sh deploy   redeploy the code only
#
# The token is only ever passed as `$(cat "$CF_TOKEN_FILE")` straight into
# curl / wrangler: never echoed, stored or put in a URL. Don't add `set -x`.
set -euo pipefail

cd "$(dirname "$0")/.."
: "${CF_TOKEN_FILE:?set CF_TOKEN_FILE to the API token file}"
[[ -r "$CF_TOKEN_FILE" ]] || { echo "can't read CF_TOKEN_FILE" >&2; exit 1; }
ZONE_NAME=${ZONE_NAME:-dshtui.com}
WORKER=dshgo-share
BUCKET=dshgo-share
KV_TITLE=dshgo-share-quota
ADMIN_FILE=${ADMIN_FILE:-$HOME/.config/keys/dshgo-share-admin.txt}
CANDIDATES=("go.$ZONE_NAME" "s.$ZONE_NAME")
API=${CF_API:-https://api.cloudflare.com/client/v4}

cf() { # METHOD PATH [JSON]
  local args=(-sS -X "$1" "$API$2" -H "Authorization: Bearer $(cat "$CF_TOKEN_FILE")" -H 'Content-Type: application/json')
  [[ $# -ge 3 ]] && args+=(--data "$3")
  curl "${args[@]}"
}

ok() { jq -e '.success == true' >/dev/null <<<"$1"; }
die() { echo "provision: $*" >&2; exit 1; }

wr() { CLOUDFLARE_API_TOKEN="$(cat "$CF_TOKEN_FILE")" CLOUDFLARE_ACCOUNT_ID="$ACCOUNT" WRANGLER_SEND_METRICS=false npx wrangler "$@"; }

# ── Read-only discovery ──────────────────────────────────────────────────
zone_json=$(cf GET "/zones?name=$ZONE_NAME")
ok "$zone_json" || die "zone lookup failed: $(jq -c '.errors' <<<"$zone_json")"
ZONE=$(jq -r '.result[0].id // empty' <<<"$zone_json")
ACCOUNT=$(jq -r '.result[0].account.id // empty' <<<"$zone_json")
[[ -n "$ZONE" && -n "$ACCOUNT" ]] || die "zone $ZONE_NAME is not on this account"
echo "zone $ZONE_NAME: $ZONE (account $ACCOUNT)"

scripts=$(cf GET "/accounts/$ACCOUNT/workers/scripts")
ok "$scripts" || die "listing Workers failed"
WORKER_EXISTS=$(jq -r --arg w "$WORKER" '[.result[] | select(.id == $w)] | length' <<<"$scripts")

domains=$(cf GET "/accounts/$ACCOUNT/workers/domains?zone_id=$ZONE")
ok "$domains" || die "listing Workers custom domains failed"
routes=$(cf GET "/zones/$ZONE/workers/routes")
ok "$routes" || die "listing Worker routes failed"

# A host is free when no DNS record has its name, no custom domain claims it
# and no Worker route pattern would catch it. Re-runs keep our own domain.
host_state() {
  local host=$1
  local owner
  owner=$(jq -r --arg h "$host" '[.result[] | select(.hostname == $h) | .service] | first // empty' <<<"$domains")
  if [[ -n "$owner" ]]; then
    [[ "$owner" == "$WORKER" ]] && echo ours || echo "taken (custom domain of $owner)"
    return
  fi
  local records
  records=$(cf GET "/zones/$ZONE/dns_records?name=$host")
  ok "$records" || { echo "unknown (DNS lookup failed)"; return; }
  if [[ $(jq '.result | length' <<<"$records") != 0 ]]; then
    echo "taken (DNS: $(jq -r '[.result[] | .type] | join(",")' <<<"$records"))"
    return
  fi
  local route
  route=$(jq -r --arg h "$host" '[.result[] | .pattern | select(
      (split("/")[0]) as $p | $p == $h or ($p | startswith("*") and ($h | endswith($p[1:]))))] | first // empty' <<<"$routes")
  [[ -n "$route" ]] && { echo "taken (route $route)"; return; }
  echo free
}

HOST=
for h in "${CANDIDATES[@]}"; do
  state=$(host_state "$h")
  echo "  $h: $state"
  if [[ -z "$HOST" && ( "$state" == free || "$state" == ours ) ]]; then HOST=$h; fi
done
wildcard=$(cf GET "/zones/$ZONE/dns_records?name=*.$ZONE_NAME")
if ok "$wildcard" && [[ $(jq '.result | length' <<<"$wildcard") != 0 ]]; then
  echo "  note: *.$ZONE_NAME has a wildcard record; the custom domain takes precedence for its own host"
fi
[[ -n "$HOST" ]] || die "neither ${CANDIDATES[*]} is free; stopping"
echo "domain: $HOST"
echo "worker $WORKER exists: $([[ $WORKER_EXISTS != 0 ]] && echo yes || echo no)"

bucket=$(cf GET "/accounts/$ACCOUNT/r2/buckets/$BUCKET")
BUCKET_EXISTS=$(ok "$bucket" && echo 1 || echo 0)
echo "bucket $BUCKET exists: $([[ $BUCKET_EXISTS == 1 ]] && echo yes || echo no)"

kv_list=$(cf GET "/accounts/$ACCOUNT/storage/kv/namespaces?per_page=100")
ok "$kv_list" || die "listing KV namespaces failed"
KV_ID=$(jq -r --arg t "$KV_TITLE" '[.result[] | select(.title == $t) | .id] | first // empty' <<<"$kv_list")
echo "kv $KV_TITLE: ${KV_ID:-missing}"

mode=${1:-check}
[[ "$mode" == check ]] && exit 0

# ── Writes: only our own resources ───────────────────────────────────────
if [[ "$mode" == apply ]]; then
  if [[ $WORKER_EXISTS != 0 && "$(host_state "$HOST")" != ours && "${ALLOW_EXISTING_WORKER:-}" != 1 ]]; then
    die "a Worker named $WORKER already exists and isn't on $HOST; not touching it (ALLOW_EXISTING_WORKER=1 if it is ours)"
  fi

  if [[ $BUCKET_EXISTS == 0 ]]; then
    res=$(cf POST "/accounts/$ACCOUNT/r2/buckets" "{\"name\":\"$BUCKET\"}")
    ok "$res" || die "creating bucket failed: $(jq -c '.errors' <<<"$res") (R2 may need enabling in the dashboard first)"
    echo "created bucket $BUCKET"
  fi
  # Our bucket only: replaces its rule set with exactly these.
  res=$(cf PUT "/accounts/$ACCOUNT/r2/buckets/$BUCKET/lifecycle" '{"rules":[
    {"id":"expire-7d","enabled":true,"conditions":{"prefix":"7d/"},"deleteObjectsTransition":{"condition":{"type":"Age","maxAge":604800}}},
    {"id":"expire-30d","enabled":true,"conditions":{"prefix":"30d/"},"deleteObjectsTransition":{"condition":{"type":"Age","maxAge":2592000}}},
    {"id":"abort-multipart","enabled":true,"conditions":{"prefix":""},"abortMultipartUploadsTransition":{"condition":{"type":"Age","maxAge":86400}}}]}')
  ok "$res" || die "setting lifecycle failed: $(jq -c '.errors' <<<"$res")"
  echo "lifecycle: 7d/ → 7 days, 30d/ → 30 days"

  if [[ -z "$KV_ID" ]]; then
    res=$(cf POST "/accounts/$ACCOUNT/storage/kv/namespaces" "{\"title\":\"$KV_TITLE\"}")
    ok "$res" || die "creating KV failed: $(jq -c '.errors' <<<"$res")"
    KV_ID=$(jq -r '.result.id' <<<"$res")
    echo "created kv $KV_TITLE: $KV_ID"
  fi

  if [[ ! -s "$ADMIN_FILE" ]]; then
    mkdir -p "$(dirname "$ADMIN_FILE")"
    (umask 077; openssl rand -base64 33 | tr '+/' '-_' | tr -d '=\n' >"$ADMIN_FILE")
    chmod 600 "$ADMIN_FILE"
    echo "admin key written to $ADMIN_FILE"
  fi
fi

[[ -n "$KV_ID" ]] || die "KV namespace $KV_TITLE is missing: run apply"
# Writes our KV id and the chosen host into wrangler.jsonc (neither is secret;
# commit the result so later deploys match).
node -e '
  const fs = require("fs");
  const [, kv, host] = process.argv;
  let s = fs.readFileSync("wrangler.jsonc", "utf8");
  s = s.replace(/"id": "[0-9a-f]{32}"/, `"id": "${kv}"`).replace(/"pattern": "[^"]+", "custom_domain": true/, `"pattern": "${host}", "custom_domain": true`);
  fs.writeFileSync("wrangler.jsonc", s);
' "$KV_ID" "$HOST"

wr deploy
if [[ "$mode" == apply ]]; then
  wr secret put ADMIN_KEY <"$ADMIN_FILE"
fi

echo "waiting for https://$HOST …"
for _ in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "https://$HOST/robots.txt" || true)
  [[ "$code" == 200 ]] && break
  sleep 5
done
node scripts/e2e.mjs "https://$HOST" --admin-key-file "$ADMIN_FILE"

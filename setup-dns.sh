#!/bin/bash
# Points tidygolf.app at GitHub Pages.
#
# Usage:
#   CF_API_TOKEN=your_token ./setup-dns.sh
#
# Create the token at: https://dash.cloudflare.com/profile/api-tokens
#   "Create Token" -> "Edit zone DNS" template
#   Zone Resources: Include -> Specific zone -> tidygolf.app
# That scopes it to DNS on this one domain and nothing else. Delete it when done.
set -euo pipefail

DOMAIN="tidygolf.app"
PAGES_HOST="ryanshim2000.github.io"
# GitHub Pages apex addresses (https://docs.github.com/pages/configuring-a-custom-domain)
GH_IPS=(185.199.108.153 185.199.109.153 185.199.110.153 185.199.111.153)

: "${CF_API_TOKEN:?Set CF_API_TOKEN first, e.g. CF_API_TOKEN=xxx ./setup-dns.sh}"

api() { curl -sS -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" "$@"; }

echo "==> Verifying token"
if ! api "https://api.cloudflare.com/client/v4/user/tokens/verify" | grep -q '"success":true'; then
  echo "Token rejected. Check it has Zone:DNS:Edit on $DOMAIN." >&2
  exit 1
fi

echo "==> Finding zone for $DOMAIN"
ZONE_ID=$(api "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
  | python3 -c 'import json,sys; r=json.load(sys.stdin)["result"]; print(r[0]["id"] if r else "")')
[ -n "$ZONE_ID" ] || { echo "Zone not found. Is $DOMAIN in this Cloudflare account?" >&2; exit 1; }
echo "    zone: $ZONE_ID"

# proxied=false is required: with Cloudflare's proxy on, GitHub cannot complete the
# domain-validation challenge and the HTTPS certificate never issues. .app is HSTS-preloaded,
# so without a certificate the site will not load at all.
create() {
  local type="$1" name="$2" content="$3"
  local existing
  existing=$(api "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=$type&name=$name" \
    | python3 -c 'import json,sys; r=json.load(sys.stdin)["result"]; print(" ".join(x["id"] for x in r))')
  for id in $existing; do
    local cur
    cur=$(api "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$id" \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["content"])')
    if [ "$cur" = "$content" ]; then echo "    exists: $type $name -> $content"; return 0; fi
  done
  api -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
    --data "{\"type\":\"$type\",\"name\":\"$name\",\"content\":\"$content\",\"ttl\":1,\"proxied\":false}" \
    | python3 -c '
import json,sys
d=json.load(sys.stdin)
if d.get("success"): print("    created:", d["result"]["type"], d["result"]["name"], "->", d["result"]["content"])
else: print("    FAILED:", [e.get("message") for e in d.get("errors",[])])'
}

echo "==> Creating apex A records"
for ip in "${GH_IPS[@]}"; do create A "$DOMAIN" "$ip"; done

echo "==> Creating www CNAME"
create CNAME "www.$DOMAIN" "$PAGES_HOST"

echo
echo "Done. DNS usually propagates in a few minutes."
echo "Delete the token now: https://dash.cloudflare.com/profile/api-tokens"

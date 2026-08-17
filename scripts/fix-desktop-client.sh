#!/usr/bin/env bash
#
# Fix the Nextcloud desktop sync client failing to connect to this stack.
#
#   ./scripts/fix-desktop-client.sh https://cloud.example.com [container]
#   ./scripts/fix-desktop-client.sh http://localhost:8080
#
# Pass the URL you type into the client, exactly as you type it. Almost
# every desktop-client failure against a containerised Nextcloud is a
# mismatch between that URL and what the server believes it is:
#
#   "Untrusted domain"            hostname missing from trusted_domains
#   login window opens localhost  overwrite.cli.url / overwritehost unset
#   login window opens http://    overwriteprotocol unset behind TLS
#   sync stalls, 404 on files     remote.php/dav not reachable as expected
#
# The script checks each one from outside (as the client sees it) and
# from inside via occ, repairs what it can, and prints the .env lines
# that make the repair survive a "docker compose down".
#
# Read-only run, changing nothing:
#
#   DRY_RUN=1 ./scripts/fix-desktop-client.sh https://cloud.example.com

set -euo pipefail

URL="${1:-}"
CONTAINER="${2:-nextcloud-app-1}"
WWW_UID=33
CURL_TIMEOUT="${CURL_TIMEOUT:-15}"
DRY_RUN="${DRY_RUN:-}"

if [ -z "$URL" ]; then
    echo "usage: $0 <server-url-as-typed-into-the-client> [container]" >&2
    echo "   eg: $0 https://cloud.example.com" >&2
    echo "       $0 http://localhost:8080" >&2
    exit 2
fi

# Trailing slashes make every path below double up.
URL="${URL%/}"

case "$URL" in
    http://*|https://*) ;;
    *)
        echo "error: URL must start with http:// or https:// - got: $URL" >&2
        exit 2 ;;
esac

SCHEME="${URL%%://*}"
HOSTPORT="${URL#*://}"
HOSTPORT="${HOSTPORT%%/*}"
HOST="${HOSTPORT%%:*}"

echo "==> Target"
printf '  url:    %s\n' "$URL"
printf '  host:   %s\n' "$HOST"
printf '  scheme: %s\n' "$SCHEME"
[ -n "$DRY_RUN" ] && echo "  mode:   DRY RUN, nothing will be changed"

# --- Outside the container: exactly what the client does ------------------

fetch() {
    # $1 method, $2 path. Body on stdout, HTTP code on the last line.
    curl -sS -m "$CURL_TIMEOUT" -X "$1" -w '\n%{http_code}' "$URL$2" 2>/dev/null || true
}

FAILED=0

echo
echo "==> Server reachability (status.php)"
STATUS_BODY="$(fetch GET /status.php)"
STATUS_CODE="$(printf '%s' "$STATUS_BODY" | tail -n1)"
STATUS_JSON="$(printf '%s' "$STATUS_BODY" | sed '$d')"

case "$STATUS_CODE" in
    200)
        printf '  HTTP 200: %s\n' "$STATUS_JSON"
        case "$STATUS_JSON" in
            *'"maintenance":true'*)
                echo "  MAINTENANCE MODE IS ON - the client cannot sync while it is."
                FAILED=1 ;;
        esac
        case "$STATUS_JSON" in
            *'"installed":false'*)
                echo "  NOT INSTALLED - finish the install first (see README.md)."
                FAILED=1 ;;
        esac ;;
    000|"")
        echo "  NO RESPONSE. The client cannot reach this URL at all."
        echo "  Check the reverse proxy, the port mapping, and TLS (a self-signed"
        echo "  certificate the client does not trust also lands here)."
        FAILED=1 ;;
    *)
        printf '  HTTP %s - unexpected. A 400 here usually means the hostname is\n' "$STATUS_CODE"
        printf '  not in trusted_domains.\n'
        FAILED=1 ;;
esac

echo
echo "==> WebDAV endpoint (remote.php/dav) - where sync actually happens"
# Reset rather than append on failure: curl writes its own "000" before
# exiting non-zero, and an appended fallback would print "000000".
DAV_CODE="$(curl -sS -o /dev/null -m "$CURL_TIMEOUT" -w '%{http_code}' "$URL/remote.php/dav/" 2>/dev/null)" || DAV_CODE="000"
case "$DAV_CODE" in
    401)
        echo "  HTTP 401 - correct. The endpoint exists and demands credentials." ;;
    200)
        echo "  HTTP 200 without credentials - unexpected, but not a client problem." ;;
    404)
        echo "  HTTP 404 - the endpoint is not being served. mod_rewrite or a"
        echo "  reverse-proxy path rule is swallowing /remote.php."
        FAILED=1 ;;
    30*)
        echo "  HTTP $DAV_CODE - a redirect here breaks sync. Usually a proxy"
        echo "  forcing HTTPS while overwriteprotocol is unset."
        FAILED=1 ;;
    *)
        echo "  HTTP $DAV_CODE - unexpected."
        FAILED=1 ;;
esac

echo
echo "==> Login Flow v2 (how the client gets its app password)"
LOGIN_BODY="$(fetch POST /index.php/login/v2)"
LOGIN_CODE="$(printf '%s' "$LOGIN_BODY" | tail -n1)"
LOGIN_JSON="$(printf '%s' "$LOGIN_BODY" | sed '$d')"

LOGIN_URL=""
if [ "$LOGIN_CODE" = "200" ]; then
    # {"poll":{...},"login":"https://host/index.php/login/flow/v2/..."}
    LOGIN_URL="$(printf '%s' "$LOGIN_JSON" \
        | sed -n 's/.*"login":"\([^"]*\)".*/\1/p' \
        | sed 's/\\\//\//g')"
fi

if [ -z "$LOGIN_URL" ]; then
    echo "  HTTP $LOGIN_CODE - no login URL returned. The client will fail at"
    echo "  the 'Log in' step. Check the reverse proxy forwards POST intact."
    FAILED=1
else
    printf '  server hands the client: %s\n' "$LOGIN_URL"
    LOGIN_HOSTPORT="${LOGIN_URL#*://}"; LOGIN_HOSTPORT="${LOGIN_HOSTPORT%%/*}"
    LOGIN_SCHEME="${LOGIN_URL%%://*}"
    if [ "$LOGIN_HOSTPORT" = "$HOSTPORT" ] && [ "$LOGIN_SCHEME" = "$SCHEME" ]; then
        echo "  matches the URL you typed - the browser will open the right page."
    else
        echo "  MISMATCH. The client opens a browser at ${LOGIN_SCHEME}://${LOGIN_HOSTPORT},"
        echo "  which is not the address you gave it. This is the classic"
        echo "  'login window opens localhost and hangs' failure."
        FAILED=1
        NEEDS_OVERWRITE=1
    fi
fi

# --- Inside the container: what the server believes about itself ----------

occ() {
    docker exec -u "$WWW_UID" "$CONTAINER" php occ "$@"
}

occ_get() {
    occ config:system:get "$1" 2>/dev/null || true
}

occ_set() {
    if [ -n "$DRY_RUN" ]; then
        echo "  would set: $*"
        return 0
    fi
    occ config:system:set "$@" >/dev/null
    echo "  set: $*"
}

HAVE_OCC=0
if command -v docker >/dev/null 2>&1 \
   && docker inspect "$CONTAINER" >/dev/null 2>&1 \
   && occ status >/dev/null 2>&1; then
    HAVE_OCC=1
fi

if [ "$HAVE_OCC" = "0" ]; then
    cat <<EOF

==> occ not available
Container "$CONTAINER" is not running here, or Nextcloud is not installed
in it. The checks above still hold - they are what the client sees - but
nothing can be repaired from this machine. Re-run it on the Docker host.
EOF
    [ "$FAILED" = "0" ] && exit 0
    exit 1
fi

echo
echo "==> trusted_domains"
DOMAINS="$(occ_get trusted_domains | tr '\n' ' ')"
printf '  current: %s\n' "${DOMAINS:-<none>}"
if printf ' %s ' "$DOMAINS" | grep -qF " $HOST "; then
    echo "  $HOST is present."
else
    echo "  $HOST is MISSING - the server answers 'Access through untrusted domain'."
    # Append; overwriting index 0 would drop localhost and lock out the
    # local healthcheck.
    NEXT=0
    for _ in $DOMAINS; do NEXT=$((NEXT + 1)); done
    occ_set trusted_domains "$NEXT" --value="$HOST"
    FIXED=1
fi

echo
echo "==> overwrite settings (what the server tells clients its address is)"
CLI_URL="$(occ_get overwrite.cli.url)"
OW_HOST="$(occ_get overwritehost)"
OW_PROTO="$(occ_get overwriteprotocol)"
printf '  overwrite.cli.url:  %s\n' "${CLI_URL:-<unset>}"
printf '  overwritehost:      %s\n' "${OW_HOST:-<unset>}"
printf '  overwriteprotocol:  %s\n' "${OW_PROTO:-<unset>}"

# All three, not just the URL: a half-configured server with the right
# overwrite.cli.url and the wrong overwriteprotocol still hands the
# client http:// links on an HTTPS site.
if [ "$CLI_URL" != "$URL" ] \
   || [ "$OW_HOST" != "$HOSTPORT" ] \
   || [ "$OW_PROTO" != "$SCHEME" ] \
   || [ -n "${NEEDS_OVERWRITE:-}" ]; then
    echo "  aligning them with $URL"
    occ_set overwrite.cli.url --value="$URL"
    occ_set overwritehost --value="$HOSTPORT"
    occ_set overwriteprotocol --value="$SCHEME"
    FIXED=1
else
    echo "  already aligned with $URL"
fi

# Without this, Nextcloud sees the proxy's IP as the client IP: rate
# limits and brute-force protection then throttle every user at once,
# which the desktop client reports as random login failures.
if [ "$SCHEME" = "https" ]; then
    echo
    echo "==> trusted_proxies (you are behind a reverse proxy)"
    PROXIES="$(occ_get trusted_proxies | tr '\n' ' ')"
    if [ -z "${PROXIES// /}" ]; then
        cat <<'EOF'
  UNSET. Nextcloud will attribute every request to the proxy's IP, so
  brute-force protection throttles all users at once - the client shows
  this as sporadic login failures. Set it to the proxy's address:

    docker compose exec -u www-data app php occ \
        config:system:set trusted_proxies 0 --value=172.18.0.0/16

  Not set automatically: only you know which address fronts this stack.
EOF
    else
        printf '  current: %s\n' "$PROXIES"
    fi
fi

echo
echo "==> Result"

if [ -n "${FIXED:-}" ] && [ -n "$DRY_RUN" ]; then
    echo "DRY RUN - nothing was changed. Re-run without DRY_RUN=1 to apply"
    echo "the settings listed above."
    exit 1
fi

if [ -n "${FIXED:-}" ] && [ -z "$DRY_RUN" ]; then
    cat <<EOF
Repaired. Re-run this script to confirm, then quit the desktop client
completely and reconnect - it caches the server's address between runs,
so a reload is not enough.

Make it survive "docker compose down" by adding to .env:

  NEXTCLOUD_TRUSTED_DOMAINS=localhost $HOST
  NEXTCLOUD_OVERWRITEHOST=$HOSTPORT
  NEXTCLOUD_OVERWRITEPROTOCOL=$SCHEME
  NEXTCLOUD_OVERWRITECLIURL=$URL

EOF
fi

if [ "$FAILED" = "0" ] && [ -z "${FIXED:-}" ]; then
    cat <<'EOF'
Everything the client depends on answers correctly: the server is
reachable, WebDAV demands auth, and Login Flow hands back a matching
address. If the client still fails, the cause is on its side:

  1. TLS. A self-signed or corporate-CA certificate is rejected outright
     by the client, with no prompt on some platforms. Import the CA into
     the OS trust store, not just the browser's.

  2. A stale account. Remove the account in the client and add it again -
     an app password revoked server-side leaves the client retrying
     silently.

  3. File size. A reverse proxy with a small body limit breaks large
     uploads only. If small files sync and big ones do not, raise
     client_max_body_size (nginx) or LimitRequestBody (Apache) on the
     proxy, and check PHP_UPLOAD_LIMIT in .env.

  4. Client log: Settings -> General -> Log settings, then reproduce.
EOF
    exit 0
fi

exit "${FAILED:-0}"

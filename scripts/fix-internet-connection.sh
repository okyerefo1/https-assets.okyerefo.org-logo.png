#!/usr/bin/env bash
#
# Fix "This server has no working internet connection: Multiple endpoints
# could not be reached." on the admin overview / setup checks page.
#
# The warning means the PHP process inside the container could not fetch
# the connectivity-check URLs. Three things break it, in this order of
# likelihood: DNS not resolving in the container, egress blocked without
# a proxy configured, or has_internet_connection deliberately set false.
#
#   ./scripts/fix-internet-connection.sh [container]
#
# Default container is "nextcloud-app-1" (compose project "nextcloud",
# service "app").
#
# To configure an outbound proxy while repairing:
#
#   PROXY=proxy.example.com:3128 ./scripts/fix-internet-connection.sh
#   PROXY=proxy.example.com:3128 PROXY_USERPWD=user:pass \
#       ./scripts/fix-internet-connection.sh
#
# PROXY_EXCLUDE is a space-separated list of hosts to bypass:
#
#   PROXY=proxy:3128 PROXY_EXCLUDE="db redis .internal" ./scripts/...
#
# Everything it changes is written with occ, so it survives restarts.

set -euo pipefail

CONTAINER="${1:-nextcloud-app-1}"
WWW_UID=33
CURL_TIMEOUT="${CURL_TIMEOUT:-10}"

# What Nextcloud itself checks when connectivity_check_domains is unset.
DEFAULT_DOMAINS="www.nextcloud.com www.startpage.com www.eff.org www.edri.org"

if ! command -v docker >/dev/null 2>&1; then
    echo "error: docker not found in PATH" >&2
    exit 1
fi

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    echo "error: no such container: $CONTAINER" >&2
    echo "running containers:" >&2
    docker ps --format '  {{.Names}}' >&2
    exit 1
fi

# occ must run as www-data (uid 33). Running it as root leaves
# root-owned files behind in config/ and data/.
occ() {
    docker exec -u "$WWW_UID" "$CONTAINER" php occ "$@"
}

# Reads back "" for an unset key instead of failing the script.
occ_get() {
    occ config:system:get "$1" 2>/dev/null || true
}

in_container() {
    docker exec "$CONTAINER" sh -c "$1"
}

if ! occ status >/dev/null 2>&1; then
    echo "error: occ is not usable in $CONTAINER" >&2
    echo "The container is still starting, or Nextcloud is not installed yet." >&2
    echo "Check: docker compose logs app" >&2
    exit 1
fi

echo "==> Current settings"
HAS_INTERNET="$(occ_get has_internet_connection)"
PROXY_NOW="$(occ_get proxy)"
printf '  has_internet_connection: %s\n' "${HAS_INTERNET:-<unset, defaults to true>}"
printf '  proxy:                   %s\n' "${PROXY_NOW:-<unset>}"

# Multi-line: one domain per line when set as a list.
DOMAINS="$(occ_get connectivity_check_domains | tr '\n' ' ' | tr -s ' ')"
if [ -z "${DOMAINS// /}" ]; then
    DOMAINS="$DEFAULT_DOMAINS"
    echo "  connectivity_check_domains: <unset, using Nextcloud defaults>"
else
    echo "  connectivity_check_domains: $DOMAINS"
fi

echo
echo "==> DNS inside the container"
in_container 'cat /etc/resolv.conf' | sed 's/^/  /'

DNS_OK=1
for domain in $DOMAINS; do
    if in_container "getent hosts $domain" >/dev/null 2>&1; then
        printf '  ok      %s\n' "$domain"
    else
        printf '  FAILED  %s (does not resolve)\n' "$domain"
        DNS_OK=0
    fi
done

# Applying the proxy before the egress test, so the test measures the
# configuration we are actually leaving behind.
if [ -n "${PROXY:-}" ]; then
    echo
    echo "==> Configuring proxy: $PROXY"
    occ config:system:set proxy --value="$PROXY"
    if [ -n "${PROXY_USERPWD:-}" ]; then
        occ config:system:set proxyuserpwd --value="$PROXY_USERPWD"
        echo "  proxyuserpwd set"
    fi
    if [ -n "${PROXY_EXCLUDE:-}" ]; then
        i=0
        for host in $PROXY_EXCLUDE; do
            occ config:system:set proxyexclude "$i" --value="$host"
            i=$((i + 1))
        done
        echo "  proxyexclude set: $PROXY_EXCLUDE"
    fi
    PROXY_NOW="$PROXY"
fi

# curl needs the proxy passed explicitly - it reads http_proxy from the
# environment, and PHP reads it from config.php. Those are separate.
CURL_ARGS="-sS -o /dev/null -m $CURL_TIMEOUT -w '%{http_code}'"
if [ -n "$PROXY_NOW" ]; then
    if [ -n "${PROXY_USERPWD:-}" ]; then
        CURL_ARGS="$CURL_ARGS -x http://${PROXY_USERPWD}@${PROXY_NOW}"
    else
        CURL_ARGS="$CURL_ARGS -x http://${PROXY_NOW}"
    fi
fi

echo
echo "==> HTTPS egress from the container${PROXY_NOW:+ (via $PROXY_NOW)}"
EGRESS_OK=1
for domain in $DOMAINS; do
    code="$(in_container "curl $CURL_ARGS https://$domain/" 2>/dev/null || echo "---")"
    case "$code" in
        2*|3*) printf '  ok      %-22s HTTP %s\n' "$domain" "$code" ;;
        ---)   printf '  FAILED  %-22s no response\n' "$domain"; EGRESS_OK=0 ;;
        *)     printf '  FAILED  %-22s HTTP %s\n' "$domain" "$code"; EGRESS_OK=0 ;;
    esac
done

# A false here suppresses the warning but also kills the app store and
# update checks, so it is only ever correct on a deliberately air-gapped
# instance. If the network works, put it back.
if [ "$HAS_INTERNET" = "false" ]; then
    echo
    if [ "$EGRESS_OK" = "1" ]; then
        echo "==> has_internet_connection was false but the network works - re-enabling"
        occ config:system:set has_internet_connection --type=boolean --value=true
    else
        echo "==> has_internet_connection is false (app store and update checks disabled)"
        echo "    Leaving it alone: egress is failing, so the setting matches reality."
    fi
fi

echo
echo "==> Result"
if [ "$DNS_OK" = "1" ] && [ "$EGRESS_OK" = "1" ]; then
    cat <<EOF
OK - the container resolves and reaches every check domain.

Reload the admin overview page to clear the warning. If it persists,
the cached setup check is stale:

  docker exec -u $WWW_UID $CONTAINER php occ setupchecks
EOF
    exit 0
fi

if [ "$DNS_OK" = "0" ]; then
    cat >&2 <<'EOF'
DNS IS BROKEN IN THE CONTAINER. Fix this first - egress cannot work
without it. Check, in this order:

  1. Docker's embedded resolver. /etc/resolv.conf above should show
     nameserver 127.0.0.11 on a user-defined network. If it shows a
     host nameserver the container cannot reach, pin a working one:

       # docker-compose.yml, under services.app and services.cron
       dns:
         - 1.1.1.1
         - 9.9.9.9

  2. The host's own resolver. The embedded resolver forwards to
     whatever the host uses:

       getent hosts www.nextcloud.com     # on the host

     A host running systemd-resolved with a stub at 127.0.0.53 is the
     usual culprit - containers cannot reach that address.

  3. A VPN or split-DNS setup on the host that the docker bridge
     network is not routed through.
EOF
fi

# Only when DNS is fine - otherwise the failed fetches are a symptom of
# the resolver, and this ladder sends you chasing the wrong cause.
if [ "$EGRESS_OK" = "0" ] && [ "$DNS_OK" = "1" ]; then
    cat >&2 <<'EOF'
EGRESS IS BLOCKED. Names resolve, but the check domains do not answer.
Check, in this order:

  1. An outbound proxy you have not told Nextcloud about. PHP does not
     read http_proxy from the environment - it needs config.php:

       PROXY=proxy.example.com:3128 ./scripts/fix-internet-connection.sh

  2. A host firewall or egress policy blocking the docker bridge:

       sudo iptables -L DOCKER-USER -n -v

  3. TLS interception. A corporate CA that the container does not
     trust makes curl fail with certificate errors - mount the CA into
     /usr/local/share/ca-certificates/ and run update-ca-certificates.

  4. A genuinely air-gapped host. Then the warning is correct, and the
     honest fix is to stop checking:

       docker exec -u 33 CONTAINER php occ config:system:set \
           has_internet_connection --type=boolean --value=false
EOF
fi

exit 1

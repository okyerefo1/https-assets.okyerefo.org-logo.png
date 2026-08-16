#!/usr/bin/env bash
#
# Fix "Cannot create or write into the data directory /var/www/html/data".
#
# The Nextcloud installer runs as www-data (uid/gid 33). That error means
# uid 33 cannot write the data directory. This script repairs ownership
# from inside the container, which also covers a bind-mounted host path
# because the mapping follows host ownership.
#
#   ./scripts/fix-data-permissions.sh [container]
#
# Default container is "nextcloud-app-1" (compose project "nextcloud",
# service "app"). Re-run the installer afterwards.

set -euo pipefail

CONTAINER="${1:-nextcloud-app-1}"
DATA_DIR="${DATA_DIR:-/var/www/html/data}"
WWW_UID=33

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

echo "==> Before"
docker exec "$CONTAINER" ls -ldn "$DATA_DIR" 2>/dev/null || echo "  $DATA_DIR does not exist yet"

echo "==> Repairing ownership to ${WWW_UID}:${WWW_UID}"
docker exec -u 0 "$CONTAINER" sh -c "
    mkdir -p '$DATA_DIR' &&
    chown -R ${WWW_UID}:${WWW_UID} '$DATA_DIR' &&
    chmod 750 '$DATA_DIR'
"

echo "==> After"
docker exec "$CONTAINER" ls -ldn "$DATA_DIR"

echo "==> Verifying www-data can actually write"
if docker exec -u "$WWW_UID" "$CONTAINER" \
       sh -c "touch '$DATA_DIR/.write-test' && rm -f '$DATA_DIR/.write-test'"; then
    echo "OK - www-data can write to $DATA_DIR. Re-run the installer."
else
    cat >&2 <<'EOF'

STILL FAILING. Ownership is correct, so something above the filesystem
is blocking the write. Check, in this order:

  1. SELinux (Fedora/RHEL/Rocky). `getenforce` says Enforcing?
     Add ":z" to the volume in compose, or:
       sudo chcon -Rt httpd_sys_rw_content_t ./data

  2. Read-only mount. Look for the data path in:
       grep ' ro,' /proc/mounts

  3. Disk full. `df -h` on the host - a full disk reports as a
     permission error here.

  4. AppArmor / a hardened container runtime denying the write.
EOF
    exit 1
fi

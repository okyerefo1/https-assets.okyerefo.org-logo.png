# Nextcloud autoconfig setup

Docker Compose stack for Nextcloud with unattended (autoconfig) install —
MariaDB by default, PostgreSQL as an alternative, Redis for file locking,
and a cron container for background jobs.

Built to avoid the failure this repo was created for:

> Cannot create or write into the data directory `/var/www/html/data`

## Quick start

```bash
cp .env.example .env
# fill in every empty value; generate each with: openssl rand -base64 32
$EDITOR .env

docker compose up -d
docker compose logs -f app     # watch the unattended install run
```

Then open <http://localhost:8080> and log in with `NEXTCLOUD_ADMIN_USER` /
`NEXTCLOUD_ADMIN_PASSWORD`. You should never see the setup form — if you
do, the install did not complete; check `docker compose logs app`.

For PostgreSQL instead of MariaDB:

```bash
docker compose -f docker-compose.postgres.yml up -d
```

Choose the engine **before** the first install. Nextcloud writes it into
`config/config.php` during setup, and changing it afterwards is a data
migration, not a compose edit.

## About the autoconfig file

The "Autoconfig file detected" banner is normal and means things are
working. The official image's entrypoint reads the `MYSQL_*` /
`POSTGRES_*` / `NEXTCLOUD_ADMIN_*` environment variables and writes
`config/autoconfig.php` for you before Apache starts. Nextcloud then
consumes that file and **deletes it** once setup succeeds.

So:

| What you see | What it means |
|---|---|
| Banner, then the form, pre-filled | Autoconfig was read; something else is blocking the install |
| No banner, empty form | Env vars are not reaching the container — check `.env` and `docker compose config` |
| No form at all, straight to login | Install completed. This is the goal |
| `autoconfig.php` still present after setup | Install did not finish |

`config/autoconfig.php.example` is a hand-written template for installs
outside Docker, or for keys the env vars don't cover. You don't need it
for the normal path here.

## The data directory error

The installer runs as `www-data` (**uid/gid 33**). The error means uid 33
cannot write `/var/www/html/data`.

This stack uses **named volumes**, and the image's entrypoint chowns those
to uid 33 on first start — which is precisely why the error doesn't occur
here. It shows up when a **bind mount** is used instead: a host directory
carries its host ownership into the container, so `./data` owned by root
or by your login user arrives as unwritable.

Repair it with:

```bash
./scripts/fix-data-permissions.sh            # default: nextcloud-app-1
./scripts/fix-data-permissions.sh my-container
```

The script chowns the directory, then verifies uid 33 can genuinely write
there rather than assuming the chown was sufficient.

If you deliberately want a bind mount (backups are simpler), fix it on the
host as well — the container mapping follows host ownership:

```bash
sudo mkdir -p ./data
sudo chown -R 33:33 ./data
sudo chmod 750 ./data
```

### When ownership is already correct

| Cause | Check | Fix |
|---|---|---|
| SELinux (Fedora/RHEL/Rocky) | `getenforce` → `Enforcing` | add `:z` to the volume, or `sudo chcon -Rt httpd_sys_rw_content_t ./data` |
| Read-only mount | `grep ' ro,' /proc/mounts` | drop `:ro` from the compose volume |
| Disk full | `df -h` | free space — a full disk surfaces as a permission error |
| AppArmor / hardened runtime | `dmesg \| grep -i denied` | adjust the profile |

## The internet connectivity warning

> This server has no working internet connection: Multiple endpoints could
> not be reached.

Admin → Overview raises this when PHP inside the `app` container cannot
fetch the connectivity-check URLs (`www.nextcloud.com`, `www.startpage.com`,
`www.eff.org`, `www.edri.org` by default). It is a container-level problem
even when the host browses the web fine — the check runs from inside.

Diagnose and repair it with:

```bash
./scripts/fix-internet-connection.sh            # default: nextcloud-app-1
./scripts/fix-internet-connection.sh my-container
```

It reports DNS and HTTPS egress per check domain, re-enables
`has_internet_connection` if it was switched off while the network in fact
works, and prints an ordered list of causes when something is still
blocked. Behind a proxy:

```bash
PROXY=proxy.example.com:3128 ./scripts/fix-internet-connection.sh
PROXY=proxy.example.com:3128 PROXY_USERPWD=user:pass \
    ./scripts/fix-internet-connection.sh
```

The three causes, in the order they actually occur:

| Cause | Check | Fix |
|---|---|---|
| DNS not resolving in the container | `docker compose exec app getent hosts www.nextcloud.com` | uncomment the `dns:` block in compose (`1.1.1.1`) — a host resolver on `127.0.0.53` is unreachable from containers |
| Proxy required but not configured | `docker compose exec app curl -sSI https://www.nextcloud.com` hangs | `PROXY=host:port ./scripts/fix-internet-connection.sh` |
| Egress blocked at the host | `sudo iptables -L DOCKER-USER -n -v` | allow the bridge network out |

`NEXTCLOUD_HTTP_PROXY` / `NEXTCLOUD_HTTPS_PROXY` / `NEXTCLOUD_NO_PROXY` in
`.env` reach the container's shell tools only. (They carry that prefix on
purpose: compose lets the *shell* environment override `.env`, so naming
them `HTTP_PROXY` would let a proxy exported on the host — commonly one
bound to `127.0.0.1`, which no container can reach — silently win.)

**PHP does not read them** — Nextcloud takes its proxy
from the `proxy` and `proxyuserpwd` keys in `config.php`, which is what the
script writes via `occ`. Setting one without the other is why a proxy often
appears half-working: `curl` succeeds inside the container while the admin
page still reports no connection.

On a deliberately air-gapped instance the warning is correct, and the
honest fix is to stop checking — accepting that this also disables the app
store and update notifications:

```bash
docker compose exec -u www-data app php occ \
    config:system:set has_internet_connection --type=boolean --value=false
```

## The desktop client can't connect

Nearly every desktop-sync failure against a containerised Nextcloud is a
mismatch between the URL you type into the client and the address the
server believes it has. Point the script at the URL exactly as you type
it into the client:

```bash
./scripts/fix-desktop-client.sh https://cloud.example.com
./scripts/fix-desktop-client.sh http://localhost:8080
DRY_RUN=1 ./scripts/fix-desktop-client.sh https://cloud.example.com   # check only
```

It probes what the client probes — `status.php`, `remote.php/dav`, and the
Login Flow v2 endpoint — then compares the answers against `occ`, adds the
missing trusted domain, aligns the overwrite settings, and prints the
`.env` lines that keep the repair across a `docker compose down`.

| Symptom | Cause | Fix |
|---|---|---|
| "Access through untrusted domain" | hostname not in `trusted_domains` | add it to `NEXTCLOUD_TRUSTED_DOMAINS` |
| Login window opens `localhost:8080` and hangs | `overwritehost` / `overwrite.cli.url` unset behind a proxy | set `NEXTCLOUD_OVERWRITE*` |
| Login window opens `http://` on an HTTPS site | `overwriteprotocol` unset | `NEXTCLOUD_OVERWRITEPROTOCOL=https` |
| Sporadic login failures for everyone at once | `trusted_proxies` unset, so brute-force protection counts every user as one IP | `NEXTCLOUD_TRUSTED_PROXIES=<proxy address>` |
| Connects, then sync 404s | `/remote.php` not reaching Apache | fix the proxy path rules |
| Small files sync, large ones fail | proxy body limit | raise `client_max_body_size` / `LimitRequestBody`, check `PHP_UPLOAD_LIMIT` |

The overwrite settings belong in `.env`, not only in `config.php`: the
image applies them on every start, so they survive `docker compose down`.
Setting them through `occ` alone works until the volume is recreated.

A self-signed certificate is worth calling out separately — the desktop
client rejects it outright, on some platforms with no prompt at all. The
CA has to be in the OS trust store, not just the browser's.

## Database host

`db` on its own is correct — it's the compose service name, resolved on
the internal network. The installer's *"specify the port number along with
the host name (e.g. localhost:5432)"* hint is generic advice, not a
requirement. Only write `db:5432` or `db:3306` if you remapped the port
off its default.

If you selected PostgreSQL in the form while running MariaDB, the install
fails immediately after the permission error clears. The database type has
to match the container you're actually running.

## Layout

```
docker-compose.yml             MariaDB + Redis + app + cron (default)
docker-compose.postgres.yml    PostgreSQL variant, use instead of the above
.env.example                   template for .env (gitignored)
config/autoconfig.php.example  manual template for non-Docker installs
scripts/fix-data-permissions.sh
scripts/fix-internet-connection.sh
scripts/fix-desktop-client.sh
```

## Operations

```bash
docker compose exec -u www-data app php occ status
docker compose exec -u www-data app php occ maintenance:mode --on
docker compose logs -f app
docker compose down            # keeps volumes
docker compose down -v         # DELETES all data
```

## Notes

- `.env` is gitignored, as is a rendered `config/autoconfig.php`, since
  both hold live credentials. Only `.env.example` is tracked.
- Images are pinned to `nextcloud:stable-apache` and `mariadb:11.4`. Pin
  to an exact Nextcloud major before running this in production — Nextcloud
  does not support skipping major versions on upgrade.
- There is no TLS here. Put a reverse proxy in front for anything
  internet-facing, and add that hostname to `NEXTCLOUD_TRUSTED_DOMAINS`.

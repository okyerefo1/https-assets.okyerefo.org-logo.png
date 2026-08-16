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

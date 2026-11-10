#!/bin/bash
# First-boot setup for Frappe HR (ERPNext + HRMS) on Railway, then hand the container to honcho.
#
# Runs as root only long enough to fix the volume's ownership; every bench
# process is started as frappe (uid 1000) at the end.
set -euo pipefail

BENCH=/home/frappe/frappe-bench
SITES="$BENCH/sites"
SITE="${SITE_NAME:-hr}"
SEED=/home/frappe/bench-seed

log() { echo "railway-entrypoint: $*"; }
as_frappe() { setpriv --reuid=frappe --regid=frappe --init-groups --inh-caps=-all env HOME=/home/frappe "$@"; }

require() {
    if [ -z "${!1:-}" ]; then
        echo "railway-entrypoint: ERROR: $1 is not set" >&2
        exit 1
    fi
}

require DB_HOST
require DB_ROOT_PASSWORD
require ADMIN_PASSWORD
require FRAPPE_API_KEY
require FRAPPE_API_SECRET

# --- the volume ------------------------------------------------------------
# Railway mounts volumes owned by uid 0. Everything here runs as frappe.
log "preparing $SITES"
chown -R frappe:frappe "$SITES"
# bench treats every directory under sites/ as a site; lost+found is not one.
rm -rf "$SITES/lost+found"

# --- what the volume hides -------------------------------------------------
# apps.txt / apps.json are baked into sites/ by the image and disappear behind
# the mount on first boot. assets/ is a symlink to the built assets at the bench
# root, refreshed on every boot so an image upgrade ships its new assets.
for f in apps.txt apps.json; do
    if [ ! -f "$SITES/$f" ]; then
        log "restoring $f"
        install -o frappe -g frappe -m 644 "$SEED/$f" "$SITES/$f"
    fi
done
rm -rf "$SITES/assets"
ln -s "$BENCH/assets" "$SITES/assets"
chown -h frappe:frappe "$SITES/assets"

mkdir -p "$SITES/redis"
chown frappe:frappe "$SITES/redis"

# --- common_site_config.json ----------------------------------------------
# Regenerated from the environment on every boot: it holds only the wiring
# (database host, redis URLs), never anything the user edits. Per-site settings
# live in sites/$SITE/site_config.json and are left alone.
log "writing common_site_config.json (db_host=$DB_HOST, site=$SITE)"
as_frappe python - "$SITES/common_site_config.json" <<'PY'
import json, os, sys

path = sys.argv[1]
try:
    with open(path) as fh:
        conf = json.load(fh)
except (OSError, ValueError):
    conf = {}

redis = os.environ.get("REDIS_URL", "redis://127.0.0.1:6379")
conf.update({
    "db_host": os.environ["DB_HOST"],
    "db_port": int(os.environ.get("DB_PORT", "3306")),
    # One redis instance, three logical databases. frappe clears the cache with
    # a keyspace scan rather than FLUSHALL, but separate db indexes keep queued
    # jobs safe from anything that ever changes its mind about that.
    "redis_cache": f"{redis}/0",
    "redis_queue": f"{redis}/1",
    "redis_socketio": f"{redis}/1",
    "socketio_port": 9000,
    # Any Host header that does not match a site directory falls back to this
    # one, which is what makes a custom domain work without re-creating the site.
    "default_site": os.environ.get("SITE_NAME", "hr"),
    "serve_default_site": True,
    "developer_mode": 0,
    "maintenance_mode": 0,
    "restart_supervisor_on_update": 0,
    "restart_systemd_on_update": 0,
})

with open(path, "w") as fh:
    json.dump(conf, fh, indent=1, sort_keys=True)
PY

# --- redis, for the setup step only ---------------------------------------
# bench new-site talks to the cache. honcho owns the long-lived redis; this one
# exists for the length of the site creation and is shut down again below.
start_setup_redis() {
    log "starting redis for setup"
    as_frappe redis-server --port 6379 --dir "$SITES/redis" --save '' --daemonize yes
    for _ in $(seq 1 30); do
        if as_frappe redis-cli ping >/dev/null 2>&1; then return 0; fi
        sleep 1
    done
    echo "railway-entrypoint: ERROR: setup redis did not come up" >&2
    exit 1
}

# --- the site --------------------------------------------------------------
if [ -f "$SITES/$SITE/site_config.json" ]; then
    log "site '$SITE' already exists, skipping creation"
else
    log "creating site '$SITE' with erpnext and hrms (first boot; this takes a few minutes)"
    start_setup_redis

    # Wait for MariaDB: on a fresh Railway project both services start together
    # and the database initialises its data directory first.
    for _ in $(seq 1 120); do
        if as_frappe mariadb -h "$DB_HOST" -P "${DB_PORT:-3306}" \
             -u "${DB_ROOT_USER:-root}" -p"$DB_ROOT_PASSWORD" -e 'SELECT 1' >/dev/null 2>&1; then
            log "database is up"
            break
        fi
        sleep 2
    done

    # --mariadb-user-host-login-scope=% : the site's database user is created on
    # the MariaDB server and connects from a different container, so it cannot be
    # scoped to localhost.
    #
    # --force : reaching this branch means sites/$SITE/site_config.json does not
    # exist, so this deploy has no working site. If an earlier attempt was killed
    # after it had created the database (a healthcheck timeout during the five
    # minutes this takes will do it), a plain new-site fails with "database
    # already exists" and the container crash-loops forever. --force makes the
    # retry recover instead. It only ever runs when there is no site to lose.
    as_frappe env HOME=/home/frappe sh -c "cd '$BENCH' && bench new-site '$SITE' \
        --db-root-username '${DB_ROOT_USER:-root}' \
        --db-root-password '$DB_ROOT_PASSWORD' \
        --admin-password '$ADMIN_PASSWORD' \
        --mariadb-user-host-login-scope='%' \
        --install-app erpnext \
        --install-app hrms \
        --force \
        --set-default"

    log "enabling the scheduler"
    as_frappe env HOME=/home/frappe sh -c "cd '$BENCH' && bench --site '$SITE' enable-scheduler" || true

    as_frappe redis-cli shutdown nosave >/dev/null 2>&1 || true
    log "site created"
fi

# --- API credentials -------------------------------------------------------
# Administrator gets the key pair from the environment on every boot, so a client
# can authenticate with `Authorization: token KEY:SECRET` from the first request
# and the pair survives redeploys. Changing the variables rotates it.
log "setting the Administrator API key"
start_setup_redis
as_frappe env HOME=/home/frappe SITES_PATH="$SITES" SITE="$SITE" \
    "$BENCH/env/bin/python" - <<'PYEOF'
import os
import frappe

frappe.init(site=os.environ["SITE"], sites_path=os.environ["SITES_PATH"])
frappe.connect()
user = frappe.get_doc("User", "Administrator")
user.api_key = os.environ["FRAPPE_API_KEY"]
user.api_secret = os.environ["FRAPPE_API_SECRET"]
user.flags.ignore_permissions = True
user.save()
frappe.db.commit()
frappe.destroy()
PYEOF
as_frappe redis-cli shutdown nosave >/dev/null 2>&1 || true

# --- run -------------------------------------------------------------------
log "starting bench (nginx on ${PORT:-8080}, ${GUNICORN_WORKERS:-2} gunicorn workers)"
# honcho hands each Procfile process its own PORT (base, then +100 per process
# type), so nginx cannot read the deploy's real port from $PORT.
export NGINX_PORT="${PORT:-8080}"
exec setpriv --reuid=frappe --regid=frappe --init-groups --inh-caps=-all \
    env HOME=/home/frappe NGINX_PORT="$NGINX_PORT" \
    honcho --app-root "$BENCH" -f "$BENCH/Procfile.railway" start

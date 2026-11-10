# Railway-tuned Frappe HR: ERPNext + the HRMS app (payroll, leave, attendance,
# recruitment, expense claims) in one container, plus MariaDB as the second service.
#
# Base: ghcr.io/frappe/hrms, which carries frappe, erpnext, payments and hrms already
# built (apps/ checked out on the version-15 branches, assets compiled). Measured on
# 2026-11-11: the v15.64.8 tag holds frappe 15.126.0, erpnext 15.124.5 and hrms 15.64.8.
# The tags named v16.x on that package hold the same version-15 content, so the version
# here is pinned by image digest, not by a tag name.
#
# What this changes against running upstream's compose file on Railway:
#
#  1. One container runs the whole bench (nginx + gunicorn + socketio + worker +
#     scheduler + redis) under honcho. Railway volumes cannot be shared between
#     services, and frappe's web, worker and scheduler all need the same `sites/`
#     directory, so upstream's six-container split is not available. Bundling redis
#     takes the stack from four always-on services to two.
#  2. The site is created on first boot under a FIXED name and nginx passes that name
#     as X-Frappe-Site-Name, so it resolves whatever host the request arrives on.
#  3. Administrator gets an API key pair from the environment, so an agent can
#     authenticate with a token header and no browser login.
FROM ghcr.io/frappe/hrms:v15.64.8@sha256:e5c78b6d70eb5916408981aec7cd7474bb2de3b6e749ca6fa95f4a293c31ad1b

USER root

# The only package upstream does not already carry.
RUN apt-get update -qq \
    && apt-get install -y -q --no-install-recommends redis-server \
    && apt-get clean -y \
    && rm -rf /var/lib/apt/lists/*

# nginx writes its pid to /run, which is root-owned, and every process here runs as frappe.
RUN sed -i 's|^pid .*|pid /tmp/nginx.pid;|' /etc/nginx/nginx.conf

# A Railway volume mounts over sites/, hiding the apps.txt and apps.json the image
# bakes there. Keep a copy outside the mount for the entrypoint to restore.
RUN mkdir -p /home/frappe/bench-seed \
    && cp /home/frappe/frappe-bench/sites/apps.txt \
          /home/frappe/frappe-bench/sites/apps.json \
          /home/frappe/bench-seed/ \
    && chown -R frappe:root /home/frappe/bench-seed

COPY --chown=frappe:root Procfile /home/frappe/frappe-bench/Procfile.railway
COPY railway-nginx.sh /usr/local/bin/railway-nginx.sh
COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
RUN chmod +x /usr/local/bin/railway-nginx.sh /usr/local/bin/railway-entrypoint.sh

# Baked so the published deploy form stays empty: templateGenerate keeps a variable
# default only when the live value is a Railway expression.
ENV SITE_NAME=hr \
    PORT=8080 \
    BACKEND=127.0.0.1:8000 \
    SOCKETIO=127.0.0.1:9000 \
    FRAPPE_SITE_NAME_HEADER=hr \
    DB_PORT=3306 \
    DB_ROOT_USER=root \
    REDIS_URL=redis://127.0.0.1:6379 \
    GUNICORN_WORKERS=2 \
    GUNICORN_THREADS=4 \
    FRAPPE_WORKER_QUEUES=short,default,long \
    ADMIN_USER=Administrator

EXPOSE 8080

# A Railway start command REPLACES the image ENTRYPOINT, so the template that uses
# this image must set NO start command.
ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]

#!/bin/bash
# Render frappe's own nginx template and serve on Railway's port.
#
# This is upstream's /usr/local/bin/nginx-entrypoint.sh with two changes: the
# listen port follows $PORT, and FRAPPE_SITE_NAME_HEADER defaults to the fixed
# site name rather than $host, so a request arriving on a custom domain still
# resolves to the site that was created on first boot.
set -euo pipefail

export BACKEND="${BACKEND:-127.0.0.1:8000}"
export SOCKETIO="${SOCKETIO:-127.0.0.1:9000}"
export UPSTREAM_REAL_IP_ADDRESS="${UPSTREAM_REAL_IP_ADDRESS:-127.0.0.1}"
export UPSTREAM_REAL_IP_HEADER="${UPSTREAM_REAL_IP_HEADER:-X-Forwarded-For}"
export UPSTREAM_REAL_IP_RECURSIVE="${UPSTREAM_REAL_IP_RECURSIVE:-off}"
export FRAPPE_SITE_NAME_HEADER="${FRAPPE_SITE_NAME_HEADER:-${SITE_NAME:-hr}}"
export PROXY_READ_TIMEOUT="${PROXY_READ_TIMEOUT:-120}"
export CLIENT_MAX_BODY_SIZE="${CLIENT_MAX_BODY_SIZE:-50m}"
# The version-15 template listens on ${NGINX_LISTEN_PORT} (the erpnext v16 one
# hard-codes 8080). NGINX_PORT, not PORT: honcho hands every Procfile process its
# own PORT (base, then +100 per process type), so nginx, sixth in the Procfile,
# would read 8580. The entrypoint exports the deploy's real port as NGINX_PORT.
export NGINX_LISTEN_PORT="${NGINX_PORT:-${PORT:-8080}}"

envsubst '${BACKEND}
  ${SOCKETIO}
  ${NGINX_LISTEN_PORT}
  ${UPSTREAM_REAL_IP_ADDRESS}
  ${UPSTREAM_REAL_IP_HEADER}
  ${UPSTREAM_REAL_IP_RECURSIVE}
  ${FRAPPE_SITE_NAME_HEADER}
  ${PROXY_READ_TIMEOUT}
  ${CLIENT_MAX_BODY_SIZE}' \
  </templates/nginx/frappe.conf.template >/etc/nginx/conf.d/frappe.conf

# Single server block, so it is also the default server -- any Host reaches it.
exec nginx -g 'daemon off;'

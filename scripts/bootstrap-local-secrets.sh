#!/usr/bin/env bash
# Локальные секреты для docker compose. В git не попадают (см. .gitignore).
# Пароли печатаются только путём к файлу. Повторный запуск не ротирует их:
# Grafana читает GF_SECURITY_ADMIN_PASSWORD лишь при создании базы.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${MONITORING_SECRETS_DIR:-${ROOT}/docker/secrets}"
FORCE=0

if [[ "${1:-}" == "--force" ]]; then
  FORCE=1
elif [[ -n "${1:-}" ]]; then
  echo "usage: bootstrap-local-secrets.sh [--force]" >&2
  exit 2
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "[ERROR] нужен openssl" >&2
  exit 1
fi

if [[ "${FORCE}" -eq 0 && -f "${DEST}/compose.env" ]]; then
  echo "[OK] секреты уже есть: ${DEST} (см. --force, он ломает уже инициализированный пароль Grafana)"
  exit 0
fi

umask 077
mkdir -p "${DEST}/tls"

grafana_password="$(openssl rand -base64 24 | tr -d '\n')"
nginx_password="$(openssl rand -base64 24 | tr -d '\n')"
salt="$(openssl rand -hex 4 | tr -d '\n')"
htpasswd_hash="$(printf '%s' "${nginx_password}" | openssl passwd -apr1 -salt "${salt}" -stdin)"

printf '%s\n' "${grafana_password}" > "${DEST}/grafana_admin_password"
printf '%s\n' "${nginx_password}" > "${DEST}/nginx_basic_auth_password"
printf '%s\n' "${salt}" > "${DEST}/htpasswd.salt"
printf 'monitoring:%s\n' "${htpasswd_hash}" > "${DEST}/htpasswd"
chmod 0600 \
  "${DEST}/grafana_admin_password" \
  "${DEST}/nginx_basic_auth_password" \
  "${DEST}/htpasswd.salt" \
  "${DEST}/htpasswd"

openssl req -x509 -nodes -newkey ec \
  -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout "${DEST}/tls/server.key" \
  -out "${DEST}/tls/server.crt" \
  -days 90 \
  -subj '/CN=monitoring.example' \
  -addext 'subjectAltName=DNS:monitoring.example,DNS:localhost,IP:127.0.0.1' \
  >/dev/null 2>&1
chmod 0600 "${DEST}/tls/server.key"
chmod 0644 "${DEST}/tls/server.crt"

cat > "${DEST}/compose.env" <<EOF
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=${grafana_password}
GRAFANA_ROOT_URL=https://127.0.0.1:8443
MONITORING_BIND_IP=127.0.0.1
MONITORING_GRAFANA_PORT=8443
MONITORING_PROMETHEUS_PORT=8444
MONITORING_ALERTMANAGER_PORT=8445
NODE_EXPORTER_TEXTFILE_DIR=/var/lib/node_exporter/textfile
NGINX_UID=$(id -u)
NGINX_GID=$(id -g)
EOF
chmod 0600 "${DEST}/compose.env"

echo "[OK] секреты записаны в ${DEST}"
echo "Grafana user: admin"
echo "Grafana password file: ${DEST}/grafana_admin_password"
echo "nginx basic auth user: monitoring"
echo "nginx password file: ${DEST}/nginx_basic_auth_password"
echo "Дальше: docker compose --env-file ${DEST}/compose.env -f ${ROOT}/docker/compose.yaml up -d"

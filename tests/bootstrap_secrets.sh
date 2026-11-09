#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

MONITORING_SECRETS_DIR="${WORK}" bash "${ROOT}/scripts/bootstrap-local-secrets.sh"

[[ "$(stat -c '%a' "${WORK}/grafana_admin_password")" == "600" ]]
[[ "$(stat -c '%a' "${WORK}/nginx_basic_auth_password")" == "600" ]]
[[ "$(stat -c '%a' "${WORK}/compose.env")" == "600" ]]
[[ "$(stat -c '%a' "${WORK}/tls/server.key")" == "600" ]]
# shellcheck disable=SC2016
grep -q '^monitoring:\$6\$' "${WORK}/proxy/htpasswd"
openssl x509 -in "${WORK}/tls/server.crt" -noout -subject | grep -q 'monitoring.example'
grep -q '^GRAFANA_ADMIN_PASSWORD=.' "${WORK}/compose.env"

# Повторный запуск не переписывает пароль.
before="$(cat "${WORK}/grafana_admin_password")"
MONITORING_SECRETS_DIR="${WORK}" bash "${ROOT}/scripts/bootstrap-local-secrets.sh"
after="$(cat "${WORK}/grafana_admin_password")"
[[ "${before}" == "${after}" ]]

git -C "${ROOT}" check-ignore -q -- docker/secrets/grafana_admin_password
git -C "${ROOT}" check-ignore -q -- ansible/group_vars/all/vault.yml

echo "[OK] bootstrap секретов"

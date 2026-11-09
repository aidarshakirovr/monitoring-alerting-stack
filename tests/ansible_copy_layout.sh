#!/usr/bin/env bash
# Ловит ansible copy без завершающего /: каталог оказывается внутри себя
# (rules/rules/alerts.yml), и Prometheus не видит алерты.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAYOUT_ROOT="$(mktemp -d)"
trap 'rm -rf "${LAYOUT_ROOT}"' EXIT

export LAYOUT_ROOT
ansible-playbook "${ROOT}/ansible/layout-check.yml"

test -f "${LAYOUT_ROOT}/monitoring/prometheus/rules/alerts.yml"
test ! -e "${LAYOUT_ROOT}/monitoring/prometheus/rules/rules"
test -f "${LAYOUT_ROOT}/monitoring/blackbox/blackbox.yml"
test ! -e "${LAYOUT_ROOT}/monitoring/blackbox/blackbox/blackbox.yml"
test -f "${LAYOUT_ROOT}/monitoring/nginx/docker-entrypoint.sh"
test ! -e "${LAYOUT_ROOT}/monitoring/nginx/nginx/docker-entrypoint.sh"
test -f "${LAYOUT_ROOT}/monitoring/grafana/provisioning/datasources/datasource.yml"

echo "[OK] раскладка copy без вложенных каталогов"

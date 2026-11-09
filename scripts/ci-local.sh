#!/usr/bin/env bash
# Локальный прогон тех же проверок, что и GitHub Actions.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"
export PATH="${HOME}/.local/bin:${PATH}"

echo "== tools =="
command -v yamllint
command -v ansible-lint
command -v ansible-playbook
command -v shellcheck
command -v docker

echo "== secrets =="
bash scripts/check-no-secrets.sh

echo "== conventions =="
bash tests/repo_conventions.sh

echo "== textfile и bootstrap =="
bash tests/textfile_scripts.sh
bash tests/bootstrap_secrets.sh
bash tests/ansible_copy_layout.sh

echo "== yamllint =="
yamllint .

echo "== shellcheck =="
shellcheck scripts/*.sh tests/*.sh monitoring/nginx/docker-entrypoint.sh

echo "== ansible =="
ansible-galaxy collection install -r ansible/requirements.yml
ansible-lint
ansible-playbook -i ansible/inventories/staging/hosts.ini ansible/site.yml --syntax-check

echo "== monitoring config =="
bash scripts/check-monitoring-config.sh

echo "== docker compose config =="
# Значение только для интерполяции. Compose up в этом скрипте не запускается.
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-ci-not-a-secret}" \
  GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}" \
  docker compose -f docker/compose.yaml config --quiet

echo "[OK] ci-local checks finished"

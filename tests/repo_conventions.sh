#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

echo "== образы закреплены и не latest =="
if grep -E 'image:.*:latest' docker/compose.yaml; then
  echo "[FAIL] latest в compose" >&2
  exit 1
fi

pins=(
  "prom/prometheus:v3.16.0"
  "prom/alertmanager:v0.34.2"
  "grafana/grafana:13.3.0"
  "prom/node-exporter:v1.12.1"
  "prom/blackbox-exporter:v0.29.1"
  "nginxinc/nginx-unprivileged:1.29.8-alpine"
)
for pin in "${pins[@]}"; do
  grep -q "${pin}" docker/compose.yaml || {
    echo "[FAIL] в compose нет ${pin}" >&2
    exit 1
  }
done
grep -q 'prom/prometheus:v3.16.0' scripts/check-monitoring-config.sh
grep -q 'prom/alertmanager:v0.34.2' scripts/check-monitoring-config.sh
grep -q 'prom/blackbox-exporter:v0.29.1' scripts/check-monitoring-config.sh

echo "== actions закреплены SHA =="
if grep -n 'uses:' .github/workflows/validate.yml | grep -v -E '@[0-9a-f]{40}'; then
  echo "[FAIL] action без полного SHA" >&2
  exit 1
fi

echo "== у каждого алерта есть тест и якорь runbook =="
while read -r name; do
  grep -q "alertname: ${name}$" monitoring/prometheus/tests/alerts_test.yml || {
    echo "[FAIL] нет теста для ${name}" >&2
    exit 1
  }
  anchor="$(printf '%s' "${name}" | tr '[:upper:]' '[:lower:]')"
  grep -q "id=\"${anchor}\"" docs/RUNBOOK.md || {
    echo "[FAIL] нет якоря ${anchor} в docs/RUNBOOK.md" >&2
    exit 1
  }
done < <(awk '/^[[:space:]]*- alert: / { print $3 }' monitoring/prometheus/rules/alerts.yml)

echo "== workflow просит минимальные permissions =="
grep -q 'contents: read' .github/workflows/validate.yml

echo "[OK] соглашения репозитория"

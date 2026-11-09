#!/usr/bin/env bash
# promtool check config, check rules, test rules, amtool, blackbox --config.check.
# Версии образов совпадают с docker/compose.yaml.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROM_DIR="${ROOT}/monitoring/prometheus"
AM_DIR="${ROOT}/monitoring/alertmanager"
BB_FILE="${ROOT}/monitoring/blackbox/blackbox.yml"
PROMETHEUS_IMAGE="prom/prometheus:v3.16.0@sha256:e04987641b57704f408e31f6373ba4138ecf27cb4a165d24aabb6c38fddd0f06"
ALERTMANAGER_IMAGE="prom/alertmanager:v0.34.2@sha256:39d8bb3966c694a124428a3a88fbcffd40bd069129ecd47c059f8a3f17c55f3b"
BLACKBOX_IMAGE="prom/blackbox-exporter:v0.29.1@sha256:ea1c7aa3ef3f307cd03e85f34abb604478ccb90b567fc690da0cd9776da76b13"

use_docker=0
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  use_docker=1
fi

if [[ "${use_docker}" -eq 1 ]]; then
  echo "== promtool (docker ${PROMETHEUS_IMAGE}) =="
  docker run --rm --entrypoint promtool \
    -v "${PROM_DIR}:/etc/prometheus:ro" \
    "${PROMETHEUS_IMAGE}" \
    check config /etc/prometheus/prometheus.yml
  docker run --rm --entrypoint promtool \
    -v "${PROM_DIR}:/etc/prometheus:ro" \
    "${PROMETHEUS_IMAGE}" \
    check rules /etc/prometheus/rules/alerts.yml
  docker run --rm --entrypoint promtool \
    -v "${PROM_DIR}:/etc/prometheus:ro" \
    -w /etc/prometheus \
    "${PROMETHEUS_IMAGE}" \
    test rules /etc/prometheus/tests/alerts_test.yml

  echo "== amtool (docker ${ALERTMANAGER_IMAGE}) =="
  docker run --rm --entrypoint amtool \
    -v "${AM_DIR}:/etc/alertmanager:ro" \
    "${ALERTMANAGER_IMAGE}" \
    check-config /etc/alertmanager/alertmanager.yml

  echo "== blackbox (docker ${BLACKBOX_IMAGE}) =="
  docker run --rm \
    -v "${BB_FILE}:/etc/blackbox/blackbox.yml:ro" \
    "${BLACKBOX_IMAGE}" \
    --config.file=/etc/blackbox/blackbox.yml \
    --config.check
elif command -v promtool >/dev/null 2>&1 && command -v amtool >/dev/null 2>&1 && command -v blackbox_exporter >/dev/null 2>&1; then
  echo "== promtool (локальный бинарник, file_sd может предупредить о /etc/prometheus) =="
  promtool check config "${PROM_DIR}/prometheus.yml"
  promtool check rules "${PROM_DIR}/rules/alerts.yml"
  promtool test rules "${PROM_DIR}/tests/alerts_test.yml"
  amtool check-config "${AM_DIR}/alertmanager.yml"
  blackbox_exporter --config.file="${BB_FILE}" --config.check
else
  echo "[ERROR] нужен docker с демоном или локальные promtool, amtool и blackbox_exporter" >&2
  exit 127
fi

echo "[OK] конфигурация мониторинга"

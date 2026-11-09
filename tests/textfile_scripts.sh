#!/usr/bin/env bash
# Юнит-тесты textfile-скриптов без restic, journald и iptables.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NOW="$(date -u -d '2026-11-09T08:00:00Z' +%s)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

expect_line() {
  local file="$1"
  local line="$2"
  if ! grep -Fxq "${line}" "${file}"; then
    echo "[FAIL] нет строки: ${line}" >&2
    echo "---- ${file} ----" >&2
    cat "${file}" >&2
    exit 1
  fi
}

echo "== restic внутри порога =="
fresh="${WORK}/fresh"
mkdir -p "${fresh}"
TEXTFILE_DIR="${fresh}" \
  REPO_LABEL=primary \
  RPO_HOURS=4 \
  RPO_GRACE_HOURS=1 \
  RESTIC_METRICS_NOW_EPOCH="${NOW}" \
  RESTIC_METRICS_FIXTURE="${ROOT}/tests/fixtures/restic-snapshot.json" \
  bash "${ROOT}/scripts/restic-textfile.sh"
expect_line "${fresh}/restic_snapshot.prom" 'restic_snapshot_check_success{repo="primary"} 1'
expect_line "${fresh}/restic_snapshot.prom" 'restic_snapshot_age_seconds{repo="primary"} 7200'
expect_line "${fresh}/restic_snapshot.prom" 'restic_rpo_seconds{repo="primary"} 14400'
expect_line "${fresh}/restic_snapshot.prom" 'restic_rpo_grace_seconds{repo="primary"} 3600'
expect_line "${fresh}/restic_snapshot.prom" 'restic_rpo_threshold_seconds{repo="primary"} 18000'
expected_ts="$(python3 -c 'from datetime import datetime; print(int(datetime.fromisoformat("2026-11-09T06:00:00+00:00").timestamp()))')"
expect_line "${fresh}/restic_snapshot.prom" "restic_last_snapshot_timestamp_seconds{repo=\"primary\"} ${expected_ts}"

echo "== restic старше порога: метрика есть, код 1 =="
old="${WORK}/old"
mkdir -p "${old}"
set +e
TEXTFILE_DIR="${old}" \
  REPO_LABEL=primary \
  RPO_HOURS=4 \
  RPO_GRACE_HOURS=1 \
  RESTIC_METRICS_NOW_EPOCH="${NOW}" \
  RESTIC_METRICS_FIXTURE="${ROOT}/tests/fixtures/restic-snapshot-old.json" \
  bash "${ROOT}/scripts/restic-textfile.sh"
old_rc=$?
set -e
[[ "${old_rc}" -eq 1 ]]
expect_line "${old}/restic_snapshot.prom" 'restic_snapshot_check_success{repo="primary"} 1'
expect_line "${old}/restic_snapshot.prom" 'restic_snapshot_age_seconds{repo="primary"} 115200'

echo "== restic пустой список: success 0 и нет возраста =="
empty="${WORK}/empty"
mkdir -p "${empty}"
set +e
TEXTFILE_DIR="${empty}" \
  REPO_LABEL=primary \
  RESTIC_METRICS_NOW_EPOCH="${NOW}" \
  RESTIC_METRICS_FIXTURE="${ROOT}/tests/fixtures/restic-snapshot-empty.json" \
  bash "${ROOT}/scripts/restic-textfile.sh"
empty_rc=$?
set -e
[[ "${empty_rc}" -eq 1 ]]
expect_line "${empty}/restic_snapshot.prom" 'restic_snapshot_check_success{repo="primary"} 0'
if grep -q 'restic_snapshot_age_seconds' "${empty}/restic_snapshot.prom"; then
  echo "[FAIL] возраст записан при пустом списке" >&2
  exit 1
fi

echo "== restic: плохой label не пишет файл =="
bad="${WORK}/bad"
mkdir -p "${bad}"
set +e
TEXTFILE_DIR="${bad}" REPO_LABEL='pri mary' bash "${ROOT}/scripts/restic-textfile.sh"
bad_rc=$?
set -e
[[ "${bad_rc}" -eq 1 ]]
if [[ -e "${bad}/restic_snapshot.prom" ]]; then
  echo "[FAIL] файл метрик создан при плохом label" >&2
  exit 1
fi

echo "== ssh: окно 15 минут =="
sshdir="${WORK}/ssh"
mkdir -p "${sshdir}"
TZ=UTC \
  TEXTFILE_DIR="${sshdir}" \
  SSH_AUTH_WINDOW_SECONDS=900 \
  SSH_AUTH_NOW_EPOCH="${NOW}" \
  SSH_AUTH_LOG_FILE="${ROOT}/tests/fixtures/auth.log" \
  bash "${ROOT}/scripts/ssh-auth-metrics.sh"
expect_line "${sshdir}/ssh_auth.prom" 'ssh_auth_metrics_collection_success{source="file"} 1'
expect_line "${sshdir}/ssh_auth.prom" 'ssh_auth_failures_last_window{source="file"} 3'
expect_line "${sshdir}/ssh_auth.prom" 'ssh_auth_invalid_user_last_window{source="file"} 1'
expect_line "${sshdir}/ssh_auth.prom" 'ssh_auth_failure_unique_sources_last_window{source="file"} 3'
expect_line "${sshdir}/ssh_auth.prom" 'ssh_auth_window_seconds{source="file"} 900'

echo "== DOCKER-USER dry-run =="
plan="$(MONITORING_DOCKER_USER_ENV=/dev/null bash "${ROOT}/scripts/monitoring-docker-user.sh" --dry-run)"
grep -q 'iptables -A DOCKER-USER -p tcp --dport 8443 .* mon-drop-8443 -j DROP' <<< "${plan}"
grep -q 'iptables -I DOCKER-USER 1 -p tcp -s 127.0.0.0/8 --dport 8443 .* mon-allow-8443 -j RETURN' <<< "${plan}"
grep -q 'ip6tables -I DOCKER-USER 1 -p tcp -s ::1/128 --dport 8445' <<< "${plan}"
set +e
MONITORING_DOCKER_USER_ENV=/dev/null MONITORING_ALLOW_CIDRS='127.0.0.0/8;rm -rf' \
  bash "${ROOT}/scripts/monitoring-docker-user.sh" --dry-run
dry_rc=$?
set -e
[[ "${dry_rc}" -eq 2 ]]

echo "[OK] textfile и dry-run DOCKER-USER"

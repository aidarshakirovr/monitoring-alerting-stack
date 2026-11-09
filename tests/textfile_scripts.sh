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

echo "== restic: не первая группа, а самая свежая; наносекунды =="
groups="${WORK}/groups"
mkdir -p "${groups}"
TEXTFILE_DIR="${groups}" \
  REPO_LABEL=primary \
  RPO_HOURS=4 \
  RPO_GRACE_HOURS=1 \
  RESTIC_METRICS_NOW_EPOCH="${NOW}" \
  RESTIC_METRICS_FIXTURE="${ROOT}/tests/fixtures/restic-snapshot-groups.json" \
  bash "${ROOT}/scripts/restic-textfile.sh"
expect_line "${groups}/restic_snapshot.prom" 'restic_snapshot_age_seconds{repo="primary"} 7200'
filtered="${WORK}/filtered"
mkdir -p "${filtered}"
TEXTFILE_DIR="${filtered}" \
  REPO_LABEL=primary \
  RPO_HOURS=4 \
  RPO_GRACE_HOURS=1 \
  RESTIC_METRICS_NOW_EPOCH="${NOW}" \
  RESTIC_SNAPSHOT_PATHS=/srv/app/data \
  RESTIC_METRICS_FIXTURE="${ROOT}/tests/fixtures/restic-snapshot-groups.json" \
  bash "${ROOT}/scripts/restic-textfile.sh" || true
expect_line "${filtered}/restic_snapshot.prom" 'restic_snapshot_age_seconds{repo="primary"} 126000'

echo "== journalctl: аргументы и sshd-session =="
fakebin="${WORK}/bin"
mkdir -p "${fakebin}"
args_file="${WORK}/journalctl.args"
cat > "${fakebin}/journalctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "${JOURNALCTL_ARGS_FILE}"
printf '%s\n' 'Failed password for root from 203.0.113.50 port 22 ssh2'
EOF
chmod 0755 "${fakebin}/journalctl"
journaldir="${WORK}/journal"
mkdir -p "${journaldir}"
PATH="${fakebin}:${PATH}" \
  JOURNALCTL_ARGS_FILE="${args_file}" \
  TEXTFILE_DIR="${journaldir}" \
  SSH_AUTH_WINDOW_SECONDS=900 \
  bash "${ROOT}/scripts/ssh-auth-metrics.sh"
expect_line "${journaldir}/ssh_auth.prom" 'ssh_auth_failures_last_window{source="journal"} 1'
grep -q '900 seconds ago' "${args_file}"
grep -q 'sshd-session' "${args_file}"
if grep -q -- '-900 seconds ago' "${args_file}"; then
  echo "[FAIL] невалидный --since" >&2
  exit 1
fi

echo "== restic: дробные секунды из 2 и 4 знаков =="
for frac in 12 1234; do
  fracdir="${WORK}/frac-${frac}"
  mkdir -p "${fracdir}"
  fixture="${fracdir}/snap.json"
  printf '[{"time":"2026-11-09T06:00:00.%s+00:00","hostname":"app","paths":["/srv/app/data"],"short_id":"f"}]\n' "${frac}" > "${fixture}"
  TEXTFILE_DIR="${fracdir}" \
    REPO_LABEL=primary \
    RPO_HOURS=4 \
    RPO_GRACE_HOURS=1 \
    RESTIC_METRICS_NOW_EPOCH="${NOW}" \
    RESTIC_METRICS_FIXTURE="${fixture}" \
    bash "${ROOT}/scripts/restic-textfile.sh"
  expect_line "${fracdir}/restic_snapshot.prom" 'restic_snapshot_age_seconds{repo="primary"} 7200'
done

echo "== DOCKER-USER dry-run =="
plan="$(MONITORING_DOCKER_USER_ENV=/dev/null MONITORING_BIND_IP=192.0.2.10 bash "${ROOT}/scripts/monitoring-docker-user.sh" --dry-run)"
grep -q 'iptables-restore --noflush' <<< "${plan}"
grep -q -- '-A MONITORING-PROXY-FWD -p tcp -s 127.0.0.0/8 -m conntrack --ctdir ORIGINAL --ctorigdst 192.0.2.10 --ctorigdstport 8443 ' <<< "${plan}"
grep -q -- '-A MONITORING-PROXY-FWD -p tcp -m conntrack --ctdir ORIGINAL --ctorigdst 192.0.2.10 --ctorigdstport 8443 ' <<< "${plan}"
grep -q 'iptables -I DOCKER-USER 1 -j MONITORING-PROXY-FWD' <<< "${plan}"
grep -q 'iptables -I INPUT 1 -j MONITORING-PROXY-IN' <<< "${plan}"
allow_at="$(grep -n 'mon-allow-8443-127.0.0.0_8 -j RETURN' <<< "${plan}" | head -1 | cut -d: -f1)"
drop_at="$(grep -n 'mon-drop-8443 -j DROP' <<< "${plan}" | head -1 | cut -d: -f1)"
[[ -n "${allow_at}" && -n "${drop_at}" && "${allow_at}" -lt "${drop_at}" ]]
if grep -E -- '-D DOCKER-USER|-F DOCKER-USER' <<< "${plan}"; then
  echo "[FAIL] план сначала снимает фильтр" >&2
  exit 1
fi

echo "== DOCKER-USER: сбой restore не ставит applied=1 =="
fakebin="${WORK}/fake-iptables"
mkdir -p "${fakebin}"
cat > "${fakebin}/iptables" <<'EOF'
#!/bin/sh
if [ "$1" = "-nL" ]; then
  exit 0
fi
exit 0
EOF
cat > "${fakebin}/iptables-restore" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod 0755 "${fakebin}/iptables" "${fakebin}/iptables-restore"
metricdir="${WORK}/docker-user-metric"
mkdir -p "${metricdir}"
set +e
PATH="${fakebin}:${PATH}" \
  MONITORING_DOCKER_USER_ENV=/dev/null \
  TEXTFILE_DIR="${metricdir}" \
  bash "${ROOT}/scripts/monitoring-docker-user.sh"
apply_rc=$?
set -e
[[ "${apply_rc}" -ne 0 ]]
expect_line "${metricdir}/docker_user.prom" 'monitoring_docker_user_applied{family="ipv4"} 0'
set +e
MONITORING_DOCKER_USER_ENV=/dev/null MONITORING_ALLOW_CIDRS='127.0.0.0/8;rm -rf' \
  bash "${ROOT}/scripts/monitoring-docker-user.sh" --dry-run
dry_rc=$?
set -e
[[ "${dry_rc}" -eq 2 ]]
set +e
MONITORING_DOCKER_USER_ENV=/dev/null MONITORING_BIND_IP=0.0.0.0 \
  bash "${ROOT}/scripts/monitoring-docker-user.sh" --dry-run
wide_rc=$?
set -e
[[ "${wide_rc}" -eq 2 ]]

echo "[OK] textfile и dry-run DOCKER-USER"

#!/usr/bin/env bash
# Счётчики неудачных SSH-входов за окно для node_exporter (textfile).
#
# Это обнаружение, не блокировка. Роль host_hardening в репозитории
# test-task-sys-admin-infr-engineer может ставить fail2ban; здесь его нет.
#
# Ограничения, без которых метрике нельзя верить:
# - Берётся один источник: явный файл, иначе journalctl _COMM=sshd,
#   иначе /var/log/auth.log, иначе /var/log/secure. Два источника сразу
#   не читаются, чтобы не удвоить одну попытку.
# - journalctl с -o cat уже ограничен --since, поэтому строки не фильтруются
#   повторно. Если _COMM другой (не sshd), журнал молчит, а auth.log мы
#   уже не откроем: будет честный ноль. Задайте SSH_AUTH_LOG_FILE.
# - Классический syslog без года читается в часовом поясе хоста
#   (или в UTC, если задан SSH_AUTH_NOW_EPOCH). Граница декабря и января
#   сдвигается на год назад, если отметка больше чем на неделю в будущем.
# - Из файла берутся только последние SSH_AUTH_LOG_TAIL_LINES строк
#   (по умолчанию 5000). Более плотный журнал будет недосчитан.
# - «Invalid user» и «Failed password» в одной строке — одна неудача.
#   Строка PAM «authentication failure» рядом со строкой sshd может
#   посчитать ту же попытку дважды, если обе попали в один источник.
# - В метриках нет IP: кардинальность series. Число разных источников —
#   отдельный gauge. IP смотрите в журнале по runbook.
# - Успешный вход с первого раза этой метрикой не виден.
set -Eeuo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
WINDOW="${SSH_AUTH_WINDOW_SECONDS:-900}"
TAIL_LINES="${SSH_AUTH_LOG_TAIL_LINES:-5000}"
OUT="${TEXTFILE_DIR}/ssh_auth.prom"
SOURCE="none"
ASSUME="0"
NOW_EPOCH="${SSH_AUTH_NOW_EPOCH:-}"

if ! [[ "${WINDOW}" =~ ^[0-9]+$ ]]; then
  echo "[ERROR] SSH_AUTH_WINDOW_SECONDS не целое число" >&2
  exit 1
fi
if ! [[ "${TAIL_LINES}" =~ ^[0-9]+$ ]]; then
  echo "[ERROR] SSH_AUTH_LOG_TAIL_LINES не целое число" >&2
  exit 1
fi

mkdir -p "${TEXTFILE_DIR}"
TMP="$(mktemp "${TEXTFILE_DIR}/.ssh_auth.prom.XXXXXX")"
RAW="$(mktemp)"
SOURCES="$(mktemp)"
cleanup() {
  rm -f "${TMP}" "${RAW}" "${SOURCES}"
}
trap cleanup EXIT

write_metrics() {
  local success="$1"
  local failures="$2"
  local invalid="$3"
  local unique="$4"
  {
    echo "# HELP ssh_auth_metrics_collection_success 1 если источник журнала прочитан"
    echo "# TYPE ssh_auth_metrics_collection_success gauge"
    echo "ssh_auth_metrics_collection_success{source=\"${SOURCE}\"} ${success}"
    echo "# HELP ssh_auth_failures_last_window Неудачные SSH-аутентификации за окно"
    echo "# TYPE ssh_auth_failures_last_window gauge"
    echo "ssh_auth_failures_last_window{source=\"${SOURCE}\"} ${failures}"
    echo "# HELP ssh_auth_invalid_user_last_window Строки Invalid user за окно"
    echo "# TYPE ssh_auth_invalid_user_last_window gauge"
    echo "ssh_auth_invalid_user_last_window{source=\"${SOURCE}\"} ${invalid}"
    echo "# HELP ssh_auth_failure_unique_sources_last_window Разные адреса в неудачных строках"
    echo "# TYPE ssh_auth_failure_unique_sources_last_window gauge"
    echo "ssh_auth_failure_unique_sources_last_window{source=\"${SOURCE}\"} ${unique}"
    echo "# HELP ssh_auth_window_seconds Длина окна, секунды"
    echo "# TYPE ssh_auth_window_seconds gauge"
    echo "ssh_auth_window_seconds{source=\"${SOURCE}\"} ${WINDOW}"
  } > "${TMP}"
  chmod 0644 "${TMP}"
  mv -f "${TMP}" "${OUT}"
}

fail_collect() {
  write_metrics 0 0 0 0
  exit 1
}

if ! command -v python3 >/dev/null 2>&1; then
  echo "[ERROR] python3 не найден" >&2
  fail_collect
fi

if [[ -n "${SSH_AUTH_LOG_FILE:-}" ]]; then
  SOURCE="file"
  if [[ ! -r "${SSH_AUTH_LOG_FILE}" ]]; then
    echo "[ERROR] журнал ${SSH_AUTH_LOG_FILE} недоступен" >&2
    fail_collect
  fi
  tail -n "${TAIL_LINES}" -- "${SSH_AUTH_LOG_FILE}" > "${RAW}"
elif command -v journalctl >/dev/null 2>&1 && journalctl \
  --since "${WINDOW} seconds ago" \
  -o cat \
  --no-pager \
  _SYSTEMD_UNIT=ssh.service \
  + _SYSTEMD_UNIT=sshd.service \
  + SYSLOG_IDENTIFIER=sshd \
  + SYSLOG_IDENTIFIER=sshd-session \
  > "${RAW}" 2>/dev/null; then
  SOURCE="journal"
  ASSUME="1"
elif [[ -r /var/log/auth.log ]]; then
  SOURCE="authlog"
  tail -n "${TAIL_LINES}" -- /var/log/auth.log > "${RAW}"
elif [[ -r /var/log/secure ]]; then
  SOURCE="secure"
  tail -n "${TAIL_LINES}" -- /var/log/secure > "${RAW}"
else
  echo "[ERROR] нет ни journalctl, ни auth.log, ни secure" >&2
  fail_collect
fi

if ! filtered="$(python3 - "${WINDOW}" "${ASSUME}" "${NOW_EPOCH}" "${RAW}" <<'PY'
import datetime
import sys

window = int(sys.argv[1])
assume = sys.argv[2] == "1"
now_raw = sys.argv[3]
path = sys.argv[4]
months = {
    name: index
    for index, name in enumerate(
        ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
        start=1,
    )
}

if now_raw:
    now = datetime.datetime.fromtimestamp(float(now_raw), datetime.timezone.utc)
    tz = datetime.timezone.utc
else:
    now = datetime.datetime.now().astimezone()
    tz = now.tzinfo

def emit(line: str) -> None:
    sys.stdout.write(line + "\n")

with open(path, encoding="utf-8", errors="replace") as handle:
    for raw_line in handle:
        line = raw_line.rstrip("\n")
        if not line:
            continue
        if assume:
            emit(line)
            continue
        if len(line) >= 20 and line[4] == "-" and "T" in line[:25]:
            token = line.split(" ", 1)[0]
            token = token.replace("Z", "+00:00")
            try:
                stamp = datetime.datetime.fromisoformat(token).astimezone(datetime.timezone.utc)
            except ValueError:
                continue
            payload = line.split(" ", 1)[1] if " " in line else line
        else:
            parts = line.split()
            if len(parts) < 4 or parts[0] not in months:
                continue
            try:
                day = int(parts[1])
                hour, minute, second = (int(x) for x in parts[2].split(":"))
            except ValueError:
                continue
            stamp = datetime.datetime(
                now.year, months[parts[0]], day, hour, minute, second, tzinfo=tz
            )
            if (stamp - now).total_seconds() > 7 * 86400:
                stamp = stamp.replace(year=stamp.year - 1)
            payload = " ".join(parts[3:])
        age = (now - stamp.astimezone(datetime.timezone.utc)).total_seconds()
        if age < 0 or age > window:
            continue
        emit(payload)
PY
)"; then
  echo "[ERROR] разбор журнала не удался" >&2
  fail_collect
fi

failures=0
invalid=0
while IFS= read -r line; do
  [[ -n "${line}" ]] || continue
  is_failure=0
  case "${line}" in
    *"Invalid user"*|*"invalid user"*)
      invalid=$((invalid + 1))
      is_failure=1
      ;;
  esac
  case "${line}" in
    *"Failed password"*|*"Failed publickey"*|*"Failed keyboard-interactive"*|*"authentication failure"*)
      is_failure=1
      ;;
  esac
  if [[ "${is_failure}" -eq 1 ]]; then
    failures=$((failures + 1))
    if [[ "${line}" =~ from[[:space:]]([0-9A-Fa-f:.]+) ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}" >> "${SOURCES}"
    fi
  fi
done <<< "${filtered}"

unique="$(sort -u "${SOURCES}" | wc -l | tr -d '[:space:]')"
write_metrics 1 "${failures}" "${invalid}" "${unique}"
echo "[INFO] ssh failures=${failures} invalid_user=${invalid} sources=${unique} window=${WINDOW}s source=${SOURCE}"

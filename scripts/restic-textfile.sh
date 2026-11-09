#!/usr/bin/env bash
# Метрики возраста последнего снапшота restic для node_exporter (textfile).
#
# Связка с github.com/aidarshakirovr/test-task-sys-admin-infr-engineer:
# там scripts/ansible role backup_restic пишет restic-rpo-check.sh, который
# завершается с кодом 1, если снапшот старше RPO (по умолчанию 4 часа).
# Здесь тот же сигнал становится метрикой, чтобы Alertmanager вёл его рядом
# с хостовыми алертами. Порог в файле — RPO + запас (grace). Запас по
# умолчанию 1 час не измерен: он закрывает длительность backup и джиттер
# таймера, иначе проверка на ровно 4 часах мигает в конце интервала.
#
# Код выхода:
#   0 — снапшот прочитан и не старше порога;
#   1 — измерение удалось, но порог превышен (метрика success=1, возраст честный);
#   1 — измерение не удалось (метрика success=0, возраста нет).
# Успех измерения и соблюдение RPO — разные вещи. Алерт смотрит на метрики.
set -Eeuo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
REPO_LABEL="${REPO_LABEL:-primary}"
RPO_HOURS="${RPO_HOURS:-4}"
RPO_GRACE_HOURS="${RPO_GRACE_HOURS:-1}"
OUT="${TEXTFILE_DIR}/restic_snapshot.prom"

if ! [[ "${REPO_LABEL}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
  echo "[ERROR] REPO_LABEL содержит недопустимые символы" >&2
  exit 1
fi

if ! [[ "${RPO_HOURS}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "[ERROR] RPO_HOURS не число" >&2
  exit 1
fi

if ! [[ "${RPO_GRACE_HOURS}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "[ERROR] RPO_GRACE_HOURS не число" >&2
  exit 1
fi

mkdir -p "${TEXTFILE_DIR}"
TMP="$(mktemp "${TEXTFILE_DIR}/.restic_snapshot.prom.XXXXXX")"
cleanup() {
  rm -f "${TMP}"
}
trap cleanup EXIT

rpo_seconds="$(awk -v h="${RPO_HOURS}" 'BEGIN { printf "%.0f", h * 3600 }')"
grace_seconds="$(awk -v h="${RPO_GRACE_HOURS}" 'BEGIN { printf "%.0f", h * 3600 }')"
threshold_seconds="$((rpo_seconds + grace_seconds))"

write_metrics() {
  local success="$1"
  local age="${2:-}"
  local stamp="${3:-}"
  {
    echo "# HELP restic_snapshot_check_success 1 если снапшот прочитан, 0 если измерение не удалось"
    echo "# TYPE restic_snapshot_check_success gauge"
    echo "restic_snapshot_check_success{repo=\"${REPO_LABEL}\"} ${success}"
    echo "# HELP restic_rpo_seconds Заявленный RPO в секундах, не измеренный SLA"
    echo "# TYPE restic_rpo_seconds gauge"
    echo "restic_rpo_seconds{repo=\"${REPO_LABEL}\"} ${rpo_seconds}"
    echo "# HELP restic_rpo_grace_seconds Запас сверх RPO на длительность backup и джиттер таймера"
    echo "# TYPE restic_rpo_grace_seconds gauge"
    echo "restic_rpo_grace_seconds{repo=\"${REPO_LABEL}\"} ${grace_seconds}"
    echo "# HELP restic_rpo_threshold_seconds Порог алерта: RPO плюс grace"
    echo "# TYPE restic_rpo_threshold_seconds gauge"
    echo "restic_rpo_threshold_seconds{repo=\"${REPO_LABEL}\"} ${threshold_seconds}"
    if [[ -n "${age}" && -n "${stamp}" ]]; then
      echo "# HELP restic_snapshot_age_seconds Возраст последнего снапшота"
      echo "# TYPE restic_snapshot_age_seconds gauge"
      echo "restic_snapshot_age_seconds{repo=\"${REPO_LABEL}\"} ${age}"
      echo "# HELP restic_last_snapshot_timestamp_seconds Unix-время последнего снапшота"
      echo "# TYPE restic_last_snapshot_timestamp_seconds gauge"
      echo "restic_last_snapshot_timestamp_seconds{repo=\"${REPO_LABEL}\"} ${stamp}"
    fi
  } > "${TMP}"
  chmod 0644 "${TMP}"
  mv -f "${TMP}" "${OUT}"
}

fail_measure() {
  write_metrics 0
  exit 1
}

if ! command -v python3 >/dev/null 2>&1; then
  echo "[ERROR] python3 не найден" >&2
  fail_measure
fi

json_file="$(mktemp)"
trap 'rm -f "${TMP}" "${json_file}"' EXIT

if [[ -n "${RESTIC_METRICS_FIXTURE:-}" ]]; then
  if [[ ! -r "${RESTIC_METRICS_FIXTURE}" ]]; then
    echo "[ERROR] фикстура недоступна" >&2
    fail_measure
  fi
  cp -- "${RESTIC_METRICS_FIXTURE}" "${json_file}"
else
  if ! command -v restic >/dev/null 2>&1; then
    echo "[ERROR] restic не найден" >&2
    fail_measure
  fi
  if [[ -z "${RESTIC_REPOSITORY:-}" || -z "${RESTIC_PASSWORD_FILE:-}" ]]; then
    echo "[ERROR] нужны RESTIC_REPOSITORY и RESTIC_PASSWORD_FILE" >&2
    fail_measure
  fi
  if [[ ! -r "${RESTIC_PASSWORD_FILE}" ]]; then
    echo "[ERROR] файл пароля restic недоступен для чтения" >&2
    fail_measure
  fi
  export RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/var/cache/restic-backup}"
  # --no-lock: это чтение. Лок пишется в репозиторий, а юнит держит
  # ProtectSystem=strict и не может создать locks/ в /var/backups.
  restic_cmd=(restic snapshots
    --repo "${RESTIC_REPOSITORY}"
    --password-file "${RESTIC_PASSWORD_FILE}"
    --latest 1
    --no-lock
    --json)
  if [[ -n "${RESTIC_SNAPSHOT_HOST:-}" ]]; then
    restic_cmd+=(--host "${RESTIC_SNAPSHOT_HOST}")
  fi
  if [[ -n "${RESTIC_SNAPSHOT_PATHS:-}" ]]; then
    local_path=""
    IFS=',' read -ra restic_paths <<< "${RESTIC_SNAPSHOT_PATHS}"
    for local_path in "${restic_paths[@]}"; do
      restic_cmd+=(--path "${local_path}")
    done
  fi
  if ! "${restic_cmd[@]}" > "${json_file}"; then
    echo "[ERROR] restic snapshots завершился с ошибкой" >&2
    fail_measure
  fi
fi

parsed="$(
  RESTIC_METRICS_NOW_EPOCH="${RESTIC_METRICS_NOW_EPOCH:-}" \
    python3 - "${json_file}" <<'PY'
import json
import os
import re
import sys
from datetime import datetime, timezone

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
if isinstance(data, dict):
    data = [data]
if not data:
    sys.exit(2)

def normalize_time(raw):
    # Python <= 3.10 принимает не больше 6 знаков дробной части.
    text = str(raw).replace("Z", "+00:00")
    return re.sub(r"(\.\d{6})\d+", r"\1", text)

def stamp_of(item):
    return datetime.fromisoformat(normalize_time(item["time"]))

host = os.environ.get("RESTIC_SNAPSHOT_HOST", "")
paths = [item for item in os.environ.get("RESTIC_SNAPSHOT_PATHS", "").split(",") if item]
chosen = []
for item in data:
    if host and item.get("hostname") != host:
        continue
    item_paths = item.get("paths") or []
    if paths and not any(path in item_paths for path in paths):
        continue
    chosen.append(item)
if not chosen:
    sys.exit(2)
# --latest 1 отдаёт последний снапшот каждой группы, не самый свежий в файле.
# data[0] поэтому не годится: берём максимум по времени.
best = max(chosen, key=stamp_of)
stamp = stamp_of(best)
epoch = stamp.timestamp()
now_raw = os.environ.get("RESTIC_METRICS_NOW_EPOCH", "")
if now_raw:
    now = float(now_raw)
else:
    now = datetime.now(timezone.utc).timestamp()
age = now - epoch
# Снапшот «из будущего» больше чем на 5 минут — часы расходятся, измерению не верим.
if age < -300:
    sys.exit(3)
if age < 0:
    age = 0
print(f"{age:.0f} {epoch:.0f}")
PY
)" || fail_measure

age="${parsed%% *}"
stamp="${parsed##* }"
if ! [[ "${age}" =~ ^[0-9]+$ && "${stamp}" =~ ^[0-9]+$ ]]; then
  echo "[ERROR] не удалось разобрать возраст снапшота" >&2
  fail_measure
fi

write_metrics 1 "${age}" "${stamp}"
echo "[INFO] Last snapshot age: ${age}s (threshold ${threshold_seconds}s, repo ${REPO_LABEL})"

if [[ "${age}" -gt "${threshold_seconds}" ]]; then
  echo "[ERROR] RPO breached: latest snapshot is ${age}s old, threshold ${threshold_seconds}s" >&2
  exit 1
fi

echo "[OK] Latest snapshot is within the RPO threshold."

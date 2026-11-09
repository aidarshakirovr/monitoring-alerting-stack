#!/usr/bin/env bash
# Грубый стоп-кран: приватные ключи и типичные токены не должны лежать в дереве.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

pattern='BEGIN [A-Z ]*PRIVATE KEY|AKIA[0-9A-Z]{16}|xox[baprs]-'

if grep -RInE --exclude-dir=.git --exclude=check-no-secrets.sh --exclude=bootstrap-local-secrets.sh \
  -e "${pattern}" .; then
  echo "[ERROR] в дереве нашёлся фрагмент, похожий на секрет" >&2
  exit 1
fi

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if git ls-files | grep -E '(^|/)vault\.yml$|(^|/)\.env$|^docker/secrets/'; then
    echo "[ERROR] в git попал vault.yml, .env или docker/secrets" >&2
    exit 1
  fi
fi

echo "[OK] явных секретов в дереве не видно"

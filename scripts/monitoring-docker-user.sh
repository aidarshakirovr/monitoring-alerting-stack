#!/usr/bin/env bash
# Точечный DROP в цепочке DOCKER-USER для портов прокси мониторинга.
#
# UFW смотрит INPUT. Docker публикует порты через DNAT и FORWARD, поэтому
# пакет к опубликованному порту обходит правила UFW. DOCKER-USER — место,
# куда Docker отдаёт решение до своего ACCEPT.
#
# В репозитории backup после allow стоит RETURN без DROP: пакет возвращается
# в политику Docker и принимается. Здесь для портов прокси после allow-списка
# стоит DROP. Чужие порты и чужие правила цепочки не сбрасываются.
#
# Привязка 127.0.0.1 часто идёт мимо FORWARD (docker-proxy / INPUT).
# Основная защита лабораторного стенда — bind, а не эта цепочка.
# Цепочка нужна, когда MONITORING_BIND_IP — не loopback.
#
# --dry-run только проверяет числа и печатает план, iptables не вызывает.
# --rebuild удаляет свои правила (комментарий mon-*) и ставит их заново.
# Между удалением и вставкой порт на короткое время снова принимает трафик
# по политике Docker. Обычный запуск ничего не удаляет.
set -Eeuo pipefail

ENV_FILE="${MONITORING_DOCKER_USER_ENV:-/etc/monitoring/docker-user.env}"
DRY_RUN=0
REBUILD=0

usage() {
  echo "usage: monitoring-docker-user.sh [--dry-run] [--rebuild]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --rebuild) REBUILD=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[ERROR] неизвестный аргумент: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

if [[ -f "${ENV_FILE}" && -r "${ENV_FILE}" ]]; then
  # Файл пишет Ansible, режим 0644, значения — порты и CIDR.
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

PORTS="${MONITORING_PROXY_PORTS:-8443 8444 8445}"
ALLOW_CIDRS="${MONITORING_ALLOW_CIDRS:-127.0.0.0/8}"
ALLOW_CIDRS_V6="${MONITORING_ALLOW_CIDRS_V6:-::1/128}"

validate_port_list() {
  local port
  for port in ${PORTS}; do
    if ! [[ "${port}" =~ ^[0-9]+$ ]]; then
      echo "[ERROR] порт не число: ${port}" >&2
      exit 2
    fi
    if [[ "${port}" -lt 1 || "${port}" -gt 65535 ]]; then
      echo "[ERROR] порт вне диапазона: ${port}" >&2
      exit 2
    fi
  done
}

validate_cidrs() {
  local cidr
  for cidr in "$@"; do
    if ! [[ "${cidr}" =~ ^[0-9A-Fa-f:.]+/[0-9]{1,3}$ ]]; then
      echo "[ERROR] странный CIDR: ${cidr}" >&2
      exit 2
    fi
  done
}

validate_port_list
# shellcheck disable=SC2086
validate_cidrs ${ALLOW_CIDRS}
# shellcheck disable=SC2086
validate_cidrs ${ALLOW_CIDRS_V6}

plan_family() {
  local family="$1"
  local cidrs="$2"
  local port cidr
  for port in ${PORTS}; do
    printf '%s -A DOCKER-USER -p tcp --dport %s -m comment --comment mon-drop-%s -j DROP\n' \
      "${family}" "${port}" "${port}"
    for cidr in ${cidrs}; do
      printf '%s -I DOCKER-USER 1 -p tcp -s %s --dport %s -m comment --comment mon-allow-%s -j RETURN\n' \
        "${family}" "${cidr}" "${port}" "${port}"
    done
  done
}

if [[ "${DRY_RUN}" -eq 1 ]]; then
  plan_family iptables "${ALLOW_CIDRS}"
  plan_family ip6tables "${ALLOW_CIDRS_V6}"
  exit 0
fi

if ! command -v iptables >/dev/null 2>&1; then
  echo "[ERROR] iptables не найден" >&2
  exit 1
fi

delete_our_rules() {
  local cmd="$1"
  local numbers number
  if ! "${cmd}" -nL DOCKER-USER >/dev/null 2>&1; then
    return 0
  fi
  numbers="$("${cmd}" -L DOCKER-USER --line-numbers -n | awk '/\/\* mon-(allow|drop)-/ { print $1 }' | sort -nr)"
  for number in ${numbers}; do
    "${cmd}" -D DOCKER-USER "${number}"
  done
}

apply_family() {
  local cmd="$1"
  local cidrs="$2"
  local port cidr
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "[WARN] ${cmd} не найден, семейство пропущено" >&2
    return 0
  fi
  if ! "${cmd}" -nL DOCKER-USER >/dev/null 2>&1; then
    echo "[ERROR] цепочка DOCKER-USER отсутствует (${cmd})" >&2
    return 1
  fi
  if [[ "${REBUILD}" -eq 1 ]]; then
    delete_our_rules "${cmd}"
  fi
  for port in ${PORTS}; do
    if ! "${cmd}" -C DOCKER-USER -p tcp --dport "${port}" -m comment --comment "mon-drop-${port}" -j DROP 2>/dev/null; then
      "${cmd}" -A DOCKER-USER -p tcp --dport "${port}" -m comment --comment "mon-drop-${port}" -j DROP
    fi
    for cidr in ${cidrs}; do
      if ! "${cmd}" -C DOCKER-USER -p tcp -s "${cidr}" --dport "${port}" -m comment --comment "mon-allow-${port}" -j RETURN 2>/dev/null; then
        "${cmd}" -I DOCKER-USER 1 -p tcp -s "${cidr}" --dport "${port}" -m comment --comment "mon-allow-${port}" -j RETURN
      fi
    done
  done
}

apply_family iptables "${ALLOW_CIDRS}"
if ! apply_family ip6tables "${ALLOW_CIDRS_V6}"; then
  # Нет цепочки IPv6: либо Docker без ip6tables, либо демон ещё не поднял её.
  # Это дыра, только если порт опубликован и на ::. Проверка — ss в runbook.
  echo "[WARN] IPv6 DOCKER-USER не применён" >&2
fi

echo "[OK] DOCKER-USER для портов мониторинга обновлён"

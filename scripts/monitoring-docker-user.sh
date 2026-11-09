#!/usr/bin/env bash
# Ограничивает опубликованные порты прокси.
#
# Два пути, оба нужны:
# 1. DNAT и FORWARD. К моменту DOCKER-USER адрес назначения уже контейнерный
#    (хост:8443 -> контейнер:8080). --dport 8443 этот пакет не видит.
#    Совпадение — conntrack --ctorigdst и --ctorigdstport, направление ORIGINAL,
#    чтобы не отрезать ответный трафик. Вставка через -I, выше любого RETURN,
#    который Docker иногда оставляет в конце цепочки.
# 2. docker-proxy (userland-proxy по умолчанию) слушает порт на хосте.
#    Такой пакет идёт в INPUT, не в FORWARD. Там dport ещё хостовый.
#
# --ctorigdst равен MONITORING_BIND_IP. Правило не матчит исходящий трафик
# контейнера на чужой :8443 и не режет транзит. 0.0.0.0 запрещён: у него нет
# одного исходного адреса назначения, и DROP совпал бы с чужими портами.
#
# Цепочки MONITORING-PROXY-* пересобираются через iptables-restore --noflush:
# коммит атомарный, фильтра на это время не пропадает. Прыжок в DOCKER-USER
# и INPUT ставится после коммита. Старые правила mon-* в этих цепочках
# снимаются только потом. --dry-run только печатает план.
set -Eeuo pipefail

ENV_FILE="${MONITORING_DOCKER_USER_ENV:-/etc/monitoring/docker-user.env}"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
DRY_RUN=0

usage() {
  echo "usage: monitoring-docker-user.sh [--dry-run]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --rebuild) ;; # совместимость: сверка и так каждый запуск
    -h|--help) usage; exit 0 ;;
    *) echo "[ERROR] неизвестный аргумент: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

if [[ -f "${ENV_FILE}" && -r "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

PORTS="${MONITORING_PROXY_PORTS:-8443 8444 8445}"
ALLOW_CIDRS="${MONITORING_ALLOW_CIDRS:-127.0.0.0/8}"
ALLOW_CIDRS_V6="${MONITORING_ALLOW_CIDRS_V6:-::1/128}"
BIND_IP="${MONITORING_BIND_IP:-127.0.0.1}"
BIND_IP_V6="${MONITORING_BIND_IP_V6:-::1}"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"

APPLIED_V4=0
APPLIED_V6=0

write_metric() {
  [[ "${DRY_RUN}" -eq 1 ]] && return 0
  mkdir -p "${TEXTFILE_DIR}"
  local tmp
  tmp="$(mktemp "${TEXTFILE_DIR}/.docker_user.prom.XXXXXX")"
  {
    echo "# HELP monitoring_docker_user_applied 1 если правила этого семейства записаны"
    echo "# TYPE monitoring_docker_user_applied gauge"
    echo "monitoring_docker_user_applied{family=\"ipv4\"} ${APPLIED_V4}"
    echo "monitoring_docker_user_applied{family=\"ipv6\"} ${APPLIED_V6}"
  } > "${tmp}"
  chmod 0644 "${tmp}"
  mv -f "${tmp}" "${TEXTFILE_DIR}/docker_user.prom"
}

fail() {
  local code="$1"
  shift
  echo "[ERROR] $*" >&2
  write_metric
  exit "${code}"
}

validate_port_list() {
  local port
  for port in ${PORTS}; do
    if ! [[ "${port}" =~ ^[0-9]+$ ]]; then
      fail 2 "порт не число: ${port}"
    fi
    if [[ "${port}" -lt 1 || "${port}" -gt 65535 ]]; then
      fail 2 "порт вне диапазона: ${port}"
    fi
  done
}

validate_cidrs() {
  local cidr
  for cidr in "$@"; do
    if ! [[ "${cidr}" =~ ^[0-9A-Fa-f:.]+/[0-9]{1,3}$ ]]; then
      fail 2 "странный CIDR: ${cidr}"
    fi
  done
}

validate_ip() {
  local ip="$1"
  if [[ "${ip}" == "0.0.0.0" || "${ip}" == "::" || "${ip}" == "*" ]]; then
    fail 2 "MONITORING_BIND_IP=${ip} слишком широкий для ctorigdst: укажите адрес интерфейса"
  fi
  if ! [[ "${ip}" =~ ^[0-9A-Fa-f:.]+$ ]]; then
    fail 2 "странная адресная привязка: ${ip}"
  fi
}

validate_port_list
# shellcheck disable=SC2086
validate_cidrs ${ALLOW_CIDRS}
# shellcheck disable=SC2086
validate_cidrs ${ALLOW_CIDRS_V6}
validate_ip "${BIND_IP}"
validate_ip "${BIND_IP_V6}"

cid_tag() {
  printf '%s' "${1//\//_}"
}

# Сначала ALLOW, потом DROP: в одной цепочке порядок -A и есть порядок матча.
append_rules() {
  local chain="$1"
  local bind="$2"
  local cidrs="$3"
  local kind="$4"
  local port cidr tag
  for port in ${PORTS}; do
    for cidr in ${cidrs}; do
      tag="$(cid_tag "${cidr}")"
      if [[ "${kind}" == "fwd" ]]; then
        printf -- '-A %s -p tcp -s %s -m conntrack --ctdir ORIGINAL --ctorigdst %s --ctorigdstport %s -m comment --comment mon-allow-%s-%s -j RETURN\n' \
          "${chain}" "${cidr}" "${bind}" "${port}" "${port}" "${tag}"
      else
        printf -- '-A %s -p tcp -d %s -s %s -m conntrack --ctstate NEW --dport %s -m comment --comment mon-in-allow-%s-%s -j ACCEPT\n' \
          "${chain}" "${bind}" "${cidr}" "${port}" "${port}" "${tag}"
      fi
    done
  done
  for port in ${PORTS}; do
    if [[ "${kind}" == "fwd" ]]; then
      printf -- '-A %s -p tcp -m conntrack --ctdir ORIGINAL --ctorigdst %s --ctorigdstport %s -m comment --comment mon-drop-%s -j DROP\n' \
        "${chain}" "${bind}" "${port}" "${port}"
    else
      printf -- '-A %s -p tcp -d %s -m conntrack --ctstate NEW --dport %s -m comment --comment mon-in-drop-%s -j DROP\n' \
        "${chain}" "${bind}" "${port}" "${port}"
    fi
  done
}

restore_text() {
  local bind="$1"
  local cidrs="$2"
  printf '%s\n' '*filter'
  printf '%s\n' ':MONITORING-PROXY-FWD - [0:0]'
  printf '%s\n' ':MONITORING-PROXY-IN - [0:0]'
  printf '%s\n' '-F MONITORING-PROXY-FWD'
  printf '%s\n' '-F MONITORING-PROXY-IN'
  append_rules MONITORING-PROXY-FWD "${bind}" "${cidrs}" fwd
  printf '%s\n' '-A MONITORING-PROXY-FWD -j RETURN'
  append_rules MONITORING-PROXY-IN "${bind}" "${cidrs}" in
  printf '%s\n' '-A MONITORING-PROXY-IN -j RETURN'
  printf '%s\n' 'COMMIT'
}

# iptables-restore коммитит таблицу целиком: пакет видит либо старую цепочку,
# либо новую, без окна, в котором фильтр снят. Прыжок в DOCKER-USER/INPUT
# ставится только после успешного коммита.
apply_family() {
  local bin="$1"
  local bind="$2"
  local cidrs="$3"
  local restore="${bin}-restore"
  if ! command -v "${bin}" >/dev/null 2>&1 || ! command -v "${restore}" >/dev/null 2>&1; then
    echo "[WARN] ${bin} не найден, семейство пропущено" >&2
    return 1
  fi
  if ! "${bin}" -nL DOCKER-USER >/dev/null 2>&1; then
    echo "[ERROR] цепочка DOCKER-USER отсутствует (${bin})" >&2
    return 1
  fi
  restore_text "${bind}" "${cidrs}" | "${restore}" --noflush || return 1
  "${bin}" -C DOCKER-USER -j MONITORING-PROXY-FWD >/dev/null 2>&1 \
    || "${bin}" -I DOCKER-USER 1 -j MONITORING-PROXY-FWD \
    || return 1
  "${bin}" -C INPUT -j MONITORING-PROXY-IN >/dev/null 2>&1 \
    || "${bin}" -I INPUT 1 -j MONITORING-PROXY-IN \
    || return 1
  delete_legacy_rules "${bin}" || return 1
  return 0
}

# Старые правила mon-* лежали прямо в DOCKER-USER и INPUT. Снимаем их
# только после того, как новая цепочка уже в пути пакета.
delete_legacy_rules() {
  local cmd="$1"
  local chain numbers number
  for chain in DOCKER-USER INPUT; do
    if ! "${cmd}" -nL "${chain}" >/dev/null 2>&1; then
      continue
    fi
    numbers="$("${cmd}" -L "${chain}" --line-numbers -n | awk '/\/\* mon-/ { print $1 }' | sort -nr)"
    for number in ${numbers}; do
      "${cmd}" -D "${chain}" "${number}" || return 1
    done
  done
  return 0
}

if [[ "${DRY_RUN}" -eq 1 ]]; then
  printf '%s\n' 'iptables-restore --noflush <<EOF'
  restore_text "${BIND_IP}" "${ALLOW_CIDRS}"
  printf '%s\n' 'EOF'
  printf '%s\n' 'iptables -C DOCKER-USER -j MONITORING-PROXY-FWD || iptables -I DOCKER-USER 1 -j MONITORING-PROXY-FWD'
  printf '%s\n' 'iptables -C INPUT -j MONITORING-PROXY-IN || iptables -I INPUT 1 -j MONITORING-PROXY-IN'
  printf '%s\n' 'ip6tables-restore --noflush <<EOF'
  restore_text "${BIND_IP_V6}" "${ALLOW_CIDRS_V6}"
  printf '%s\n' 'EOF'
  printf '%s\n' 'ip6tables -C DOCKER-USER -j MONITORING-PROXY-FWD || ip6tables -I DOCKER-USER 1 -j MONITORING-PROXY-FWD'
  printf '%s\n' 'ip6tables -C INPUT -j MONITORING-PROXY-IN || ip6tables -I INPUT 1 -j MONITORING-PROXY-IN'
  exit 0
fi

if apply_family iptables "${BIND_IP}" "${ALLOW_CIDRS}"; then
  APPLIED_V4=1
else
  APPLIED_V4=0
fi

if apply_family ip6tables "${BIND_IP_V6}" "${ALLOW_CIDRS_V6}"; then
  APPLIED_V6=1
else
  APPLIED_V6=0
  echo "[WARN] IPv6 DOCKER-USER не применён" >&2
fi

write_metric
if [[ "${APPLIED_V4}" -ne 1 ]]; then
  echo "[ERROR] правила IPv4 не записаны" >&2
  exit 1
fi
echo "[OK] правила портов мониторинга обновлены"

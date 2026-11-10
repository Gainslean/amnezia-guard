#!/bin/bash
# AmneziaGuard — генерация правил pf (kill switch).
# Подключается из guard.sh. Печатает набор правил для якоря в stdout.
#
# Логика: всё, что идёт НЕ через туннель Amnezia, блокируется.
# Разрешено только:
#   - lo0 (локальные процессы между собой);
#   - интерфейс туннеля Amnezia (utunN, определяется по процессу Amnezia);
#   - зашифрованные пакеты самой Amnezia к серверу (её UDP-порт и выученные IP серверов);
#   - DHCP (чтобы Wi-Fi получал адрес);
#   - по желанию — локальная сеть (принтеры, AirDrop), но без DNS роутера.

IP_RE='^([0-9]{1,3}(\.[0-9]{1,3}){3}|[0-9a-fA-F]*:[0-9a-fA-F:.]*)(/[0-9]{1,3})?$'
LAN4="{ 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/4, 255.255.255.255 }"

# Читает файл со списком IP (по одному в строке, # — комментарий) и печатает через запятую.
ag_list_csv() {
  [ -f "$1" ] || return 0
  grep -v '^[[:space:]]*#' "$1" | tr -d ' \t\r' | grep -E "$IP_RE" \
    | sort -u | paste -sd, - | sed 's/,/, /g'
}

# Аргументы: $1 — интерфейсы туннеля (через пробел), $2 — UDP/TCP порты Amnezia (через пробел)
ag_build_rules() {
  local tun_ifs="$1" ports="$2" servers split extra p i

  servers="$(ag_list_csv "$AG_DIR/servers.txt")"
  extra="$(echo "${EXTRA_ALLOW:-}" | tr ' ' '\n' | grep -E "$IP_RE" | paste -sd, - | sed 's/,/, /g')"
  [ -n "$extra" ] && servers="${servers:+$servers, }$extra"
  split=""
  [ "${ALLOW_SPLIT:-0}" = "1" ] && split="$(ag_list_csv "$AG_DIR/split.txt")"

  echo "# AmneziaGuard kill switch — generated $(date '+%Y-%m-%d %H:%M:%S')"
  echo "table <ag_servers> persist { $servers }"
  [ -n "$split" ] && echo "table <ag_split> persist { $split }"

  echo "pass quick on lo0 all"
  for i in $tun_ifs; do
    echo "pass quick on $i all"
  done

  # DHCP — получить адрес от роутера (иначе Wi-Fi не поднимется вовсе)
  echo "pass out quick inet proto udp from any port 68 to any port 67"
  echo "pass in quick inet proto udp from any port 67 to any port 68"

  # Зашифрованный трафик самой Amnezia к её серверу (сокет её процесса)
  for p in $ports; do
    echo "pass out quick proto udp from any port $p to any"
    echo "pass out quick proto tcp from any port $p to any"
  done
  echo "pass out quick to <ag_servers>"
  [ -n "$split" ] && echo "pass out quick to <ag_split>"

  if [ "${ALLOW_LAN:-1}" = "1" ]; then
    # DNS к роутеру запрещаем — иначе запросы утекают провайдеру
    echo "block drop out quick proto { tcp udp } to $LAN4 port { 53, 853 }"
    echo "pass out quick inet to $LAN4"
    echo "pass in quick inet from $LAN4"
    echo "pass quick on { awdl0 llw0 } all"
    echo "pass out quick inet6 to { fe80::/10, ff00::/8 }"
    echo "pass in quick inet6 from fe80::/10"
  fi

  # Всё остальное — в никуда
  echo "block drop quick all"
}

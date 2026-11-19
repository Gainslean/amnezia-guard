#!/bin/bash
# AmneziaGuard — что служба узнаёт сама. Подключается из guard.sh.
#   - IP сервера Amnezia (чтобы переподключение шло сразу, даже при включённой защите);
#   - исключения kill switch самой Amnezia (её сервер, её API, сайты-исключения, её DNS);
#   - маршруты в обход VPN (раздельное туннелирование), если включено ALLOW_SPLIT.

remember_servers() {
  local ip changed=0
  touch "$AG_DIR/servers.txt"
  for ip in "$@"; do
    [ -z "$ip" ] && continue
    if ! grep -qx "$ip" "$AG_DIR/servers.txt"; then
      echo "$ip" >> "$AG_DIR/servers.txt"; changed=1
      log "выучен сервер Amnezia: $ip"
    fi
  done
  [ "$changed" = 1 ] && LAST_HASH=""
  return 0
}

# Куда идут UDP-пакеты с порта $1 — по таблице состояний pf (мгновенно, без ожидания пакетов).
# Формат строки: «ALL udp 192.168.1.30:49596 -> 194.152.137.38:51820 MULTIPLE:MULTIPLE».
servers_from_states() {
  pfctl -ss 2>/dev/null | awk -v p="$1" '
    { for (i = 2; i < NF; i++) if ($i == "->") {
        src = $(i-1); dst = $(i+1)
        if (src ~ ("[:\\[]" p "\\]?$") && $0 ~ /udp/) {
          sub(/\[[0-9]+\]$/, "", dst); sub(/:[0-9]+$/, "", dst); print dst } } }' | sort -u
}

# Для WireGuard/AWG сокет «не подключён» — адрес сервера видно только по трафику.
# 1) таблица состояний pf; 2) если там пусто — слушаем порт до 30 с в фоне
#    (AWG шлёт keepalive не реже раза в 25 с, так что пакет точно будет).
learn_udp_server() {
  local port="$1" phys="$2" ips
  case "$LEARNED_PORTS" in *" $port "*) return ;; esac
  ips="$(servers_from_states "$port")"
  LEARNED_PORTS="$LEARNED_PORTS$port "
  if [ -n "$ips" ]; then remember_servers $ips; return; fi
  [ -z "$phys" ] && return
  (
    out="$(mktemp -t aglearn)"
    tcpdump -n -l -c 1 -i "$phys" "udp and src port $port" > "$out" 2>/dev/null &
    pid=$!
    for _ in $(seq 1 30); do sleep 1; [ -s "$out" ] && break; done
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    remember_servers $(awk '{print $5}' "$out" | sed -E 's/\.[0-9]+:?$//' | grep -E '^[0-9a-fA-F.:]+$' | sort -u)
    [ -s "$out" ] || log "сервер для порта $port не выучен за 30 с — попробую при следующем подключении"
    rm -f "$out"
    kill -USR1 $$ 2>/dev/null
  ) &
}

# Kill switch самой Amnezia держит в pf таблицы исключений: allownets (её сервер, её API,
# сайты, которые вы исключили в Amnezia) и dnsaddr (DNS, который она себе разрешает).
# Без них Amnezia при упавшем туннеле не может получить настройки и переподключиться.
# Копируем их на диск: так они работают и при загрузке, до старта Amnezia.
AMN_NETS_TABLE="amn/110.allowNets:allownets"
AMN_DNS_TABLE="amn/310.blockDNS:dnsaddr"

amn_table() { pfctl -a "${1%%:*}" -t "${1##*:}" -T show 2>/dev/null | tr -d ' ' | grep -E "$IP_RE" | sort -u; }

sync_amnezia_exceptions() {
  [ "${AMNEZIA_EXCEPTIONS:-1}" = 1 ] || return 0
  local nets dns
  nets="$(amn_table "$AMN_NETS_TABLE")"
  dns="$(amn_table "$AMN_DNS_TABLE")"
  if [ -n "$nets" ] && [ "$nets" != "$(cat "$AG_DIR/amnezia_nets.txt" 2>/dev/null)" ]; then
    echo "$nets" > "$AG_DIR/amnezia_nets.txt"
    log "исключения Amnezia обновлены: $(echo "$nets" | wc -l | tr -d ' ') адресов"
  fi
  if [ -n "$dns" ] && [ "$dns" != "$(cat "$AG_DIR/amnezia_dns.txt" 2>/dev/null)" ]; then
    echo "$dns" > "$AG_DIR/amnezia_dns.txt"
    log "DNS Amnezia: $(echo "$dns" | paste -sd' ' -)"
  fi
  return 0
}

# Раздельное туннелирование: адреса, которые Amnezia сама пускает мимо VPN
learn_split() {
  local phys="$1" gw="$2"
  [ "$ALLOW_SPLIT" = "1" ] && [ -n "$gw" ] || return 0
  netstat -rn -f inet | awk -v gw="$gw" -v ifc="$phys" '
    $2==gw && $NF==ifc && $1!="default" {
      d=$1; m=""; if (index(d,"/")) { split(d,x,"/"); d=x[1]; m=x[2] }
      n=split(d,o,"."); if (m=="") m=(n==4?32:n*8)
      while (n<4) { d=d".0"; n++ }
      print d"/"m }' >> "$AG_DIR/split.txt"
  sort -u -o "$AG_DIR/split.txt" "$AG_DIR/split.txt"
}

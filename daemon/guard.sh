#!/bin/bash
# AmneziaGuard — системная служба (root, LaunchDaemon).
# Реагирует на события сети мгновенно (сторож agwatch будит службу за миллисекунды),
# плюс каждые 0,25 с дешёвая проверка: pf включён, правила на месте, интерфейсы те же.
# Находит туннель Amnezia, держит правила pf так, чтобы трафик шёл ТОЛЬКО через него,
# и пишет status.json для иконки в строке меню.
# Если служба упадёт — правила остаются (безопасный отказ: интернет закрыт, а не открыт).

AG_DIR="${AG_DIR:-/Library/Application Support/AmneziaGuard}"
ANCHOR="com.apple/000.AmneziaGuard"
STATUS="$AG_DIR/status.json"
PATH="${AG_TEST_PATH:+$AG_TEST_PATH:}/usr/bin:/bin:/usr/sbin:/sbin"  # AG_TEST_PATH — только для тестов

# Настройки по умолчанию (переопределяются в config)
PROC_PATTERN='AmneziaVPNNetworkExtension|AmneziaVPN-service|amneziawg-go'
ALLOW_LAN=1
ALLOW_SPLIT=0
AMNEZIA_EXCEPTIONS=1   # пропускать исключения kill switch самой Amnezia (её сервер, API, DNS)
EXTRA_ALLOW=""
FAST_INTERVAL=0.25  # дешёвая проверка pf и интерфейсов (4 раза в секунду)
FULL_INTERVAL=5     # полная проверка на всякий случай (основное — по событиям)

. "$AG_DIR/rules.sh"
. "$AG_DIR/learn.sh"
[ -f "$AG_DIR/config" ] && . "$AG_DIR/config"

LAST_HASH=""
RULES_OK=false
BLOCKED_BASE=0
LEARNED_PORTS=" "; PREV_CAND=""; LEARNER_PID=""
TMP_RULES="$(mktemp -t agrules)"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

# Выключено ли вручную; временное выключение (agctl off N) истекает само.
reenable_at() { local t; t="$(cat "$AG_DIR/reenable_at" 2>/dev/null)"; [[ "$t" =~ ^[0-9]+$ ]] && echo "$t" || echo 0; }

# Без запуска внешних программ (read — встроенная команда): вызывается 4 раза в секунду.
is_enabled() {
  local v=1 t=0
  [ -f "$AG_DIR/enabled" ] && read -r v < "$AG_DIR/enabled"
  [ "$v" = "0" ] || return 0
  [ -f "$AG_DIR/reenable_at" ] && read -r t < "$AG_DIR/reenable_at"
  if [[ "$t" =~ ^[0-9]+$ ]] && [ "$t" -gt 0 ] && [ "$(date +%s)" -ge "$t" ]; then
    echo 1 > "$AG_DIR/enabled"; rm -f "$AG_DIR/reenable_at"
    log "временное выключение истекло — защита снова ВКЛЮЧЕНА"
    return 0
  fi
  return 1
}

# Проверки без конвейеров (| head | grep): один запуск pfctl, сравнение — встроенное в bash.
pf_enabled() { [[ "$(pfctl -s info 2>/dev/null)" == *"Status: Enabled"* ]]; }

anchor_loaded() { [[ "$(pfctl -a "$ANCHOR" -sr 2>/dev/null)" == *"block drop"* ]]; }

# Физический интерфейс и шлюз (default-маршрут не через utun)
phys_route() {
  netstat -rn -f inet | awk '$1=="default" && $NF !~ /^(utun|lo|ipsec|ppp)/ {print $NF, $2; exit}'
}

# PID процессов Amnezia (кроме нас самих)
amnezia_pids() { pgrep -f "$PROC_PATTERN" | grep -v "^$$\$" | paste -sd, -; }

# Один вызов lsof на всё (туннель + сокеты): lsof — самая медленная часть проверки.
lsof_amnezia() { lsof -nP -a -p "$1" > "$TMP_RULES.lsof" 2>/dev/null; }

# Интерфейс туннеля: процесс Amnezia держит сокет utun_control unit N -> utun(N-1)
find_tun() {
  local units
  units="$(grep 'utun_control' "$TMP_RULES.lsof" \
    | sed -n 's/.*unit \([0-9][0-9]*\).*/\1/p' | sort -un)"
  for u in $units; do echo "utun$((u - 1))"; done | paste -sd' ' -
}

# Порты сокетов Amnezia и удалённые адреса (серверы)
# Сокет туннеля AWG/WireGuard — один долгоживущий UDP-сокет не на петле. Кроме него у Amnezia
# бывают сотни коротких: DNS-запросы, связь между её процессами через [::1]. Их не берём:
#   - TCP, петля (127.*, [::1]) и соединения на порт 53/853 — отбрасываем сразу;
#   - если кандидатов больше 3, берём только те, что живы со прошлой проверки.
# SOCK_REMOTES — куда подключены именно эти сокеты (для WireGuard обычно пусто).
scan_sockets() {
  local cand stable
  awk '$5 ~ /^IPv[46]$/ && $8 == "UDP" {print $9}' "$TMP_RULES.lsof" \
    | grep -v -E '^(127\.|\[::1\]|localhost)' | grep -v -E -- '->(127\.|\[::1\])' \
    | grep -v -E ':(53|853)$' > "$TMP_RULES.sock"
  cand="$(awk '{split($1,a,"->"); n=split(a[1],b,":"); print b[n]}' "$TMP_RULES.sock" \
    | grep -E '^[0-9]+$' | sort -un)"
  if [ "$(printf '%s\n' "$cand" | grep -c .)" -gt 3 ]; then
    stable="$(printf '%s\n' "$cand" | grep -Fx -f <(printf '%s\n' $PREV_CAND) 2>/dev/null)"
    PREV_CAND="$cand"; cand="$stable"
  else
    PREV_CAND="$cand"
  fi
  SOCK_PORTS="$(printf '%s\n' $cand | grep . | head -3 | paste -sd' ' -)"
  SOCK_REMOTES="$(for p in $SOCK_PORTS; do
      awk -v p="$p" '{split($1,a,"->"); n=split(a[1],b,":"); if (b[n]==p && a[2]!="") {
        r=a[2]; sub(/:[0-9]+$/,"",r); gsub(/[\[\]]/,"",r); print r } }' "$TMP_RULES.sock"
    done | sort -u)"
}

blocked_now() {
  pfctl -a "$ANCHOR" -vsr 2>/dev/null | awk '
    /^block/ {b=1; next}
    b && /Packets:/ {for(i=1;i<=NF;i++) if($i=="Packets:") s+=$(i+1); b=0; next}
    {b=0} END {print s+0}'
}

json_arr() { [ -z "$1" ] && { printf '[]'; return; }; printf '["%s"]' "$(echo "$1" | sed 's/ /","/g')"; }

write_status() {
  local tmp="$STATUS.tmp" servers
  servers="$(ag_list_csv "$AG_DIR/servers.txt" | sed 's/, / /g')"
  cat > "$tmp" <<EOF
{"ts":$(date +%s),"enabled":$1,"pf":$2,"rules":$3,"vpn_proc":$4,"vpn_up":$5,
"vpn_if":"$6","phys_if":"$7","ports":$(json_arr "$8"),"servers":$(json_arr "$servers"),
"blocked":$9,"allow_lan":$ALLOW_LAN,"allow_split":$ALLOW_SPLIT,"reenable_at":$(reenable_at)}
EOF
  chmod 644 "$tmp"; mv -f "$tmp" "$STATUS"
}

apply_rules() {
  local tun="$1" ports="$2" h
  ag_build_rules "$tun" "$ports" > "$TMP_RULES"
  h="$(tail -n +2 "$TMP_RULES" | md5 -q)"
  if [ "$h" != "$LAST_HASH" ] || ! anchor_loaded; then
    BLOCKED_BASE=$((BLOCKED_BASE + $(blocked_now)))
    if pfctl -a "$ANCHOR" -f "$TMP_RULES" 2>"$TMP_RULES.err"; then
      LAST_HASH="$h"; RULES_OK=true
      cp "$TMP_RULES" "$AG_DIR/rules.active"   # сторож вернёт их мгновенно, если снимут
      log "правила обновлены: туннель=[${tun:-нет}] порты=[${ports:-нет}]"
    else
      log "ОШИБКА pfctl: $(tr '\n' ' ' < "$TMP_RULES.err")"; RULES_OK=false
    fi
  else
    RULES_OK=true
  fi
  if ! pf_enabled; then
    pfctl -E >/dev/null 2>&1 && log "pf был выключен — включён снова"
  fi
}

tick() {
  local pids tun ports phys gw vpn_up=false proc=false en=false pfon=false rl=false p
  read -r phys gw <<< "$(phys_route)"
  pids="$(amnezia_pids)"
  tun=""; ports=""
  if [ -n "$pids" ]; then
    proc=true
    lsof_amnezia "$pids"
    tun="$(find_tun)"
    if [ -z "$tun" ]; then   # запасной путь: интерфейс default-маршрута, если это utun
      tun="$(netstat -rn -f inet | awk '$1=="default" && $NF ~ /^utun/ {print $NF; exit}')"
    fi
    scan_sockets
    ports="$SOCK_PORTS"
    remember_servers $SOCK_REMOTES
    for t in $tun; do
      ifconfig "$t" 2>/dev/null | grep -q 'inet ' && vpn_up=true
    done
  fi

  # учимся всегда, даже при выключенной защите: тогда включение потом сработает сразу
  sync_amnezia_exceptions; clean_servers
  if [ "$vpn_up" = true ]; then
    for p in $ports; do learn_udp_server "$p" "$phys"; done
    learn_split "$phys" "$gw"
  fi

  if is_enabled; then
    en=true
    apply_rules "$tun" "$ports"
  elif [ -n "$LAST_HASH" ] || anchor_loaded; then
    pfctl -a "$ANCHOR" -F all >/dev/null 2>&1
    LAST_HASH=""; log "защита ВЫКЛЮЧЕНА пользователем"
  fi

  pf_enabled && pfon=true
  [ "$en" = true ] && rl="$RULES_OK"
  write_status "$en" "$pfon" "$rl" "$proc" "$vpn_up" "${tun%% *}" "$phys" "$ports" \
    "$((BLOCKED_BASE + $(blocked_now)))"
}

# Для тестов: AG_TEST=1 . guard.sh — только функции, без цикла
[ "${AG_TEST:-}" = 1 ] && return 0

# Запасная проверка, если сторож agwatch не запущен (обычно её делает он, в 10 раз дешевле).
fast_guard() {
  is_enabled || { [ -n "$LAST_HASH" ] && WAKE=1; return; }
  if ! pf_enabled; then
    pfctl -E >/dev/null 2>&1; log "pf кто-то выключил — включён обратно"; WAKE=1
  fi
  if ! anchor_loaded; then   # вернуть последние правила сразу, без полной проверки
    [ -s "$AG_DIR/rules.active" ] && pfctl -a "$ANCHOR" -f "$AG_DIR/rules.active" 2>/dev/null
    log "правила кто-то снял — восстановлены"; WAKE=1
  fi
}

WATCH_PID=""; WATCH_STARTED=-100
start_watcher() {
  [ -x "$AG_DIR/agwatch" ] || return 0
  [ $((SECONDS - WATCH_STARTED)) -ge 5 ] || return 0   # не чаще раза в 5 с
  WATCH_STARTED=$SECONDS
  "$AG_DIR/agwatch" $$ "$ANCHOR" "$AG_DIR" & WATCH_PID=$!
}

WAKE=1
trap 'WAKE=1' HUP USR1  # HUP — от agctl, USR1 — от сторожа сети и фонового обучения
trap 'log "служба остановлена (правила оставлены)"; rm -f "$TMP_RULES"*
      [ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null; pkill -P $$ 2>/dev/null; exit 0' TERM INT

log "AmneziaGuard запущен"
pfctl -E >/dev/null 2>&1   # своя ссылка на pf: чужой «pfctl -X» его не выключит
start_watcher
LAST_FULL=0; IFSIG=""
while true; do
  watching=false
  [ -n "$WATCH_PID" ] && kill -0 "$WATCH_PID" 2>/dev/null && watching=true
  now=$SECONDS
  # без сторожа сами следим за списком интерфейсов (со сторожем об этом сообщают события)
  if [ "$watching" = true ]; then sig="$IFSIG"; else sig="$(ifconfig -lu)"; fi
  if [ "$WAKE" = 1 ] || [ "$sig" != "$IFSIG" ] || [ $((now - LAST_FULL)) -ge "$FULL_INTERVAL" ]; then
    WAKE=0; IFSIG="$sig"
    [ -f "$AG_DIR/config" ] && . "$AG_DIR/config"
    tick; LAST_FULL=$now
  elif [ "$watching" = false ]; then
    fast_guard
  fi
  if [ -n "$WATCH_PID" ] && [ "$watching" = false ] && [ $((SECONDS - WATCH_STARTED)) -ge 5 ]; then
    log "сторож перезапущен"; start_watcher
  fi
  if [ "$WAKE" = 1 ]; then
    sleep 0.05              # склеить пачку событий (Amnezia добавляет десятки маршрутов разом)
  elif [ "$watching" = true ]; then
    sleep "$FULL_INTERVAL" & wait $!   # сторож разбудит сигналом, если что-то случится
  else
    sleep "$FAST_INTERVAL" & wait $!
  fi
done

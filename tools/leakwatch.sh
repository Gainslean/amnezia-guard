#!/bin/bash
# Слушает физический интерфейс и показывает всё, что ИДЁТ НАРУЖУ мимо VPN-сервера.
# Исходящие пакеты, заблокированные pf, сюда не попадают (pf режет их раньше),
# поэтому любая строка «ИСХОДЯЩИЙ» = реальная утечка.  Запуск: sudo bash leakwatch.sh [секунд]
SECS="${1:-15}"
AG="/Library/Application Support/AmneziaGuard"
PHYS="$(python3 -c "import json;print(json.load(open('$AG/status.json'))['phys_if'])")"
MYIP="$(ipconfig getifaddr "$PHYS")"
SERVERS="$(grep -E '^[0-9.]+$' "$AG/servers.txt" | sed 's/^/host /' | paste -sd' ' - | sed 's/ host / or host /g')"
FILTER="not ($SERVERS) and not net 192.168.0.0/16 and not net 10.0.0.0/8 and not net 224.0.0.0/4 and not broadcast and not ip6 multicast"

echo "Интерфейс $PHYS ($MYIP), сервер(ы): $(paste -sd' ' "$AG/servers.txt")"
echo "Слушаю $SECS с всё, что не к VPN-серверу и не в локалку..."
OUT="$(mktemp)"
tcpdump -n -l -i "$PHYS" "$FILTER" > "$OUT" 2>/dev/null &
PID=$!
sleep "$SECS"; kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null

echo
echo "=== ИСХОДЯЩИЕ мимо VPN (утечка, если есть):"
grep -E " IP6? ${MYIP//./\\.}\." "$OUT" | awk '{print $5}' | sed -E 's/\.[0-9]+:?$//' | sort | uniq -c | sort -rn | head -20
[ -z "$(grep -E " IP6? ${MYIP//./\\.}\." "$OUT")" ] && echo "   нет — наружу мимо VPN ничего не ушло ✓"
echo
echo "=== ВХОДЯЩИЕ извне (pf их отбрасывает, это ответы на старые соединения):"
grep -vE " IP6? ${MYIP//./\\.}\." "$OUT" | awk '{print $3}' | sed -E 's/\.[0-9]+$//' | sort | uniq -c | sort -rn | head -10
echo
echo "=== Состояния pf к адресам вне VPN (должно быть пусто):"
pfctl -ss 2>/dev/null | grep -v -E "$(paste -sd'|' "$AG/servers.txt")" | grep -F "$MYIP" | head -10
echo "=== Заблокировано правилом: $(pfctl -a com.apple/000.AmneziaGuard -vsr 2>/dev/null | awk '/^block drop quick all/{getline; for(i=1;i<=NF;i++) if($i=="Packets:") print $(i+1)}') пакетов"
rm -f "$OUT"

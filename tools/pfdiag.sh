#!/bin/bash
# Диагностика pf: только читает. Показывает главный набор правил, все якоря (свои и чужие,
# например kill switch самой Amnezia), сокеты Amnezia и наши правила.
# Запуск: sudo bash tools/pfdiag.sh [файл-отчёт]
OUT="${1:-/tmp/agdiag.txt}"
AG="/Library/Application Support/AmneziaGuard"
{
  echo "=== $(date '+%F %T')  macOS $(sw_vers -productVersion)"
  echo "=== pf info";            pfctl -s info 2>&1 | head -3
  echo "=== ссылки pf -E (токены)"; pfctl -s References 2>&1 | head -10
  echo "=== главный набор правил"; pfctl -sr 2>&1
  echo "=== главный: nat/rdr";   pfctl -sn 2>&1 | head -10
  echo "=== все якоря (рекурсивно, с правилами)"
  dump() {  # $1 — полный путь якоря
    echo "--- якорь $1"; pfctl -a "$1" -sr 2>&1 | grep -v ALTQ
    for t in $(pfctl -a "$1" -s Tables 2>/dev/null); do
      echo "    таблица <$t>: $(pfctl -a "$1" -t "$t" -T show 2>/dev/null | tr -s ' \n' ' ' | cut -c1-400)"
    done
    for sub in $(pfctl -a "$1" -sA 2>/dev/null | sed 's/^ *//'); do dump "$sub"; done
  }
  for top in $(pfctl -sA 2>/dev/null | sed 's/^ *//'); do dump "$top"; done
  echo "=== таблицы главного набора"; for t in $(pfctl -s Tables 2>/dev/null); do echo "--- $t"; pfctl -t "$t" -T show 2>&1 | head -5; done
  echo "=== наш якорь (счётчики)"; pfctl -a com.apple/000.AmneziaGuard -vsr 2>&1 | head -40
  echo "=== процессы Amnezia";    pgrep -fl -i amnezia
  echo "=== сокеты Amnezia";      for p in $(pgrep -f -i 'amneziawg-go|AmneziaVPN-service|AmneziaVPN$'); do lsof -nP -a -p "$p" -i 2>/dev/null | awk 'NR>1{print $1,$2,$8,$9,$10}'; lsof -nP -a -p "$p" 2>/dev/null | grep utun_control | awk '{print $1,$2,$NF}'; done
  echo "=== маршруты default";    netstat -rn -f inet | awk '$1=="default"||$1=="0/1"||$1=="128.0/1"'
  echo "=== DNS";                 scutil --dns | awk '/resolver #[12]$/{f=1} f&&/nameserver|if_index/' | head -6
  echo "=== статус AmneziaGuard"; cat "$AG/status.json"
} > "$OUT" 2>&1
chmod 644 "$OUT"
echo "Готово: $OUT"

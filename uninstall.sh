#!/bin/bash
# Полное удаление AmneziaGuard и снятие правил. Запуск:  sudo ./uninstall.sh
AG_DIR="/Library/Application Support/AmneziaGuard"
[ "$(id -u)" = 0 ] || { echo "Запустите так: sudo ./uninstall.sh"; exit 1; }
USER_ID="$(id -u "${SUDO_USER:-$(stat -f %Su /dev/console)}")"

launchctl bootout "gui/$USER_ID" /Library/LaunchAgents/com.amneziaguard.menubar.plist 2>/dev/null
launchctl bootout system /Library/LaunchDaemons/com.amneziaguard.daemon.plist 2>/dev/null
pkill -f "$AG_DIR/guard.sh" 2>/dev/null
pfctl -a com.apple/000.AmneziaGuard -F all >/dev/null 2>&1
rm -f /Library/LaunchAgents/com.amneziaguard.menubar.plist \
      /Library/LaunchDaemons/com.amneziaguard.daemon.plist \
      /etc/newsyslog.d/amnezia-guard.conf
rm -rf /Applications/AmneziaGuard.app "$AG_DIR"
echo "AmneziaGuard удалён, правила сняты — интернет работает как обычно."

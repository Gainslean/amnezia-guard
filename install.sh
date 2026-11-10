#!/bin/bash
# Установка AmneziaGuard. Запуск:  sudo ./install.sh
# Ставит: службу kill switch (root, всегда работает, стартует при загрузке)
#         + приложение со значком в строке меню (стартует при входе).
set -euo pipefail
cd "$(dirname "$0")"
AG_DIR="/Library/Application Support/AmneziaGuard"
DAEMON=/Library/LaunchDaemons/com.amneziaguard.daemon.plist
AGENT=/Library/LaunchAgents/com.amneziaguard.menubar.plist
APP=/Applications/AmneziaGuard.app

[ "$(id -u)" = 0 ] || { echo "Запустите так: sudo ./install.sh"; exit 1; }
USER_NAME="${SUDO_USER:-$(stat -f %Su /dev/console)}"
USER_ID="$(id -u "$USER_NAME")"

if [ ! -d build/AmneziaGuard.app ] || [ ! -x build/agwatch ]; then
  echo "• сборка приложения (от имени $USER_NAME)"
  sudo -u "$USER_NAME" ./build.sh
fi

if ! pgrep -f 'AmneziaVPNNetworkExtension|AmneziaVPN-service|amneziawg-go' >/dev/null; then
  echo
  echo "ВНИМАНИЕ: AmneziaVPN сейчас не подключён."
  echo "Сразу после установки интернет будет закрыт, пока вы не подключите Amnezia."
  read -r -p "Продолжить? [y/N] " ans
  [[ "$ans" =~ ^[yYдД] ]] || exit 1
fi

echo "• служба"
mkdir -p "$AG_DIR"
install -m 755 -o root -g wheel daemon/guard.sh daemon/agctl "$AG_DIR/"
install -m 644 -o root -g wheel daemon/rules.sh "$AG_DIR/"
install -m 755 -o root -g wheel build/agwatch "$AG_DIR/"
[ -f "$AG_DIR/config" ] || install -m 644 -o root -g wheel daemon/config.default "$AG_DIR/config"
[ -f "$AG_DIR/enabled" ] || echo 1 > "$AG_DIR/enabled"
touch "$AG_DIR/servers.txt" "$AG_DIR/split.txt"
chown root:wheel "$AG_DIR" "$AG_DIR"/*; chmod 755 "$AG_DIR"

cat > "$DAEMON" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.amneziaguard.daemon</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$AG_DIR/guard.sh</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/var/log/amnezia-guard.log</string>
  <key>StandardErrorPath</key><string>/var/log/amnezia-guard.log</string>
</dict></plist>
PL
chown root:wheel "$DAEMON"; chmod 644 "$DAEMON"
echo "/var/log/amnezia-guard.log  644  3  1000  *  J" > /etc/newsyslog.d/amnezia-guard.conf
launchctl bootout system "$DAEMON" 2>/dev/null || true
launchctl bootstrap system "$DAEMON"

echo "• приложение"
launchctl bootout "gui/$USER_ID" "$AGENT" 2>/dev/null || true
rm -rf "$APP"; ditto build/AmneziaGuard.app "$APP"; chown -R root:wheel "$APP"
cat > "$AGENT" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.amneziaguard.menubar</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/AmneziaGuard</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict></plist>
PL
chown root:wheel "$AGENT"; chmod 644 "$AGENT"
launchctl bootstrap "gui/$USER_ID" "$AGENT" 2>/dev/null || sudo -u "$USER_NAME" open "$APP"

sleep 3
echo
echo "Готово. Значок щита — в строке меню справа вверху."
echo "Состояние:     \"$AG_DIR/agctl\" status"
echo "АВАРИЙНО выключить защиту:  sudo \"$AG_DIR/agctl\" off"
echo "Удалить:       sudo ./uninstall.sh"

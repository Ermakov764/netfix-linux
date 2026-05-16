#!/bin/bash
# Установка netfix: скрипт в /usr/local/bin + alias netfix в shell

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="${SCRIPT_DIR}/netfix.sh"
TARGET="/usr/local/bin/netfix"
ALIAS_LINE='alias netfix="sudo /usr/local/bin/netfix"'

if [ ! -f "$SOURCE" ]; then
    echo "Ошибка: не найден $SOURCE"
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    echo "Запустите с sudo: sudo ./install.sh"
    exit 1
fi

echo "→ Установка: $TARGET"
cp "$SOURCE" "$TARGET"
chmod 755 "$TARGET"

echo "→ Проверка синтаксиса"
bash -n "$TARGET"

alias_added=0
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    for rc in "$home/.bashrc" "$home/.zshrc"; do
        [ -f "$rc" ] || continue
        if grep -qF 'alias netfix=' "$rc" 2>/dev/null; then
            echo "→ Alias уже есть: $rc"
            alias_added=1
        else
            echo "" >> "$rc"
            echo "# netfix — сброс сети после Docker/K8s" >> "$rc"
            echo "$ALIAS_LINE" >> "$rc"
            echo "→ Alias добавлен: $rc"
            alias_added=1
        fi
    done
fi

echo ""
if [ "$alias_added" -eq 1 ]; then
    echo "✅ Готово. В этом или новом терминале:"
    echo ""
    echo "   source ~/.bashrc    # один раз в текущем окне"
    echo "   netfix"
else
    echo "✅ Скрипт установлен: $TARGET"
    echo ""
    echo "Добавьте alias вручную (~/.bashrc):"
    echo "   $ALIAS_LINE"
    echo ""
    echo "Затем: source ~/.bashrc && netfix"
fi
echo ""
echo "Логи:    /var/log/network-reset-*.log"
echo "Бэкапы:  /var/backups/network-*"

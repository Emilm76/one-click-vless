#!/bin/bash

# ─────────────────────────────────────────────
# Удаление Xray VLESS + XTLS-Reality
# ─────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    log_error "Скрипт должен быть запущен от root"
    exit 1
fi

log_warn "Это удалит Xray и все данные пользователей."
read -rp "Продолжить? (y/n): " confirm
[[ "$confirm" != "y" ]] && exit 0

# Останавливаем и отключаем службу
log_info "Остановка службы Xray..."
systemctl stop xray    2>/dev/null
systemctl disable xray 2>/dev/null

# Удаляем через официальный uninstall если доступен
if [[ -f /usr/local/bin/xray ]]; then
    log_info "Запуск официального деинсталлятора..."
    bash -c "$(curl -4 -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove 2>/dev/null \
        || log_warn "Официальный деинсталлятор не сработал, удаляем вручную"
fi

# Удаляем файлы и конфиги
log_info "Удаление файлов..."
rm -f  /usr/local/bin/xray
rm -rf /usr/local/etc/xray
rm -rf /usr/local/share/xray
rm -f  /var/log/xray/access.log
rm -f  /var/log/xray/error.log
rmdir  /var/log/xray 2>/dev/null

# Удаляем systemd-юниты
rm -f /etc/systemd/system/xray.service
rm -rf /etc/systemd/system/xray.service.d
systemctl daemon-reload

# Удаляем утилиты управления
log_info "Удаление утилит..."
rm -f /usr/local/bin/{userlist,mainuser,newuser,rmuser,sharelink}

# Удаляем справку
rm -f "$HOME/help"

# Удаляем группу xray если существует
if getent group xray > /dev/null 2>&1; then
    groupdel xray 2>/dev/null && log_info "Группа xray удалена"
fi

log_info "Xray успешно удалён."
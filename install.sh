#!/bin/bash

set -e

PORT=443
SNI="github.com"
XHTTP_PATH="/$(openssl rand -hex 8)"
KEYS_FILE="/usr/local/etc/xray/.keys"
CONFIG="/usr/local/etc/xray/config.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Скрипт должен быть запущен от root"
        exit 1
    fi
}

check_reinstall() {
    if [[ -f "$CONFIG" ]]; then
        log_warn "Xray уже установлен. Переустановка удалит существующих пользователей."
        read -rp "Продолжить? (y/n): " confirm
        [[ "$confirm" != "y" ]] && exit 0
    fi
}

generate_link() {
    local email="$1"
    local uuid="$2"
    local ip
    ip=$(curl -4 -s --max-time 5 icanhazip.com \
        || curl -4 -s --max-time 5 api.ipify.org \
        || { log_error "Не удалось определить IP-адрес сервера"; exit 1; })

    local pbk sid sni protocol port path
    pbk=$(awk -F': ' '/PublicKey/ {print $2}' "$KEYS_FILE")
    sid=$(awk -F': ' '/shortsid/ {print $2}' "$KEYS_FILE")
    sni=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$CONFIG")
    protocol=$(jq -r '.inbounds[0].protocol' "$CONFIG")
    port=$(jq -r '.inbounds[0].port' "$CONFIG")
    path=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path' "$CONFIG")

    echo "$protocol://$uuid@$ip:$port?security=reality&sni=$sni&fp=firefox&pbk=$pbk&sid=$sid&spx=$(printf '%s' "$path" | python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read()))")&type=xhttp&flow=xtls-rprx-vision&encryption=none#$email"
}

check_root
check_reinstall

# Ask the operator for IPs to whitelist in fail2ban (optional).
# This replaces the previously hardcoded author IP.
ask_whitelist_ip() {
    echo ""
    log_info "Настройка белого списка fail2ban (необязательно)."
    log_info "Укажите IP-адреса, которые никогда не будут заблокированы (например, ваш домашний IP)."
    log_info "Введите адреса через пробел, или нажмите Enter, чтобы пропустить."
    read -rp "IP для белого списка: " WHITELIST_INPUT

    FAIL2BAN_IGNOREIP="127.0.0.1/8 ::1"
    if [[ -n "$WHITELIST_INPUT" ]]; then
        # Validate: accept only IPv4, IPv6, and CIDR entries; reject everything else.
        for entry in $WHITELIST_INPUT; do
            if [[ "$entry" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] || \
               [[ "$entry" =~ ^[0-9a-fA-F:]+(/[0-9]{1,3})?$ ]]; then
                FAIL2BAN_IGNOREIP+=" $entry"
            else
                log_warn "Пропущена невалидная запись: '$entry'"
            fi
        done
    fi
    log_info "Белый список fail2ban: $FAIL2BAN_IGNOREIP"
}

ask_whitelist_ip

log_info "Будет установлен Vless с транспортом XHTTP"
sleep 2

log_info "Установка зависимостей..."
apt update -q
apt install -y qrencode curl jq ufw fail2ban python3

if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    log_info "BBR уже включён"
else
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
    log_info "BBR включён"
fi

log_info "Установка Xray-core..."
if ! bash -c "$(curl -4 -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install; then
    log_error "Не удалось установить Xray-core"
    exit 1
fi

log_info "Генерация ключей..."
x25519_out=$(xray x25519 2>&1)
privatkey=$(echo "$x25519_out" | awk 'NR==1 {print $NF}')
pubkey=$(echo "$x25519_out"    | awk 'NR==2 {print $NF}')

if [[ -z "$privatkey" || -z "$pubkey" ]]; then
    log_error "Не удалось получить ключи X25519. Вывод xray x25519:"
    log_error "$x25519_out"
    exit 1
fi

rm -f "$KEYS_FILE"
touch "$KEYS_FILE"
chmod 600 "$KEYS_FILE"

echo "shortsid: $(openssl rand -hex 8)" >> "$KEYS_FILE"
echo "uuid: $(xray uuid)"               >> "$KEYS_FILE"
echo "PrivateKey: $privatkey"           >> "$KEYS_FILE"
echo "PublicKey: $pubkey"               >> "$KEYS_FILE"

uuid=$(awk -F': ' '/uuid/ {print $2}'        "$KEYS_FILE")
privatkey=$(awk -F': ' '/PrivateKey/ {print $2}' "$KEYS_FILE")
shortsid=$(awk -F': ' '/shortsid/ {print $2}'    "$KEYS_FILE")
pubkey_check=$(awk -F': ' '/PublicKey/ {print $2}' "$KEYS_FILE")

if [[ -z "$pubkey_check" ]]; then
    log_error "PublicKey не записан в $KEYS_FILE. Содержимое файла:"
    cat "$KEYS_FILE" >&2
    exit 1
fi

log_info "Создание конфигурации..."
cat > "$CONFIG" << EOF
{
    "log": {
        "loglevel": "warning"
    },
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {
                "type": "field",
                "domain": ["geosite:category-ads-all"],
                "outboundTag": "block"
            }
        ]
    },
    "inbounds": [
        {
            "listen": "0.0.0.0",
            "port": $PORT,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "email": "main",
                        "id": "$uuid",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "xhttp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "$SNI:443",
                    "xver": 0,
                    "serverNames": ["$SNI", "www.$SNI"],
                    "privateKey": "$privatkey",
                    "minClientVer": "",
                    "maxClientVer": "",
                    "maxTimeDiff": 0,
                    "shortIds": ["$shortsid"]
                },
                "xhttpSettings": {
                    "path": "$XHTTP_PATH",
                    "host": "$SNI",
                    "mode": "auto"
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls"]
            }
        }
    ],
    "outbounds": [
        {"protocol": "freedom", "tag": "direct"},
        {"protocol": "blackhole", "tag": "block"}
    ],
    "policy": {
        "levels": {
            "0": {"handshake": 3, "connIdle": 180}
        }
    }
}
EOF

chmod 600 "$CONFIG"

if ! jq empty "$CONFIG" 2>/dev/null; then
    log_error "Конфиг содержит ошибки JSON"
    exit 1
fi

log_info "Настройка UFW..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow "$PORT"/tcp
ufw --force enable
log_info "UFW настроен"

log_info "Настройка fail2ban..."
cat > /etc/fail2ban/jail.d/xray.conf << F2B
[DEFAULT]
ignoreip = ${FAIL2BAN_IGNOREIP}

[sshd]
enabled  = true
port     = ssh
findtime = 600
maxretry = 3
bantime = 43200

[xray-auth]
enabled  = true
port     = 443
logpath  = /var/log/xray/access.log
maxretry = 10
bantime  = 43200
findtime = 300
filter   = xray-auth
F2B

cat > /etc/fail2ban/filter.d/xray-auth.conf << 'F2B'
[Definition]
failregex = .*rejected.*<HOST>.*
            .*failed.*<HOST>.*
ignoreregex =
F2B

systemctl enable fail2ban
systemctl restart fail2ban
log_info "fail2ban настроен"

cat > /usr/local/bin/userlist << 'EOF'
#!/bin/bash
CONFIG="/usr/local/etc/xray/config.json"
emails=($(jq -r '.inbounds[0].settings.clients[].email' "$CONFIG"))
if [[ ${#emails[@]} -eq 0 ]]; then
    echo "Список клиентов пуст"
    exit 1
fi
echo "Список клиентов:"
for i in "${!emails[@]}"; do
    echo "$((i+1)). ${emails[$i]}"
done
EOF

cat > /usr/local/bin/mainuser << 'SCRIPT'
#!/bin/bash
CONFIG="/usr/local/etc/xray/config.json"
KEYS_FILE="/usr/local/etc/xray/.keys"

generate_link() {
    local email="$1" uuid="$2"
    local ip pbk sid sni protocol port path
    ip=$(curl -4 -s --max-time 5 icanhazip.com || curl -4 -s --max-time 5 api.ipify.org)
    [[ -z "$ip" ]] && { echo "Ошибка: не удалось определить IP"; exit 1; }
    pbk=$(awk -F': ' '/PublicKey/ {print $2}' "$KEYS_FILE")
    sid=$(awk -F': ' '/shortsid/ {print $2}' "$KEYS_FILE")
    sni=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$CONFIG")
    protocol=$(jq -r '.inbounds[0].protocol' "$CONFIG")
    port=$(jq -r '.inbounds[0].port' "$CONFIG")
    path=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path' "$CONFIG")
    local enc_path
    enc_path=$(printf '%s' "$path" | python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read()))")
    echo "$protocol://$uuid@$ip:$port?security=reality&sni=$sni&fp=firefox&pbk=$pbk&sid=$sid&spx=$enc_path&type=xhttp&flow=xtls-rprx-vision&encryption=none#$email"
}

uuid=$(awk -F': ' '/uuid/ {print $2}' "$KEYS_FILE")
link=$(generate_link "main" "$uuid")
echo ""
echo "Ссылка для подключения:"
echo "$link"
echo ""
echo "QR-код:"
echo "$link" | qrencode -t ansiutf8
SCRIPT

cat > /usr/local/bin/newuser << 'SCRIPT'
#!/bin/bash
CONFIG="/usr/local/etc/xray/config.json"
KEYS_FILE="/usr/local/etc/xray/.keys"
TMP=$(mktemp)

if [[ $EUID -ne 0 ]]; then
    echo "Требуются права root. Запустите: sudo newuser"
    exit 1
fi

generate_link() {
    local email="$1" uuid="$2"
    local ip pbk sid sni protocol port path
    ip=$(curl -4 -s --max-time 5 icanhazip.com || curl -4 -s --max-time 5 api.ipify.org)
    [[ -z "$ip" ]] && { echo "Ошибка: не удалось определить IP"; exit 1; }
    pbk=$(awk -F': ' '/PublicKey/ {print $2}' "$KEYS_FILE")
    sid=$(awk -F': ' '/shortsid/ {print $2}' "$KEYS_FILE")
    sni=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$CONFIG")
    protocol=$(jq -r '.inbounds[0].protocol' "$CONFIG")
    port=$(jq -r '.inbounds[0].port' "$CONFIG")
    path=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path' "$CONFIG")
    local enc_path
    enc_path=$(printf '%s' "$path" | python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read()))")
    echo "$protocol://$uuid@$ip:$port?security=reality&sni=$sni&fp=firefox&pbk=$pbk&sid=$sid&spx=$enc_path&type=xhttp&flow=xtls-rprx-vision&encryption=none#$email"
}

read -rp "Введите имя пользователя: " email
if [[ -z "$email" || "$email" == *" "* ]]; then
    echo "Имя не может быть пустым или содержать пробелы."
    exit 1
fi

exists=$(jq --arg e "$email" '.inbounds[0].settings.clients[] | select(.email == $e)' "$CONFIG")
if [[ -n "$exists" ]]; then
    echo "Пользователь '$email' уже существует."
    exit 1
fi

uuid=$(xray uuid)
jq --arg email "$email" --arg uuid "$uuid" \
    '.inbounds[0].settings.clients += [{"email": $email, "id": $uuid, "flow": "xtls-rprx-vision"}]' \
    "$CONFIG" > "$TMP" && chmod 600 "$TMP" && mv "$TMP" "$CONFIG"

if ! systemctl restart xray; then
    echo "Ошибка: не удалось перезапустить Xray. Проверьте конфиг."
    exit 1
fi

link=$(generate_link "$email" "$uuid")
echo ""
echo "Ссылка для подключения:"
echo "$link"
echo ""
echo "QR-код:"
echo "$link" | qrencode -t ansiutf8
SCRIPT

cat > /usr/local/bin/rmuser << 'SCRIPT'
#!/bin/bash
CONFIG="/usr/local/etc/xray/config.json"
TMP=$(mktemp)

if [[ $EUID -ne 0 ]]; then
    echo "Требуются права root. Запустите: sudo rmuser"
    exit 1
fi

emails=($(jq -r '.inbounds[0].settings.clients[].email' "$CONFIG"))
if [[ ${#emails[@]} -eq 0 ]]; then
    echo "Нет клиентов для удаления."
    exit 1
fi

echo "Список клиентов:"
for i in "${!emails[@]}"; do
    echo "$((i+1)). ${emails[$i]}"
done

read -rp "Введите номер клиента для удаления: " choice
if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#emails[@]} )); then
    echo "Ошибка: номер должен быть от 1 до ${#emails[@]}"
    exit 1
fi

selected="${emails[$((choice - 1))]}"
jq --arg email "$selected" \
    '(.inbounds[0].settings.clients) |= map(select(.email != $email))' \
    "$CONFIG" > "$TMP" && chmod 600 "$TMP" && mv "$TMP" "$CONFIG"

if ! systemctl restart xray; then
    echo "Ошибка: не удалось перезапустить Xray."
    exit 1
fi
echo "Клиент '$selected' удалён."
SCRIPT

cat > /usr/local/bin/sharelink << 'SCRIPT'
#!/bin/bash
CONFIG="/usr/local/etc/xray/config.json"
KEYS_FILE="/usr/local/etc/xray/.keys"

generate_link() {
    local email="$1" uuid="$2"
    local ip pbk sid sni protocol port path
    ip=$(curl -4 -s --max-time 5 icanhazip.com || curl -4 -s --max-time 5 api.ipify.org)
    [[ -z "$ip" ]] && { echo "Ошибка: не удалось определить IP"; exit 1; }
    pbk=$(awk -F': ' '/PublicKey/ {print $2}' "$KEYS_FILE")
    sid=$(awk -F': ' '/shortsid/ {print $2}' "$KEYS_FILE")
    sni=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$CONFIG")
    protocol=$(jq -r '.inbounds[0].protocol' "$CONFIG")
    port=$(jq -r '.inbounds[0].port' "$CONFIG")
    path=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path' "$CONFIG")
    local enc_path
    enc_path=$(printf '%s' "$path" | python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read()))")
    echo "$protocol://$uuid@$ip:$port?security=reality&sni=$sni&fp=firefox&pbk=$pbk&sid=$sid&spx=$enc_path&type=xhttp&flow=xtls-rprx-vision&encryption=none#$email"
}

emails=($(jq -r '.inbounds[0].settings.clients[].email' "$CONFIG"))
if [[ ${#emails[@]} -eq 0 ]]; then
    echo "Нет клиентов."
    exit 1
fi

for i in "${!emails[@]}"; do
    echo "$((i+1)). ${emails[$i]}"
done

read -rp "Выберите клиента: " client
if ! [[ "$client" =~ ^[0-9]+$ ]] || (( client < 1 || client > ${#emails[@]} )); then
    echo "Ошибка: номер должен быть от 1 до ${#emails[@]}"
    exit 1
fi

selected="${emails[$((client - 1))]}"
uuid=$(jq --arg e "$selected" -r '.inbounds[0].settings.clients[] | select(.email == $e) | .id' "$CONFIG")
link=$(generate_link "$selected" "$uuid")
echo ""
echo "Ссылка для подключения:"
echo "$link"
echo ""
echo "QR-код:"
echo "$link" | qrencode -t ansiutf8
SCRIPT

chmod +x /usr/local/bin/{userlist,mainuser,newuser,rmuser,sharelink}

if ! systemctl restart xray; then
    log_error "Не удалось запустить Xray. Проверьте конфиг: $CONFIG"
    exit 1
fi

log_info "Xray-core успешно установлен"
mainuser

cat > "$HOME/help" << 'EOF'

Команды для управления пользователями Xray:

    newuser   — создать нового пользователя
    rmuser    — удалить пользователя
    mainuser  — ссылка и QR-код основного пользователя
    sharelink — получить ссылку для любого пользователя
    userlist  — список всех клиентов

Файл конфигурации:
    /usr/local/etc/xray/config.json

Перезапуск Xray:
    systemctl restart xray

EOF


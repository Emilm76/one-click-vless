# One click VLESS + Reality

Скрипт для автоматической установки VPN-сервера на базе [Xray-core](https://github.com/XTLS/Xray-core) с протоколом **VLESS + XTLS-Reality**.

## Требования

- Сервер с Ubuntu 22+ / Debian 11+

## Установка

```bash
git clone https://github.com/Emilm76/one-click-vless.git
cd ./one-click-vless
sudo bash ./install.sh
```

После установки автоматически выводится ссылка и QR-код для подключения основного пользователя.

**Удаление**

```bash
sudo bash ./uninstall.sh
```

## Управление пользователями

- `sudo newuser` Создать нового пользователя
- `sudo rmuser` Удалить пользователя
- `mainuser` Ссылка и QR-код основного пользователя
- `userlist` Список всех пользователей
- `sharelink` Ссылка и QR-код для выбранного пользователя

## Файлы

```
/usr/local/etc/xray/config.json   — конфигурация сервера
/usr/local/etc/xray/.keys         — uuid, ключи X25519, shortId
~/help                            — краткая справка по командам
```

## Клиенты для подключения

**Android**
- v2rayTun
- v2rayNG
- Hiddify

**IOS**
- V2RayTun
- FoxRay

**Windows**
- Happ
- V2RayN
- Throne

**Linux**
- Throne
- Happ

Отсканируйте QR-код или вставьте ссылку вручную.

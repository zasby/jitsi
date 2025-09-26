# Развертывание mesh P2P (без JVB/Jicofo)

1) Создайте файл `.env` в каталоге с `docker-compose.yml`:

```
DOMAIN=connect.mooz.pro
PUBLIC_IP=165.22.141.124
EMAIL=admin@mooz.pro
CERT_DIR=/etc/letsencrypt/live/connect.mooz.pro
```

2) Убедитесь, что certbot уже выпустил сертификаты (вы проверили):

```
sudo certbot certificates
```

3) Соберите web (форк jitsi-meet) и скопируйте артефакты в `./web-dist` (скрипт fix-jitsi-p2p.sh делает это автоматически).

4) Запуск:

```
docker compose up -d
```

5) Проверка:
- `https://connect.mooz.pro` — отдается статика
- `wss://connect.mooz.pro/xmpp-websocket` — успешное ws
- TURN UDP 3478 — доступен (user=turnuser, pass=turnpass)

6) Настройка клиента:
- В `jitsi-meet/config.js`: `meshP2P.enabled = true`, `disableFocus = true`, `bosh/websocket` на ваш домен, `p2p.stunServers` указывает на `turn.connect.mooz.pro:3478`.

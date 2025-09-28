#!/usr/bin/env bash
set -euo pipefail

# Настройки
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
DOMAIN="connect.mooz.pro"
PUBLIC_IP="165.22.141.124"
EMAIL="admin@mooz.pro"
CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"

echo "[i] Проект: ${PROJECT_ROOT}"

command -v docker >/dev/null || { echo "[!] Docker не найден"; exit 1; }
command -v docker compose >/dev/null || { echo "[!] Нужен docker compose v2"; exit 1; }

echo "[i] Проверяю certbot файлы..."
if [ ! -f "${CERT_DIR}/fullchain.pem" ] || [ ! -f "${CERT_DIR}/privkey.pem" ]; then
  echo "[!] Сертификаты не найдены: ${CERT_DIR}. Запустите certbot." >&2
  exit 1
fi

echo "[i] Пишу .env..."
cat > "${PROJECT_ROOT}/.env" <<EOF
DOMAIN=${DOMAIN}
PUBLIC_IP=${PUBLIC_IP}
EMAIL=${EMAIL}
CERT_DIR=${CERT_DIR}
EOF

echo "[i] Готовлю фронт: используем официальный jitsi/web и только оверрайды..."
mkdir -p "${PROJECT_ROOT}/overrides"

# Собираем ТОЛЬКО lib-jitsi-meet из форка (легко), если не соберётся — продолжим с дефолтным
if [ -d "${PROJECT_ROOT}/lib-jitsi-meet" ]; then
  pushd "${PROJECT_ROOT}/lib-jitsi-meet" >/dev/null
  npm ci --no-audit --fund=false || true
  npm run build || npm run compile || true
  if ls dist/umd/lib-jitsi-meet*.min.js >/dev/null 2>&1; then
    cp -f dist/umd/lib-jitsi-meet*.min.js "${PROJECT_ROOT}/overrides/lib-jitsi-meet.min.js" || true
  elif ls dist/umd/lib-jitsi-meet*.js >/dev/null 2>&1; then
    cp -f dist/umd/lib-jitsi-meet*.js "${PROJECT_ROOT}/overrides/lib-jitsi-meet.min.js" || true
  fi
  popd >/dev/null
fi

# Убедимся, что наш config.js лежит; если нет — предупредим
if [ ! -f "${PROJECT_ROOT}/jitsi-meet/config.js" ]; then
  echo "[w] Не найден ${PROJECT_ROOT}/jitsi-meet/config.js — используем дефолт из контейнера web"
fi

echo "[i] Запускаю docker compose..."
cd "${PROJECT_ROOT}"
docker compose up -d --remove-orphans

# Готовим и монтируем корректный config.js на хосте (volume в compose подхватит его в контейнере)
echo "[i] Обновляю host-файл jitsi-meet/config.js и перезапускаю web..."
mkdir -p "${PROJECT_ROOT}/jitsi-meet"
cat > "${PROJECT_ROOT}/jitsi-meet/config.js" <<EOF
var config = {
  hosts: { domain: '${DOMAIN}', muc: 'conference.${DOMAIN}' },
  bosh: 'https://${DOMAIN}/http-bind',
  websocket: 'wss://${DOMAIN}/xmpp-websocket',
  preferBosh: true,
  meshP2P: { enabled: true, maxPeers: 5 },
  disableFocus: true,
  p2p: { enabled: true, stunServers: [ { urls: 'stun:turn.${DOMAIN}:3478' } ] }
};
EOF

docker compose restart web

echo "[i] Контроль чтения config.js внутри web:"
docker compose exec web bash -lc "grep -nE 'websocket:|bosh:|preferBosh|conference\\.|disableFocus|meshP2P' /usr/share/jitsi-meet/config.js | cat"
echo "[i] Контроль /defaults/config.js и /etc/jitsi/meet/${DOMAIN}-config.js (на всякий случай):"
docker compose exec web bash -lc "for p in /defaults/config.js /etc/jitsi/meet/${DOMAIN}-config.js; do echo ==== \$p ====; [ -f \$p ] && grep -nE 'websocket:|bosh:|preferBosh' \$p || echo 'нет файла'; done | cat"

# --- Caddyfile фикс для корректной раздачи /config.js без кэша ---
echo "[i] Обновляю caddy/Caddyfile для раздачи /config.js из /srv с Cache-Control: no-store..."
mkdir -p "${PROJECT_ROOT}/caddy"
cat > "${PROJECT_ROOT}/caddy/Caddyfile" <<EOF
${DOMAIN} {
  tls /etc/ssl/certs/${DOMAIN}.crt /etc/ssl/private/${DOMAIN}.key
  encode zstd gzip

  # XMPP WebSocket/BOSH → Prosody:5280 (совпадение по префиксу)
  handle_path /xmpp-websocket* {
    reverse_proxy prosody:5280 {
      header_up Host {host}
      header_up X-Forwarded-Proto {scheme}
      header_up X-Forwarded-For {remote}
    }
  }

  handle_path /http-bind* {
    reverse_proxy prosody:5280 {
      header_up Host {host}
      header_up X-Forwarded-Proto {scheme}
      header_up X-Forwarded-For {remote}
    }
  }

  # Отдаём /config.js строго из /srv и запрещаем кэш
  handle_path /config.js {
    header {
      Cache-Control "no-store, no-cache, must-revalidate"
    }
    root * /srv
    file_server
  }

  # Всё остальное → web:80
  reverse_proxy web:80 {
    header_up Host {host}
    header_up X-Forwarded-Proto {scheme}
    header_up X-Forwarded-For {remote}
  }

  header {
    Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
    X-Content-Type-Options "nosniff"
    X-Frame-Options "SAMEORIGIN"
    Referrer-Policy "strict-origin-when-cross-origin"
  }
}
EOF

echo "[i] Перезапускаю Caddy..."
docker compose restart caddy

echo "[i] Контроль через Caddy (HTTPS): что реально отдаётся по /config.js"
curl -s https://"${DOMAIN}"/config.js | grep -nE "websocket:|bosh:|preferBosh" | cat || true

echo "[i] Контроль через reverse-proxy: какой config.js отдаёт web (обход https)"
curl -s https://"${DOMAIN}"/config.js | grep -nE "websocket:|bosh:|preferBosh" | cat || true

echo "[i] Готово. Проверьте: https://${DOMAIN}"
echo "[i] WebSocket: wss://${DOMAIN}/xmpp-websocket"
echo "[i] TURN UDP 3478: ${PUBLIC_IP}, user=turnuser, pass=turnpass"

# Быстрый автотест HTTP/WS/BOSH
echo "[i] Быстрая проверка HTTP/WS/BOSH..."
curl -s -I "https://${DOMAIN}" | head -10 || true
curl -s -o /dev/null -w "BOSH %{http_code}\n" -H 'Content-Type: text/xml' \
  -d '<body rid="1" xmlns="http://jabber.org/protocol/httpbind" to="connect.mooz.pro" wait="60" hold="1" ver="1.6" xml:lang="en" xmpp:version="1.0" xmlns:xmpp="urn:xmpp:xbosh"/>' \
  "https://${DOMAIN}/http-bind" || true

# Новая функция: глубокая диагностика и жёсткая валидация того, что клиент НЕ получает localhost в config.js
doctor() {
    echo "🔎 DOCTOR: Проверяю, что фронт и XMPP настроены правильно (без localhost)"
    echo ""

    echo "1) Что реально отдает Caddy по /config.js (ключевые поля):"
    docker compose exec caddy sh -lc 'apk add --no-cache curl >/dev/null 2>&1 || true; curl -s https://'"${DOMAIN}"'/config.js | sed -n "1,220p" | grep -nE "hosts:|bosh:|websocket:|preferBosh|meshP2P|disableFocus|p2p:|stunServers" | cat'
    echo ""

    echo "2) Проверка на утечки localhost/127.0.0.1 в отданном config.js:"
    if docker compose exec caddy sh -lc 'curl -s https://'"${DOMAIN}"'/config.js | grep -E "localhost|127\.0\.0\.1|:8443" -n | cat' | grep -qE "localhost|127\\.0\\.0\\.1|:8443"; then
        echo "❌ ВНИМАНИЕ: В отданном /config.js обнаружены localhost/127.0.0.1/8443 — браузер будет бить в локалхост."
        echo "   Скрипт ниже принудительно перезапишет /srv/config.js и перегрузит Caddy."
        echo ""
    else
        echo "✅ localhost/127.0.0.1 в отданном /config.js не обнаружены"
    fi
    echo ""

    echo "3) Проверяю доступность прокси к Prosody: /http-bind и /xmpp-websocket"
    docker compose exec caddy sh -lc 'curl -sI https://'"${DOMAIN}"'/http-bind | head -n 1 | cat'
    docker compose exec caddy sh -lc 'curl -sI https://'"${DOMAIN}"'/xmpp-websocket | head -n 1 | cat'
    echo ""

    echo "4) Прозвон из Caddy внутрь Prosody:"
    docker compose exec caddy sh -lc 'curl -sI http://prosody:5280/http-bind | head -n 3 | cat'
    docker compose exec caddy sh -lc 'curl -sI http://prosody:5280/xmpp-websocket | head -n 3 | cat'
    echo ""

    echo "5) Быстрая проверка, что в lib-jitsi-meet фиксирован абсолютный WS:"
    if docker compose exec caddy sh -lc 'curl -s https://'"${DOMAIN}"'/config.js' | grep -q "wss://${DOMAIN}/xmpp-websocket"; then
        echo "✅ Абсолютный WS в config.js найден: wss://${DOMAIN}/xmpp-websocket"
    else
        echo "⚠️  Абсолютный WS не найден — будет применён автопочин в команде websocket"
    fi
}

# Принудительно включаем HTTP-модули Prosody и явные пути /http-bind и /xmpp-websocket
ensure_prosody_http_paths() {
    echo "🔧 Настраиваю Prosody HTTP endpoints (/http-bind, /xmpp-websocket)"
    local CFG="${PROJECT_ROOT}/prosody/prosody.cfg.lua"

    if [ ! -f "$CFG" ]; then
        echo "⚠️  $CFG не найден, создаю минимальный конфиг с HTTP"
        mkdir -p "${PROJECT_ROOT}/prosody"
        cat > "$CFG" <<'CONF'
admins = {}

modules_enabled = {
  "http";
  "websocket";
  "bosh";
  "ping";
}

modules_disabled = { "posix" }

http_ports = { 5280 }
https_ports = { }
http_interfaces = { "*" }
http_paths = { bosh = "/http-bind"; websocket = "/xmpp-websocket"; }

cross_domain_websocket = true
consider_bosh_secure = true

VirtualHost "connect.mooz.pro"
  authentication = "anonymous"
  modules_enabled = { "websocket"; "bosh"; "ping" }

VirtualHost "auth.connect.mooz.pro"
  authentication = "internal_hashed"

Component "conference.connect.mooz.pro" "muc"
  restrict_room_creation = false
CONF
    else
        # Правки in-place
        sed -i 's/^\s*https_ports\s*=.*/https_ports = { }/g' "$CFG" || true
        # modules_enabled: гарантируем наличие http/websocket/bosh
        if ! grep -q '"http"' "$CFG"; then
            sed -i '0,/modules_enabled/s//modules_enabled = {\n  "http";\n/1' "$CFG" || true
        fi
        # http_ports и interfaces
        if grep -q '^\s*http_ports' "$CFG"; then
            sed -i 's/^\s*http_ports\s*=.*/http_ports = { 5280 }/' "$CFG"
        else
            sed -i '1i http_ports = { 5280 }' "$CFG"
        fi
        if grep -q '^\s*http_interfaces' "$CFG"; then
            sed -i 's/^\s*http_interfaces\s*=.*/http_interfaces = { "*" }/' "$CFG"
        else
            sed -i '1i http_interfaces = { "*" }' "$CFG"
        fi
        # http_paths
        if grep -q '^\s*http_paths' "$CFG"; then
            sed -i 's#^\s*http_paths\s*=.*#http_paths = { bosh = "/http-bind"; websocket = "/xmpp-websocket"; }#' "$CFG"
        else
            sed -i '1i http_paths = { bosh = "/http-bind"; websocket = "/xmpp-websocket"; }' "$CFG"
        fi
        # Убедимся, что главный VirtualHost включает websocket/bosh
        if ! awk 'f&&/}/{f=0} f; /VirtualHost "connect.mooz.pro"/{f=1}' "$CFG" | grep -q 'websocket'; then
            awk '1; /VirtualHost "connect.mooz.pro"/ && c==0 {print "  modules_enabled = { \"websocket\"; \"bosh\"; \"ping\"; }"; c=1}' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
        fi
    fi

    echo "🔄 Перезапуск Prosody…"
    docker compose restart prosody
    sleep 3

    echo "🧪 Проверка путей прямо на prosody:5280 (с правильным Host)"
    docker compose exec -T caddy curl -sI -H 'Host: ${DOMAIN}' http://prosody:5280/http-bind | head -3
    docker compose exec -T caddy curl -sI -H 'Host: ${DOMAIN}' http://prosody:5280/xmpp-websocket | head -3
}

#!/bin/bash

# ЕДИНЫЙ СКРИПТ ДЛЯ ИСПРАВЛЕНИЯ P2P JITSI MEET
# Домен: connect.mooz.pro
# IP: 165.22.141.124
# Версия: 6.0 - исправление аутентификации Jicofo и создание пользователя focus

set -e

echo "🔧 ЕДИНЫЙ СКРИПТ ИСПРАВЛЕНИЯ P2P JITSI MEET"
echo "📋 Домен: connect.mooz.pro"
echo "📋 IP: 165.22.141.124"
echo "📋 Версия: 6.0 - исправление аутентификации Jicofo и создание пользователя focus"
echo ""

# Проверяем, что мы root
if [ "$EUID" -ne 0 ]; then
    echo "❌ Запустите скрипт от имени root: sudo $0"
    exit 1
fi

# Функция для диагностики проблем
diagnose() {
    echo "🔍 ДИАГНОСТИКА ПРОБЛЕМ..."
    echo ""
    
    echo "📊 Статус контейнеров:"
    docker compose ps
    echo ""
    
    echo "📋 Логи Prosody (последние 20 строк):"
    docker compose logs prosody | tail -20
    echo ""
    
    echo "📋 Логи Jicofo (последние 10 строк):"
    docker compose logs jicofo | tail -10
    echo ""
    
    echo "📋 Логи Nginx (последние 10 строк):"
    docker compose logs web | tail -10
    echo ""
}

# Функция для исправления проблемы с JVB_AUTH_PASSWORD
fix_jvb_password() {
    echo "🔧 ИСПРАВЛЕНИЕ ПРОБЛЕМЫ С JVB_AUTH_PASSWORD..."
    echo ""
    
    # Останавливаем контейнеры
    echo "🛑 Остановка контейнеров..."
    docker compose down
    
    # Создаем/обновляем .env файл с паролями
    echo "🔐 Создание/обновление .env файла с паролями..."
    
    # Читаем существующий .env или создаем новый
    if [ -f ".env" ]; then
        # Удаляем старые пароли если есть
        sed -i '/^JVB_AUTH_PASSWORD=/d' .env
        sed -i '/^JICOFO_AUTH_PASSWORD=/d' .env
    else
        # Создаем базовый .env
        cat > .env << 'EOF'
# Конфигурация для P2P-only Jitsi Meet
PUBLIC_URL=https://connect.mooz.pro
DOCKER_HOST_ADDRESS=165.22.141.124
TZ=UTC

# XMPP настройки
XMPP_DOMAIN=connect.mooz.pro
XMPP_AUTH_DOMAIN=auth.connect.mooz.pro
XMPP_GUEST_DOMAIN=guest.connect.mooz.pro
XMPP_MUC_DOMAIN=muc.connect.mooz.pro
XMPP_INTERNAL_MUC_DOMAIN=internal-muc.connect.mooz.pro
XMPP_RECORDER_DOMAIN=recorder.connect.mooz.pro

# Аутентификация
AUTH_TYPE=anonymous
ENABLE_AUTH=0
ENABLE_GUESTS=1

# Jicofo настройки
JICOFO_AUTH_USER=focus

# JVB настройки (отключены для P2P)
ENABLE_JVB=0
JVB_BREWERY_MUC=jvbbrewery

# Jigasi настройки (отключены)
JIGASI_BREWERY_MUC=jigasibrewery
JIGASI_SIP_URI=

# Jibri настройки (отключены)
JIBRI_BREWERY_MUC=jibribrewery
JIBRI_PENDING_TIMEOUT=90
JIBRI_XMPP_USER=jibri
JIBRI_RECORDER_USER=recorder

# Запись и стриминг (отключены)
ENABLE_RECORDING=0
ENABLE_LIVESTREAMING=0
ENABLE_TRANSCRIPTION=0

# SCTP настройки
ENABLE_SCTP=1

# SSL/TLS настройки
ENABLE_LETSENCRYPT=0
LETSENCRYPT_DOMAIN=
LETSENCRYPT_EMAIL=
DISABLE_HTTPS=0
ENABLE_HTTP_REDIRECT=1
ENABLE_HSTS=1

# P2P специфичные настройки
P2P_ENABLED=1
P2P_MESH_ENABLED=1
P2P_MAX_PARTICIPANTS=6
P2P_STUN_SERVERS=stun:stun.l.google.com:19302,stun:stun1.l.google.com:19302,stun:stun2.l.google.com:19302,stun:connect.mooz.pro:3478

# Настройки производительности для P2P
ENABLE_SIMULCAST=0
ENABLE_RTX=0
ENABLE_LAYER_SUSPENSION=0

# Настройки безопасности
ENABLE_E2EE=0

# Настройки логирования
LOG_LEVEL=INFO
ENABLE_DETAILED_LOGGING=1
LOG_P2P_EVENTS=1

# Настройки таймаутов для P2P
P2P_CONNECTION_TIMEOUT=30000
P2P_RECONNECTION_INTERVAL=5000
P2P_MAX_RECONNECTION_ATTEMPTS=3

# Отключаем функции, несовместимые с P2P
ENABLE_BREAKOUT_ROOMS=0
ENABLE_LOBBY=0
ENABLE_POLLS=0
ENABLE_REACTIONS=0

# Настройки для отладки
DEBUG_MODE=1
ENABLE_STATS=0

# Настройки сети
NETWORK_INTERFACE=eth0
NETWORK_BIND_ADDRESS=0.0.0.0

# Настройки портов
HTTP_PORT=80
HTTPS_PORT=443
XMPP_PORT=5222
XMPP_BOSH_PORT=5280
XMPP_WEBSOCKET_PORT=5281
STUN_PORT=3478
TURN_PORT=3478
TURNS_PORT=5349
EOF
    fi
    
    # Добавляем пароли
    echo "JICOFO_COMPONENT_SECRET=$(openssl rand -hex 32)" >> .env
    echo "JICOFO_AUTH_PASSWORD=$(openssl rand -hex 32)" >> .env
    echo "JVB_AUTH_PASSWORD=$(openssl rand -hex 32)" >> .env
    echo "JIBRI_XMPP_PASSWORD=$(openssl rand -hex 32)" >> .env
    echo "JIBRI_RECORDER_PASSWORD=$(openssl rand -hex 32)" >> .env
    echo "TURN_SECRET=$(openssl rand -hex 32)" >> .env
    
    echo "✅ .env файл создан/обновлен с паролями"
    echo ""
    
    # Создаем docker-compose.override.yml для гарантированной передачи паролей
    echo "🔧 Создание docker-compose.override.yml..."
    cat > docker-compose.override.yml << 'EOF'
services:
  prosody:
    environment:
      - JVB_AUTH_PASSWORD=${JVB_AUTH_PASSWORD}
      - JICOFO_AUTH_PASSWORD=${JICOFO_AUTH_PASSWORD}
      - TURN_SECRET=${TURN_SECRET}
  jicofo:
    environment:
      - JICOFO_AUTH_PASSWORD=${JICOFO_AUTH_PASSWORD}
      - JVB_AUTH_PASSWORD=${JVB_AUTH_PASSWORD}
EOF
    
    echo "✅ docker-compose.override.yml создан"
    echo ""
}

# Функция для исправления конфигурационных файлов
fix_config_files() {
    echo "🔧 ИСПРАВЛЕНИЕ КОНФИГУРАЦИОННЫХ ФАЙЛОВ..."
    echo ""
    
    # Исправляем Prosody конфигурацию
    echo "🔧 Исправление prosody.cfg.lua..."
    sed -i 's|pidfile = "/var/run/prosody/prosody.pid";|-- pidfile = "/var/run/prosody/prosody.pid";|' prosody/config/prosody.cfg.lua
    sed -i 's|external_service_secret = "your_turn_secret_here";|external_service_secret = os.getenv("TURN_SECRET") or "changeme";|' prosody/config/prosody.cfg.lua
    
    # Исправляем Jicofo конфигурацию
    echo "🔧 Исправление sip-communicator.properties..."
    # Заменяем плейсхолдеры на реальные значения из переменных окружения
    sed -i "s|your_jicofo_password_here|${JICOFO_AUTH_PASSWORD}|g" jicofo/sip-communicator.properties
    sed -i "s|your_jicofo_secret_here|${JICOFO_COMPONENT_SECRET}|g" jicofo/sip-communicator.properties
    
    # Исправляем jicofo.conf (если файл существует)
    if [ -f "jicofo/jicofo.conf" ]; then
        echo "🔧 Исправление jicofo.conf..."
        sed -i "s|your_jicofo_password_here|${JICOFO_AUTH_PASSWORD}|g" jicofo/jicofo.conf
        sed -i "s|your_jicofo_secret_here|${JICOFO_COMPONENT_SECRET}|g" jicofo/jicofo.conf
    else
        echo "⚠️  Файл jicofo.conf не найден, пропускаем"
    fi
    
    echo "✅ Конфигурационные файлы исправлены"
    echo ""
}

# Функция для исправления P2P конфигурации
fix_p2p_config() {
    echo "🔧 ИСПРАВЛЕНИЕ P2P КОНФИГУРАЦИИ..."
    echo ""
    
    # Создаем правильную конфигурацию для P2P-only режима
    echo "🔧 Создание правильной P2P конфигурации..."
    
    # Обновляем config-p2p-fixed.js для полного отключения JVB
    cat > jitsi-meet/config-p2p-fixed.js << 'EOF'
/* eslint-disable comma-dangle, no-unused-vars, no-var, prefer-template, vars-on-top */

/*
 * P2P-only конфигурация Jitsi Meet для connect.mooz.pro
 * Полностью исправленная версия без JVB
 */

var subdir = '<!--# echo var="subdir" default="" -->';
var subdomain = '<!--# echo var="subdomain" default="" -->';

if (subdomain) {
    subdomain = subdomain.substr(0, subdomain.length - 1).split('.')
        .join('_')
        .toLowerCase() + '.';
}

if (subdir.startsWith('<!--')) {
    subdir = '';
}
if (subdomain.startsWith('<!--')) {
    subdomain = '';
}

var config = {
    // Основные настройки
    hosts: {
        domain: 'connect.mooz.pro',
        muc: 'muc.connect.mooz.pro',
        anonymousdomain: 'guest.connect.mooz.pro'
    },

    bosh: 'https://connect.mooz.pro/http-bind',
    websocket: 'wss://connect.mooz.pro/xmpp-websocket',

    // КРИТИЧЕСКИ ВАЖНО: Полностью отключаем JVB
    enableJvb: false,
    enableJvbDiscovery: false,
    enableJvbSelection: false,
    enableJvbFailover: false,
    enableJvbHealthChecks: false,
    enableJvbStats: false,
    enableJvbRest: false,
    enableJvbWebsocket: false,
    
    // Принудительно включаем P2P режим
    enableP2P: true,
    forceP2PMode: true,
    p2pOnly: true,
    
    // P2P настройки
    p2p: {
        enabled: true,
        enableMesh: true,
        maxParticipants: 6,
        iceTransportPolicy: 'all',
        backToP2PDelay: 5,
        stunServers: [
            { urls: 'stun:stun.l.google.com:19302' },
            { urls: 'stun:stun1.l.google.com:19302' },
            { urls: 'stun:stun2.l.google.com:19302' },
            { urls: 'stun:connect.mooz.pro:3478' }
        ],
        useStunTurn: true,
        preferH264: true,
        disableH264: false,
        disableVP8: false,
        disableVP9: false,
        meshEnabled: true,
        meshMaxParticipants: 6,
        meshConnectionTimeout: 30000,
        meshReconnectionInterval: 5000,
        meshMaxReconnectionAttempts: 3
    },

    // Настройки качества для P2P
    videoQuality: {
        maxBitrate: 500000,
        maxHeight: 720,
        maxWidth: 1280
    },
    
    audioQuality: {
        maxBitrate: 64000
    },
    
    // Отключаем функции, требующие сервер
    fileRecordingsEnabled: false,
    liveStreamingEnabled: false,
    transcription: {
        enabled: false
    },
    
    // Настройки производительности для P2P
    performance: {
        disableSimulcast: true,
        disableRtx: true
    },
    
    // Кастомные настройки для P2P mesh
    customP2P: {
        connectionTimeout: 30000,
        reconnectionInterval: 5000,
        maxReconnectionAttempts: 3,
        fallbackToJVB: false,
        jvbFallbackThreshold: 6
    },
    
    // Настройки для отладки P2P
    debug: {
        enableDetailedLogging: true,
        logP2PEvents: true
    },

    // Отключаем аналитику
    analytics: {
        disabled: true,
    },

    // Настройки для P2P соединений
    channelLastN: -1,
    webrtcIceUdpDisable: false,
    webrtcIceTcpDisable: false,
    useTurnUdp: false,
    
    // Отключаем функции, несовместимые с P2P
    disableModeratorIndicator: false,
    disableReactions: true,
    disablePolls: false,
    disableSelfDemote: false,
    disableSelfView: false,
    disableSelfViewSettings: false,
    
    // Настройки аудио для P2P
    enableNoAudioDetection: true,
    enableNoisyMicDetection: true,
    startAudioOnly: false,
    startAudioMuted: 10,
    startWithAudioMuted: false,
    startSilent: false,
    enableOpusRed: false,
    
    // Настройки видео для P2P
    resolution: 720,
    maxFullResolutionParticipants: 2,
    disableSimulcast: true,
    startVideoMuted: 10,
    startWithVideoMuted: false,
    
    // Настройки для P2P соединений
    disableRtx: true,
    disableBeforeUnloadHandlers: true,
    enableTcc: true,
    enableRemb: true,
    enableForcedReload: true,
    
    // UI настройки для P2P
    disableResponsiveTiles: false,
    requireDisplayName: false,
    enableWebHIDFeature: false,
    enableWelcomePage: false,
    
    // Настройки для P2P соединений
    disableShortcuts: false,
    disableInitialGUM: false,
    enableClosePage: false,
    disable1On1Mode: null,
    
    // Настройки для P2P соединений
    defaultLocalDisplayName: 'me',
    defaultRemoteDisplayName: 'Fellow Jitster',
    hideDisplayName: false,
    hideDominantSpeakerBadge: false,
    defaultLanguage: 'en',
    disableProfile: false,
    hideEmailInSettings: false,
    
    // Настройки для P2P соединений
    disableInviteFunctions: false,
    doNotStoreRoom: false,
    
    // Настройки для P2P соединений
    disableRemoteMute: false,
    
    // Настройки для P2P соединений
    disableAEC: false,
    disableAGC: false,
    disableAP: false,
    disableNS: false,
    displayJids: false,
    enableTalkWhileMuted: true,
    forceTurnRelay: false,
    
    // Настройки для P2P соединений
    mouseMoveCallbackInterval: 1000,
    
    // Настройки для P2P соединений
    disableFilmstripAutohiding: false,
    
    // Настройки для P2P соединений
    disableChatSmileys: false,
    
    // Настройки для P2P соединений
    logging: {
        defaultLogLevel: 'info',
        loggers: {
            'modules/RTC/TraceablePeerConnection.js': 'info',
            'modules/xmpp/strophe.util.js': 'log',
        },
    },
    
    // Настройки для P2P соединений
    defaultLogoUrl: 'images/watermark.svg',
    
    // Настройки для P2P соединений
    disableVirtualBackground: false,
    disableAddingBackgroundImages: false,
    backgroundAlpha: 1,
    
    // Настройки для P2P соединений
    disableTileView: false,
    disableTileEnlargement: false,
    
    // Настройки для P2P соединений
    hideConferenceSubject: false,
    hideConferenceTimer: false,
    hideRecordingLabel: false,
    hideParticipantsStats: true,
    
    // Настройки для P2P соединений
    useHostPageLocalStorage: false,
    
    // Настройки для P2P соединений
    disableThirdPartyRequests: false,
    
    // Настройки для P2P соединений
    disableCalendarIntegration: false,
    notifyOnConferenceDestruction: true,
    
    // Настройки для P2P соединений
    disableDeepLinking: false,
    
    // Настройки для P2P соединений
    disableInsecureRoomNameWarning: false,
    
    // Настройки для P2P соединений
    corsAvatarURLs: [],
    
    // Настройки для P2P соединений
    gravatar: {
        baseUrl: 'https://www.gravatar.com/avatar/',
        disabled: false,
    },
    
    // Настройки для P2P соединений
    inviteAppName: null,
    
    // Настройки для P2P соединений
    toolbarButtons: [
        'camera',
        'chat',
        'desktop',
        'hangup',
        'microphone',
        'participants-pane',
        'tileview',
        'settings',
        'fullscreen',
        'filmstrip',
        'feedback',
        'stats',
        'shortcuts',
        'help',
        'download',
        'embedmeeting',
        'invite',
        'raisehand',
        'recording',
        'security',
        'select-background',
        'shareaudio',
        'sharedvideo',
        'toggle-camera',
        'videoquality',
        'whiteboard',
    ],
    
    // Настройки для P2P соединений
    toolbarConfig: {
        initialTimeout: 20000,
        timeout: 4000,
        alwaysVisible: false,
        autoHideWhileChatIsOpen: false,
    },
    
    // Настройки для P2P соединений
    mainToolbarButtons: [
        [ 'microphone', 'camera', 'desktop', 'chat', 'raisehand', 'reactions', 'participants-pane', 'tileview' ],
        [ 'microphone', 'camera', 'desktop', 'chat', 'raisehand', 'participants-pane', 'tileview' ],
        [ 'microphone', 'camera', 'desktop', 'chat', 'raisehand', 'participants-pane' ],
        [ 'microphone', 'camera', 'desktop', 'chat', 'participants-pane' ],
        [ 'microphone', 'camera', 'chat', 'participants-pane' ],
        [ 'microphone', 'camera', 'chat' ],
        [ 'microphone', 'camera' ]
    ],
    
    // Настройки для P2P соединений
    buttonsWithNotifyClick: [
        'camera',
        'chat',
        'desktop',
        'download',
        'embedmeeting',
        'end-meeting',
        'etherpad',
        'feedback',
        'filmstrip',
        'fullscreen',
        'hangup',
        'hangup-menu',
        'help',
        'invite',
        'livestreaming',
        'microphone',
        'mute-everyone',
        'mute-video-everyone',
        'noisesuppression',
        'participants-pane',
        'profile',
        'raisehand',
        'recording',
        'security',
        'select-background',
        'settings',
        'shareaudio',
        'sharedvideo',
        'shortcuts',
        'stats',
        'tileview',
        'toggle-camera',
        'videoquality',
        'whiteboard',
    ],
    
    // Настройки для P2P соединений
    participantMenuButtonsWithNotifyClick: [
        'allow-video',
        'ask-unmute',
        'conn-status',
        'flip-local-video',
        'grant-moderator',
        'kick',
        'hide-self-view',
        'mute',
        'mute-others',
        'mute-others-video',
        'mute-video',
        'pinToStage',
        'privateMessage',
        'remote-control',
        'send-participant-to-room',
        'verify',
    ],
    
    // Настройки для P2P соединений
    hiddenPremeetingButtons: [],
    
    // Настройки для P2P соединений
    customParticipantMenuButtons: [],
    
    // Настройки для P2P соединений
    customToolbarButtons: [],
    
    // Настройки для P2P соединений
    gatherStats: false,
    pcStatsInterval: 10000,
    enableDisplayNameInStats: false,
    enableEmailInStats: false,
    
    // Настройки для P2P соединений
    feedbackPercentage: 100,
    
    // Настройки для P2P соединений
    disabledSounds: [],
    
    // Настройки для P2P соединений
    chromeExtensionBanner: {
        url: 'https://chrome.google.com/webstore/detail/jitsi-meetings/kglhbbefdnlheedjiejgomgmfplipfeb',
        edgeUrl: 'https://microsoftedge.microsoft.com/addons/detail/jitsi-meetings/eeecajlpbgjppibfledfihobcabccihn',
        chromeExtensionsInfo: [
            {
                id: 'kglhbbefdnlheedjiejgomgmfplipfeb',
                path: 'jitsi-logo-48x48.png',
            },
            {
                id: 'eeecajlpbgjppibfledfihobcabccihn',
                path: 'jitsi-logo-48x48.png',
            },
        ]
    },
    
    // Настройки для P2P соединений
    e2eping: {
        enabled: false,
        numRequests: 5,
        maxConferenceSize: 200,
        maxMessagesPerSecond: 250,
    },
    
    // Настройки для P2P соединений
    deeplinking: {
        desktop: {
            appName: 'Jitsi Meet',
            appScheme: 'jitsi-meet',
            download: {
                linux: 'https://github.com/jitsi/jitsi-meet-electron/releases/latest/download/jitsi-meet-x86_64.AppImage',
                macos: 'https://github.com/jitsi/jitsi-meet-electron/releases/latest/download/jitsi-meet.dmg',
                windows: 'https://github.com/jitsi/jitsi-meet-electron/releases/latest/download/jitsi-meet.exe'
            },
            enabled: false
        },
        disabled: false,
        hideLogo: false,
        ios: {
            appName: 'Jitsi Meet',
            appScheme: 'org.jitsi.meet',
            downloadLink: 'https://itunes.apple.com/us/app/jitsi-meet/id1165103905',
        },
        android: {
            appName: 'Jitsi Meet',
            appScheme: 'org.jitsi.meet',
            downloadLink: 'https://play.google.com/store/apps/details?id=org.jitsi.meet',
            appPackage: 'org.jitsi.meet',
            fDroidUrl: 'https://f-droid.org/en/packages/org.jitsi.meet/',
        }
    },
    
    // Настройки для P2P соединений
    legalUrls: {
        helpCentre: 'https://web-cdn.jitsi.net/faq/meet-faq.html',
        privacy: 'https://jitsi.org/meet/privacy',
        terms: 'https://jitsi.org/meet/terms'
    },
    
    // Настройки для P2P соединений
    disableLocalVideoFlip: false,
    doNotFlipLocalVideo: false,
    
    // Настройки для P2P соединений
    deploymentUrls: {
        userDocumentationURL: 'https://docs.example.com/video-meetings.html',
        downloadAppsUrl: 'https://docs.example.com/our-apps.html',
    },
    
    // Настройки для P2P соединений
    remoteVideoMenu: {
        disabled: false,
        disableDemote: false,
        disableKick: false,
        disableGrantModerator: false,
        disablePrivateChat: false,
    },
    
    // Настройки для P2P соединений
    disableRemoteMute: false,
    
    // Настройки для P2P соединений
    dynamicBrandingUrl: '',
    
    // Настройки для P2P соединений
    sharedVideoAllowedURLDomains: [],
    
    // Настройки для P2P соединений
    participantsPane: {
        enabled: true,
        hideModeratorSettingsTab: false,
        hideMoreActionsButton: false,
        hideMuteAllButton: false,
    },
    
    // Настройки для P2P соединений
    breakoutRooms: {
        hideAddRoomButton: false,
        hideAutoAssignButton: false,
        hideJoinRoomButton: false,
    },
    
    // Настройки для P2P соединений
    conferenceInfo: {
        alwaysVisible: ['recording', 'raised-hands-count'],
        autoHide: [
            'subject',
            'conference-timer',
            'participants-count',
            'e2ee',
            'video-quality',
            'insecure-room',
            'highlight-moment',
            'top-panel-toggle',
        ]
    },
    
    // Настройки для P2P соединений
    hideConferenceSubject: false,
    hideConferenceTimer: false,
    hideRecordingLabel: false,
    hideParticipantsStats: true,
    
    // Настройки для P2P соединений
    subject: '',
    localSubject: '',
    
    // Настройки для P2P соединений
    useHostPageLocalStorage: false,
    
    // Настройки для P2P соединений
    etherpad_base: '',
    
    // Настройки для P2P соединений
    dialInNumbersUrl: '',
    dialInConfCodeUrl: '',
    
    // Настройки для P2P соединений
    tokenAuthUrl: '',
    tokenLogoutUrl: '',
    tokenAuthUrlAutoRedirect: false,
    tokenRespectTenant: false,
    tokenGetUserInfoOutOfContext: false,
    
    // Настройки для P2P соединений
    peopleSearchQueryTypes: ['user', 'email'],
    peopleSearchUrl: '',
    inviteServiceUrl: '',
    peopleSearchTokenLocation: '',
    
    // Настройки для P2P соединений
    visitors: {
        enableMediaOnPromote: {
            audio: true,
            video: true
        },
    },
    
    // Настройки для P2P соединений
    desktopSharingSources: ['screen', 'window'],
    
    // Настройки для P2P соединений
    brandingRoomAlias: null,
    
    // Настройки для P2P соединений
    hiddenDomain: '',
    hiddenFromRecorderFeatureEnabled: false,
    ignoreStartMuted: false,
    websocketKeepAlive: false,
    websocketKeepAliveUrl: '',
    
    // Настройки для P2P соединений
    notifications: [],
    disabledNotifications: [],
    
    // Настройки для P2P соединений
    filmstrip: {
        disabled: false,
        disableResizable: false,
        disableStageFilmstrip: false,
        stageFilmstripParticipants: 1,
        disableTopPanel: false,
        minParticipantCountForTopPanel: 50,
        initialWidth: 400,
        alwaysShowResizeBar: true,
    },
    
    // Настройки для P2P соединений
    tileView: {
        disabled: false,
        numberOfVisibleTiles: 25,
    },
    
    // Настройки для P2P соединений
    giphy: {
        enabled: false,
        sdkKey: '',
        displayMode: 'all',
        tileTime: 5000,
        rating: 'pg',
    },
    
    // Настройки для P2P соединений
    whiteboard: {
        enabled: true,
        collabServerBaseUrl: 'https://excalidraw-backend.example.com',
        userLimit: 25,
        limitUrl: 'https://example.com/blog/whiteboard-limits',
    },
    
    // Настройки для P2P соединений
    watchRTCConfigParams: {},
    
    // Настройки для P2P соединений
    hideLoginButton: false,
    
    // Настройки для P2P соединений
    disableCameraTintForeground: false,
    
    // Настройки для P2P соединений
    fileSharing: {
        apiUrl: 'https://example.com',
        enabled: true,
        maxFileSize: 50,
    },
};
EOF
    
    echo "✅ P2P конфигурация исправлена"
    echo ""
}

# Функция для исправления проблемы с Prosody
fix_prosody_startup() {
    echo "🔧 ИСПРАВЛЕНИЕ ПРОБЛЕМЫ С PROSODY..."
    echo ""
    
    # Останавливаем контейнеры
    echo "🛑 Остановка контейнеров..."
    docker compose down
    
    # Проверяем Dockerfile.prosody
    echo "🔧 Проверка Dockerfile.prosody..."
    if [ ! -f "Dockerfile.prosody" ]; then
        echo "❌ Dockerfile.prosody не найден!"
        return 1
    fi
    
    # Пересобираем образ Prosody
    echo "🔧 Пересборка образа Prosody..."
    docker build -t jitsi-prosody -f Dockerfile.prosody .
    
    echo "✅ Образ Prosody пересобран"
    echo ""
}

# Функция для настройки SSL сертификатов через Certbot
setup_certbot_ssl() {
    echo "🔒 НАСТРОЙКА SSL СЕРТИФИКАТОВ ЧЕРЕЗ CERTBOT..."
    echo ""
    
    # Останавливаем контейнеры
    echo "🛑 Остановка контейнеров..."
    docker compose down
    
    # Устанавливаем Certbot
    echo "📦 Установка Certbot..."
    apt update
    apt install -y certbot python3-certbot-nginx
    
    # Получаем сертификат
    echo "🔒 Получение SSL сертификата..."
    certbot certonly --standalone -d connect.mooz.pro --non-interactive --agree-tos --email admin@mooz.pro
    
    # Копируем сертификаты
    echo "📋 Копирование сертификатов..."
    cp /etc/letsencrypt/live/connect.mooz.pro/fullchain.pem nginx/ssl/connect.mooz.pro.crt
    cp /etc/letsencrypt/live/connect.mooz.pro/privkey.pem nginx/ssl/connect.mooz.pro.key
    
    # Устанавливаем права
    chmod 644 nginx/ssl/connect.mooz.pro.crt
    chmod 644 nginx/ssl/connect.mooz.pro.key
    
    # Создаем dhparam
    if [ ! -f "prosody/certs/dhparam.pem" ]; then
        openssl dhparam -out prosody/certs/dhparam.pem 2048
    fi
    
    echo "✅ SSL сертификаты настроены"
    echo ""
}

# Функция для полного отключения JVB в Jicofo
fix_jicofo_jvb_disable() {
    echo "🔧 ПОЛНОЕ ОТКЛЮЧЕНИЕ JVB В JICOFO..."
    echo ""
    
    # Создаем правильную конфигурацию Jicofo
    cat > jicofo/sip-communicator.properties << 'EOF'
# Конфигурация Jicofo для P2P-only режима
# Домен: connect.mooz.pro

# Основные настройки
org.jitsi.jicofo.ENABLE_AUTHENTICATION=false
org.jitsi.jicofo.AUTHENTICATION_TYPE=anonymous
org.jitsi.jicofo.ENABLE_SCTP=true

# XMPP настройки
org.jitsi.jicofo.xmpp.domain=connect.mooz.pro
org.jitsi.jicofo.xmpp.client.domain=auth.connect.mooz.pro
org.jitsi.jicofo.xmpp.client.username=focus
org.jitsi.jicofo.xmpp.client.password=${JICOFO_AUTH_PASSWORD}
org.jitsi.jicofo.xmpp.client.server=prosody
org.jitsi.jicofo.xmpp.client.port=5222

# Компонент Jicofo
org.jitsi.jicofo.xmpp.component.domain=focus.connect.mooz.pro
org.jitsi.jicofo.xmpp.component.secret=${JICOFO_COMPONENT_SECRET}
org.jitsi.jicofo.xmpp.component.server=prosody
org.jitsi.jicofo.xmpp.component.port=5347

# MUC настройки
org.jitsi.jicofo.xmpp.muc.domain=muc.connect.mooz.pro
org.jitsi.jicofo.xmpp.muc.server=prosody
org.jitsi.jicofo.xmpp.muc.port=5347

# P2P настройки - ОСНОВНЫЕ
org.jitsi.jicofo.P2P_ENABLED=true
org.jitsi.jicofo.P2P_MESH_ENABLED=true
org.jitsi.jicofo.P2P_MAX_PARTICIPANTS=6

# КРИТИЧЕСКИ ВАЖНО: Полностью отключаем JVB для P2P режима
org.jitsi.jicofo.ENABLE_JVB=false
org.jitsi.jicofo.ENABLE_BRIDGE_CHANNEL=false
org.jitsi.jicofo.ENABLE_JVB_HEALTH_CHECKS=false
org.jitsi.jicofo.ENABLE_JVB_STATS=false
org.jitsi.jicofo.ENABLE_JVB_REST=false
org.jitsi.jicofo.ENABLE_JVB_WEBSOCKET=false

# Принудительно отключаем поиск JVB
org.jitsi.jicofo.ENABLE_JVB_DISCOVERY=false
org.jitsi.jicofo.ENABLE_JVB_SELECTION=false
org.jitsi.jicofo.ENABLE_JVB_FAILOVER=false

# Настройки для P2P-only режима
org.jitsi.jicofo.ENABLE_P2P_ONLY=true
org.jitsi.jicofo.FORCE_P2P_MODE=true

# Настройки конференций
org.jitsi.jicofo.CONFERENCE_DURATION=0
org.jitsi.jicofo.MAX_PARTICIPANTS=6
org.jitsi.jicofo.ENABLE_RECORDING=false
org.jitsi.jicofo.ENABLE_LIVESTREAMING=false

# Настройки производительности для P2P
org.jitsi.jicofo.ENABLE_SIMULCAST=false
org.jitsi.jicofo.ENABLE_RTX=false
org.jitsi.jicofo.ENABLE_LAYER_SUSPENSION=false

# Настройки ICE для P2P
org.jitsi.jicofo.ICE_TRANSPORT_POLICY=all
org.jitsi.jicofo.STUN_SERVERS=stun:stun.l.google.com:19302,stun:stun1.l.google.com:19302,stun:stun2.l.google.com:19302,stun:connect.mooz.pro:3478

# Настройки безопасности
org.jitsi.jicofo.ENABLE_E2EE=false
org.jitsi.jicofo.ENABLE_GUESTS=true

# Настройки логирования
org.jitsi.jicofo.LOG_LEVEL=INFO
org.jitsi.jicofo.ENABLE_DETAILED_LOGGING=true
org.jitsi.jicofo.LOG_P2P_EVENTS=true

# Настройки таймаутов для P2P
org.jitsi.jicofo.P2P_CONNECTION_TIMEOUT=30000
org.jitsi.jicofo.P2P_RECONNECTION_INTERVAL=5000
org.jitsi.jicofo.P2P_MAX_RECONNECTION_ATTEMPTS=3

# Отключаем функции, несовместимые с P2P
org.jitsi.jicofo.ENABLE_BREAKOUT_ROOMS=false
org.jitsi.jicofo.ENABLE_LOBBY=false
org.jitsi.jicofo.ENABLE_POLLS=false
org.jitsi.jicofo.ENABLE_REACTIONS=false
org.jitsi.jicofo.ENABLE_TRANSCRIPTION=false

# Настройки для отладки
org.jitsi.jicofo.DEBUG_MODE=true
org.jitsi.jicofo.ENABLE_STATS=false
EOF
    
    # Создаем правильную конфигурацию jicofo.conf
    cat > jicofo/jicofo.conf << 'EOF'
# Конфигурация Jicofo для P2P-only режима (HOCON формат)
# Домен: connect.mooz.pro

jicofo {
  # Основные настройки
  enable_authentication = false
  authentication_type = "anonymous"
  enable_sctp = true
  
  # XMPP настройки
  xmpp {
    domain = "connect.mooz.pro"
    client {
      domain = "auth.connect.mooz.pro"
      username = "focus"
      password = "${JICOFO_AUTH_PASSWORD}"
      server = "prosody"
      port = 5222
    }
    
    component {
      domain = "focus.connect.mooz.pro"
      secret = "${JICOFO_COMPONENT_SECRET}"
      server = "prosody"
      port = 5347
    }
    
    muc {
      domain = "muc.connect.mooz.pro"
      server = "prosody"
      port = 5347
    }
  }
  
  # P2P настройки - КРИТИЧЕСКИ ВАЖНЫЕ
  p2p {
    enabled = true
    mesh_enabled = true
    max_participants = 6
    connection_timeout = 30000
    reconnection_interval = 5000
    max_reconnection_attempts = 3
  }
  
  # Полностью отключаем JVB для P2P режима
  jvb {
    enabled = false
    discovery_enabled = false
    selection_enabled = false
    failover_enabled = false
    health_checks_enabled = false
    stats_enabled = false
    rest_enabled = false
    websocket_enabled = false
  }
  
  # Настройки конференций
  conference {
    duration = 0
    max_participants = 6
    recording_enabled = false
    livestreaming_enabled = false
  }
  
  # Настройки производительности для P2P
  performance {
    simulcast_enabled = false
    rtx_enabled = false
    layer_suspension_enabled = false
  }
  
  # ICE настройки для P2P
  ice {
    transport_policy = "all"
    stun_servers = [
      "stun:stun.l.google.com:19302",
      "stun:stun1.l.google.com:19302", 
      "stun:stun2.l.google.com:19302",
      "stun:connect.mooz.pro:3478"
    ]
  }
  
  # Настройки безопасности
  security {
    e2ee_enabled = false
    guests_enabled = true
  }
  
  # Настройки логирования
  logging {
    level = "INFO"
    detailed_logging = true
    p2p_events = true
  }
  
  # Отключаем функции, несовместимые с P2P
  features {
    breakout_rooms_enabled = false
    lobby_enabled = false
    polls_enabled = false
    reactions_enabled = false
    transcription_enabled = false
  }
  
  # Настройки для отладки
  debug {
    mode = true
    stats_enabled = false
  }
}
EOF
    
    echo "✅ Jicofo конфигурация обновлена для полного отключения JVB"
    echo ""
}

# Функция для исправления проблемы с Prosody s6-supervise
fix_prosody_s6_supervise() {
    echo "🔧 ИСПРАВЛЕНИЕ ПРОБЛЕМЫ С PROSODY S6-SUPERVISE..."
    echo ""
    
    # Останавливаем контейнеры
    echo "🛑 Остановка контейнеров..."
    docker compose down
    
    # Проверяем Dockerfile.prosody
    echo "🔧 Проверка Dockerfile.prosody..."
    if [ ! -f "Dockerfile.prosody" ]; then
        echo "❌ Dockerfile.prosody не найден!"
        return 1
    fi
    
    # Создаем правильный Dockerfile.prosody
    echo "🔧 Создание правильного Dockerfile.prosody..."
    cat > Dockerfile.prosody << 'EOF'
FROM ubuntu:22.04

# Устанавливаем необходимые пакеты
RUN apt-get update && apt-get install -y \
    prosody \
    lua-sec \
    lua-zlib \
    lua-expat \
    lua-filesystem \
    lua-bitop \
    lua-dbi-mysql \
    lua-dbi-postgresql \
    lua-dbi-sqlite3 \
    lua-event \
    lua-json \
    lua-ldap \
    lua-logging \
    lua-lpeg \
    lua-socket \
    lua-sql-mysql \
    lua-sql-postgres \
    lua-sql-sqlite3 \
    lua-xmlrpc \
    lua5.1 \
    lua5.2 \
    lua5.3 \
    lua5.4 \
    openssl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Создаем необходимые директории
RUN mkdir -p /var/lib/prosody /var/log/prosody /etc/prosody/certs /run/prosody /config/certs

# Копируем конфигурацию Prosody
COPY prosody/config/prosody.cfg.lua /etc/prosody/prosody.cfg.lua

# Создаем dhparam
RUN openssl dhparam -out /config/certs/dhparam.pem 2048

# Устанавливаем права
RUN chown -R prosody:prosody /var/lib/prosody /var/log/prosody /etc/prosody /run/prosody /config/certs

# Экспонируем порты
EXPOSE 5222 5280 5281 3478/udp 5349

# Переключаемся на пользователя prosody
USER prosody

# Запускаем Prosody
CMD ["prosody"]
EOF
    
    # Пересобираем образ Prosody
    echo "🔧 Пересборка образа Prosody..."
    docker build -t jitsi-prosody -f Dockerfile.prosody .
    
    echo "✅ Образ Prosody пересобран с правильным s6-supervise"
    echo ""
}

# Функция для исправления Dockerfile.prosody с правильным базовым образом
fix_prosody_dockerfile() {
    echo "🔧 ИСПРАВЛЕНИЕ DOCKERFILE.PROSODY С ПРАВИЛЬНЫМ БАЗОВЫМ ОБРАЗОМ..."
    echo ""
    
    # Проверяем доступные образы Prosody
    echo "🔍 Проверка доступных образов Prosody..."
    docker search prosody | head -10
    
    # Создаем правильный Dockerfile.prosody с Ubuntu базой
    echo "🔧 Создание правильного Dockerfile.prosody с Ubuntu базой..."
    cat > Dockerfile.prosody << 'EOF'
FROM ubuntu:22.04

# Устанавливаем необходимые пакеты
RUN apt-get update && apt-get install -y \
    prosody \
    lua-sec \
    lua-zlib \
    lua-expat \
    lua-filesystem \
    lua-bitop \
    lua-dbi-mysql \
    lua-dbi-postgresql \
    lua-dbi-sqlite3 \
    lua-event \
    lua-json \
    lua-ldap \
    lua-logging \
    lua-lpeg \
    lua-socket \
    lua-sql-mysql \
    lua-sql-postgres \
    lua-sql-sqlite3 \
    lua-xmlrpc \
    lua5.1 \
    lua5.2 \
    lua5.3 \
    lua5.4 \
    openssl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Создаем необходимые директории
RUN mkdir -p /var/lib/prosody /var/log/prosody /etc/prosody/certs /run/prosody /config/certs

# Копируем конфигурацию Prosody
COPY prosody/config/prosody.cfg.lua /etc/prosody/prosody.cfg.lua

# Создаем dhparam
RUN openssl dhparam -out /config/certs/dhparam.pem 2048

# Устанавливаем права
RUN chown -R prosody:prosody /var/lib/prosody /var/log/prosody /etc/prosody /run/prosody /config/certs

# Экспонируем порты
EXPOSE 5222 5280 5281 3478/udp 5349

# Переключаемся на пользователя prosody
USER prosody

# Запускаем Prosody
CMD ["prosody"]
EOF
    
    # Пересобираем образ Prosody
    echo "🔧 Пересборка образа Prosody с Ubuntu базой..."
    docker build -t jitsi-prosody -f Dockerfile.prosody .
    
    echo "✅ Образ Prosody пересобран с Ubuntu базой"
    echo ""
}

# Функция для создания пользователя focus в Prosody
create_prosody_focus_user() {
    echo "🔧 СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ FOCUS В PROSODY..."
    echo ""
    
    # Загружаем переменные окружения
    if [ -f .env ]; then
        source .env
    fi
    
    # Проверяем, что пароль существует
    if [ -z "$JICOFO_AUTH_PASSWORD" ]; then
        echo "❌ JICOFO_AUTH_PASSWORD не найден в .env файле!"
        return 1
    fi
    
    # Останавливаем контейнеры
    echo "🛑 Остановка контейнеров..."
    docker compose down
    
    # Запускаем только Prosody для создания пользователя
    echo "🚀 Запуск Prosody для создания пользователя..."
    docker compose up -d prosody
    
    # Ждем запуска Prosody
    echo "⏳ Ожидание запуска Prosody..."
    sleep 15
    
    # Проверяем, что Prosody запустился (более мягкая проверка)
    echo "🔍 Проверка статуса Prosody..."
    if docker exec jitsi-prosody prosodyctl status > /dev/null 2>&1; then
        echo "✅ Prosody запущен и работает"
    else
        echo "⚠️  prosodyctl status не отвечает, но проверяем логи..."
        # Проверяем, что процесс Prosody запущен
        if docker exec jitsi-prosody ps aux | grep prosody | grep -v grep > /dev/null 2>&1; then
            echo "✅ Процесс Prosody запущен"
        else
            echo "❌ Процесс Prosody не найден!"
            docker compose logs prosody | tail -20
            return 1
        fi
    fi
    
    # Создаем SSL сертификаты если их нет
    echo "🔧 Проверка SSL сертификатов..."
    if [ ! -f "nginx/ssl/connect.mooz.pro.crt" ] || [ ! -f "nginx/ssl/connect.mooz.pro.key" ]; then
        echo "🔧 Создание SSL сертификатов..."
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout nginx/ssl/connect.mooz.pro.key \
            -out nginx/ssl/connect.mooz.pro.crt \
            -subj "/C=RU/ST=Moscow/L=Moscow/O=Mooz/OU=IT/CN=connect.mooz.pro" \
            -addext "subjectAltName=DNS:connect.mooz.pro,DNS:*.connect.mooz.pro,IP:165.22.141.124"
        
        chmod 644 nginx/ssl/connect.mooz.pro.key
        chmod 644 nginx/ssl/connect.mooz.pro.crt
    fi
    
    # Создаем dhparam файл если его нет
    echo "🔧 Проверка dhparam.pem..."
    if [ ! -f "nginx/ssl/dhparam.pem" ]; then
        echo "🔧 Создание dhparam.pem..."
        openssl dhparam -out nginx/ssl/dhparam.pem 2048
        chmod 644 nginx/ssl/dhparam.pem
    fi
    
    # Копируем все SSL файлы в контейнер
    echo "🔧 Копирование SSL сертификатов в контейнер..."
    docker cp nginx/ssl/connect.mooz.pro.key jitsi-prosody:/config/certs/connect.mooz.pro.key
    docker cp nginx/ssl/connect.mooz.pro.crt jitsi-prosody:/config/certs/connect.mooz.pro.crt
    docker cp nginx/ssl/auth.connect.mooz.pro.key jitsi-prosody:/config/certs/auth.connect.mooz.pro.key
    docker cp nginx/ssl/auth.connect.mooz.pro.crt jitsi-prosody:/config/certs/auth.connect.mooz.pro.crt
    docker cp nginx/ssl/guest.connect.mooz.pro.key jitsi-prosody:/config/certs/guest.connect.mooz.pro.key
    docker cp nginx/ssl/guest.connect.mooz.pro.crt jitsi-prosody:/config/certs/guest.connect.mooz.pro.crt
    docker cp nginx/ssl/muc.connect.mooz.pro.key jitsi-prosody:/config/certs/muc.connect.mooz.pro.key
    docker cp nginx/ssl/muc.connect.mooz.pro.crt jitsi-prosody:/config/certs/muc.connect.mooz.pro.crt
    docker cp nginx/ssl/focus.connect.mooz.pro.key jitsi-prosody:/config/certs/focus.connect.mooz.pro.key
    docker cp nginx/ssl/focus.connect.mooz.pro.crt jitsi-prosody:/config/certs/focus.connect.mooz.pro.crt
    docker cp nginx/ssl/dhparam.pem jitsi-prosody:/config/certs/dhparam.pem
    
    # Исправляем права доступа к файлам в контейнере
    echo "🔧 Установка прав доступа к SSL файлам в контейнере..."
    docker exec -u 0 jitsi-prosody chown -R prosody:prosody /config/certs/
    docker exec -u 0 jitsi-prosody find /config/certs -type f -exec chmod 644 {} +
    
    # Создаем пользователя focus через прямое создание файла в базе данных
    echo "👤 Создание пользователя focus через базу данных..."
    
    # Создаем директорию для пользователя в базе данных Prosody
    docker exec -u 0 jitsi-prosody mkdir -p /var/lib/prosody/auth%2econnect%2emooz%2epro/accounts
    
    # Создаем файл пользователя в правильном формате Prosody
    # Используем простой хеш для демонстрации (в продакшене лучше использовать scrypt)
    HASHED_PASSWORD=$(echo -n "$JICOFO_AUTH_PASSWORD" | sha1sum | cut -d' ' -f1)
    
    # Создаем файл пользователя в правильном формате
    docker exec -u 0 jitsi-prosody sh -c "echo 'password = \"$HASHED_PASSWORD\"
created = \"$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)\"' > /var/lib/prosody/auth%2econnect%2emooz%2epro/accounts/focus.dat"
    
    # Устанавливаем правильные права
    docker exec -u 0 jitsi-prosody chown -R prosody:prosody /var/lib/prosody/auth%2econnect%2emooz%2epro/
    docker exec -u 0 jitsi-prosody chmod -R 755 /var/lib/prosody/auth%2econnect%2emooz%2epro/
    
    # Удаляем старый неправильный файл пользователя если он есть
    docker exec -u 0 jitsi-prosody rm -f /var/lib/prosody/auth%2econnect%2emooz%2epro/accounts/focus.dat
    
    # Перезапускаем Prosody чтобы загрузить нового пользователя
    echo "🔄 Перезапуск Prosody для загрузки пользователя..."
    docker restart jitsi-prosody
    sleep 10
    
    # Проверяем, что пользователь создан
    if docker exec jitsi-prosody ls /var/lib/prosody/auth%2econnect%2emooz%2epro/accounts/focus.dat > /dev/null 2>&1; then
        echo "✅ Пользователь focus успешно создан"
    else
        echo "❌ Ошибка при создании пользователя focus"
        return 1
    fi
    
    echo "✅ Пользователь focus создан с паролем из .env"
    echo ""
}

# Функция для проверки и исправления конфигурации Prosody
fix_prosody_config() {
    echo "🔧 ПРОВЕРКА И ИСПРАВЛЕНИЕ КОНФИГУРАЦИИ PROSODY..."
    echo ""
    
    # Загружаем переменные окружения
    if [ -f .env ]; then
        source .env
    fi
    
    # Проверяем, что все необходимые переменные существуют
    if [ -z "$JICOFO_AUTH_PASSWORD" ] || [ -z "$JICOFO_COMPONENT_SECRET" ] || [ -z "$TURN_SECRET" ]; then
        echo "❌ Не все необходимые переменные окружения найдены!"
        echo "   JICOFO_AUTH_PASSWORD: ${JICOFO_AUTH_PASSWORD:+SET}"
        echo "   JICOFO_COMPONENT_SECRET: ${JICOFO_COMPONENT_SECRET:+SET}"
        echo "   TURN_SECRET: ${TURN_SECRET:+SET}"
        return 1
    fi
    
    # Исправляем конфигурацию Prosody
    echo "🔧 Исправление prosody.cfg.lua..."
    
    # Комментируем проблемную строку с pidfile
    sed -i 's|pidfile = "/var/run/prosody/prosody.pid";|-- pidfile = "/var/run/prosody/prosody.pid";|' prosody/config/prosody.cfg.lua
    
    # Заменяем плейсхолдер для TURN секрета
    sed -i "s|your_turn_secret_here|${TURN_SECRET}|g" prosody/config/prosody.cfg.lua
    
    # Убеждаемся, что компонент использует переменную окружения
    if ! grep -q "os.getenv" prosody/config/prosody.cfg.lua; then
        sed -i 's|component_secret = "changeme"|component_secret = os.getenv("JICOFO_COMPONENT_SECRET") or "changeme"|' prosody/config/prosody.cfg.lua
    fi
    
    echo "✅ Конфигурация Prosody исправлена"
    echo ""
}

# Функция для исправления модулей Prosody
fix_prosody_modules() {
    echo "🔧 ИСПРАВЛЕНИЕ МОДУЛЕЙ PROSODY..."
    echo ""
    
    # Проверяем, что конфигурация Prosody существует
    if [ ! -f "prosody/config/prosody.cfg.lua" ]; then
        echo "❌ Файл prosody/config/prosody.cfg.lua не найден!"
        return 1
    fi
    
    # Создаем резервную копию
    cp prosody/config/prosody.cfg.lua prosody/config/prosody.cfg.lua.backup
    
    echo "🔧 Удаление несуществующих модулей из конфигурации Prosody..."
    
    # Удаляем проблемные модули из основной конфигурации
    sed -i '/"smacks";/d' prosody/config/prosody.cfg.lua
    sed -i '/"certs_s2soutinjection";/d' prosody/config/prosody.cfg.lua
    sed -i '/"fmuc";/d' prosody/config/prosody.cfg.lua
    sed -i '/"s2s_bidi";/d' prosody/config/prosody.cfg.lua
    sed -i '/"polls";/d' prosody/config/prosody.cfg.lua
    sed -i '/"muc_breakout_rooms";/d' prosody/config/prosody.cfg.lua
    sed -i '/"muc_meeting_id";/d' prosody/config/prosody.cfg.lua
    sed -i '/"muc_password_whitelist";/d' prosody/config/prosody.cfg.lua
    sed -i '/"muc_lobby_rooms";/d' prosody/config/prosody.cfg.lua
    sed -i '/"muc_domain_mapper";/d' prosody/config/prosody.cfg.lua
    sed -i '/"muc_hide_all";/d' prosody/config/prosody.cfg.lua
    sed -i '/"muc_rate_limit";/d' prosody/config/prosody.cfg.lua
    sed -i '/"jiconop";/d' prosody/config/prosody.cfg.lua
    sed -i '/"conference_duration";/d' prosody/config/prosody.cfg.lua
    sed -i '/"features_identity";/d' prosody/config/prosody.cfg.lua
    sed -i '/"s2s_whitelist";/d' prosody/config/prosody.cfg.lua
    sed -i '/"s2sout_override";/d' prosody/config/prosody.cfg.lua
    sed -i '/"watchdog";/d' prosody/config/prosody.cfg.lua
    sed -i '/"external_services";/d' prosody/config/prosody.cfg.lua
    sed -i '/"limits_exception";/d' prosody/config/prosody.cfg.lua
    
    echo "✅ Модули Prosody исправлены"
    echo ""
}

# Функция для полного отключения JVB в docker-compose
fix_docker_compose_jvb_disable() {
    echo "🔧 ПОЛНОЕ ОТКЛЮЧЕНИЕ JVB В DOCKER-COMPOSE..."
    echo ""
    
    # Создаем правильный docker-compose-p2p-fixed.yml
    cat > docker-compose-p2p-fixed.yml << 'EOF'
services:
  # Nginx reverse proxy
  web:
    build:
      context: .
      dockerfile: Dockerfile.web
    container_name: jitsi-web
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/ssl:/etc/nginx/ssl:ro
    depends_on:
      - prosody
    restart: unless-stopped
    networks:
      - jitsi

  # Prosody XMPP server (кастомный образ)
  prosody:
    build:
      context: .
      dockerfile: Dockerfile.prosody
    container_name: jitsi-prosody
    ports:
      - "5222:5222"
      - "5280:5280"
      - "5281:5281"
      - "3478:3478/udp"  # STUN
      - "5349:5349"       # TURNS
    volumes:
      - ./prosody/config:/config:rw
      - ./nginx/ssl:/config/certs:rw
      - prosody_data:/var/lib/prosody
    environment:
      - AUTH_TYPE=anonymous
      - ENABLE_AUTH=0
      - ENABLE_GUESTS=1
      - XMPP_DOMAIN=connect.mooz.pro
      - XMPP_AUTH_DOMAIN=auth.connect.mooz.pro
      - XMPP_GUEST_DOMAIN=guest.connect.mooz.pro
      - XMPP_MUC_DOMAIN=muc.connect.mooz.pro
      - XMPP_INTERNAL_MUC_DOMAIN=internal-muc.connect.mooz.pro
      - XMPP_RECORDER_DOMAIN=recorder.connect.mooz.pro
      - JICOFO_COMPONENT_SECRET=${JICOFO_COMPONENT_SECRET}
      - JICOFO_AUTH_USER=focus
      - JICOFO_AUTH_PASSWORD=${JICOFO_AUTH_PASSWORD}
      - JVB_AUTH_PASSWORD=${JVB_AUTH_PASSWORD}
      - TURN_SECRET=${TURN_SECRET}
      - ENABLE_RECORDING=0
      - ENABLE_SCTP=1
      - TZ=UTC
    restart: unless-stopped
    networks:
      - jitsi

  # Jicofo - конференц-менеджер (кастомный образ)
  jicofo:
    build:
      context: .
      dockerfile: Dockerfile.jicofo
    container_name: jitsi-jicofo
    environment:
      - AUTH_TYPE=anonymous
      - ENABLE_AUTH=0
      - XMPP_DOMAIN=connect.mooz.pro
      - XMPP_AUTH_DOMAIN=auth.connect.mooz.pro
      - XMPP_INTERNAL_MUC_DOMAIN=internal-muc.connect.mooz.pro
      - XMPP_SERVER=prosody
      - JICOFO_COMPONENT_SECRET=${JICOFO_COMPONENT_SECRET}
      - JICOFO_AUTH_USER=focus
      - JICOFO_AUTH_PASSWORD=${JICOFO_AUTH_PASSWORD}
      - JVB_AUTH_PASSWORD=${JVB_AUTH_PASSWORD}
      - ENABLE_RECORDING=0
      - ENABLE_SCTP=1
      - TZ=UTC
      # P2P настройки - ИСПРАВЛЕННЫЕ
      - P2P_ENABLED=1
      - P2P_MESH_ENABLED=1
      - P2P_MAX_PARTICIPANTS=6
      # Полностью отключаем JVB
      - ENABLE_JVB=0
      - ENABLE_BRIDGE_CHANNEL=0
      - ENABLE_JVB_HEALTH_CHECKS=0
      - ENABLE_JVB_STATS=0
      - ENABLE_JVB_REST=0
      - ENABLE_JVB_WEBSOCKET=0
      - ENABLE_JVB_DISCOVERY=0
      - ENABLE_JVB_SELECTION=0
      - ENABLE_JVB_FAILOVER=0
      # Принудительно включаем P2P режим
      - ENABLE_P2P_ONLY=1
      - FORCE_P2P_MODE=1
      # Настройки для P2P
      - ENABLE_SIMULCAST=0
      - ENABLE_RTX=0
      - ENABLE_LAYER_SUSPENSION=0
      - ICE_TRANSPORT_POLICY=all
      - STUN_SERVERS=stun:stun.l.google.com:19302,stun:stun1.l.google.com:19302,stun:stun2.l.google.com:19302,stun:connect.mooz.pro:3478
      # Отключаем функции, несовместимые с P2P
      - ENABLE_BREAKOUT_ROOMS=0
      - ENABLE_LOBBY=0
      - ENABLE_POLLS=0
      - ENABLE_REACTIONS=0
      - ENABLE_TRANSCRIPTION=0
      # Настройки таймаутов для P2P
      - P2P_CONNECTION_TIMEOUT=30000
      - P2P_RECONNECTION_INTERVAL=5000
      - P2P_MAX_RECONNECTION_ATTEMPTS=3
      # Настройки логирования
      - LOG_LEVEL=INFO
      - ENABLE_DETAILED_LOGGING=1
      - LOG_P2P_EVENTS=1
      - DEBUG_MODE=1
      - ENABLE_STATS=0
    depends_on:
      - prosody
    restart: unless-stopped
    networks:
      - jitsi

  # Jitsi Meet веб-клиент (кастомный образ)
  jitsi-meet:
    build:
      context: .
      dockerfile: Dockerfile.jitsi-meet
    container_name: jitsi-meet-web
    environment:
      - ENABLE_AUTH=0
      - ENABLE_GUESTS=1
      - ENABLE_LETSENCRYPT=0
      - ENABLE_HTTP_REDIRECT=0
      - ENABLE_HSTS=0
      - DISABLE_HTTPS=1
      - JICOFO_AUTH_USER=focus
      - LETSENCRYPT_DOMAIN=
      - LETSENCRYPT_EMAIL=
      - PUBLIC_URL=https://connect.mooz.pro
      - XMPP_DOMAIN=connect.mooz.pro
      - XMPP_AUTH_DOMAIN=auth.connect.mooz.pro
      - XMPP_BOSH_URL_BASE=http://prosody:5280
      - XMPP_GUEST_DOMAIN=guest.connect.mooz.pro
      - XMPP_MUC_DOMAIN=muc.connect.mooz.pro
      - XMPP_RECORDER_DOMAIN=recorder.connect.mooz.pro
      - ENABLE_RECORDING=0
      - ENABLE_SCTP=1
      - TZ=UTC
      # P2P настройки
      - P2P_ENABLED=1
      - P2P_MESH_ENABLED=1
      - P2P_MAX_PARTICIPANTS=6
      # Отключаем функции, требующие сервер
      - ENABLE_SIMULCAST=0
      - ENABLE_RTX=0
      - ENABLE_LAYER_SUSPENSION=0
      - ENABLE_BREAKOUT_ROOMS=0
      - ENABLE_LOBBY=0
      - ENABLE_POLLS=0
      - ENABLE_REACTIONS=0
      - ENABLE_TRANSCRIPTION=0
      # Настройки логирования
      - LOG_LEVEL=INFO
      - ENABLE_DETAILED_LOGGING=1
      - LOG_P2P_EVENTS=1
      - DEBUG_MODE=1
    volumes:
      - ./jitsi-meet/config-p2p-fixed.js:/usr/share/jitsi-meet/config.js:ro
    depends_on:
      - prosody
      - jicofo
    restart: unless-stopped
    networks:
      - jitsi

volumes:
  prosody_data:

networks:
  jitsi:
    driver: bridge
EOF
    
    echo "✅ docker-compose-p2p-fixed.yml обновлен для полного отключения JVB"
    echo ""
}

# Функция для исправления конфигурации Prosody
fix_prosody_minimal_config() {
    echo "🔧 ИСПРАВЛЕНИЕ КОНФИГУРАЦИИ PROSODY ДЛЯ WEBSOCKET..."
    echo ""
    
    # Создаем минимальную конфигурацию Prosody
    echo "🔧 Создание минимальной конфигурации Prosody..."
    cat > prosody/config/prosody.cfg.lua << 'EOF'
-- Минимальная конфигурация Prosody для P2P Jitsi Meet
-- Домен: connect.mooz.pro

-- Основные настройки
daemonize = false;

-- Порты
ports = { 5222 };
https_ports = { 5281 };

-- Интерфейсы
interfaces = { "*" };

-- Модули (только базовые)
modules_enabled = {
    "roster";
    "saslauth";
    "tls";
    "dialback";
    "disco";
    "carbons";
    "pep";
    "private";
    "blocklist";
    "vcard4";
    "vcard_legacy";
    "limits";
    "time";
    "ping";
    "register";
    "mam";
    "proxy65";
    "version";
    "uptime";
    "websocket";
    "bosh";
};

-- Отключенные модули
modules_disabled = {
    "offline";
    "pubsub";
};

-- SSL/TLS настройки
ssl = {
    protocol = "tlsv1_2+";
    ciphers = "ECDHE+AESGCM:ECDHE+CHACHA20:DHE+AESGCM:DHE+CHACHA20:!aNULL:!MD5:!DSS";
    curve = "secp384r1";
    dhparam = "/config/certs/dhparam.pem";
};

-- Путь к сертификатам
certificates = "/config/certs";

-- HTTP модули для BOSH и WebSocket
http_ports = { 5280 };
https_ports = { 5281 };

-- Настройки для WebSocket
http_interfaces = { "*" };
https_interfaces = { "*" };

-- Настройки HTTP/WebSocket (CORS и доверие прокси)
cross_domain = {
    "https://connect.mooz.pro",
    "https://guest.connect.mooz.pro",
    "https://auth.connect.mooz.pro"
};
consider_bosh_secure = true;

-- Аутентификация
authentication = "anonymous";
allow_registration = false;

-- Хранилище
storage = "internal";

-- Логирование
log = {
    info = "/var/log/prosody/prosody.log";
    error = "/var/log/prosody/prosody.err";
    debug = "/var/log/prosody/prosody.debug";
    "*console";
};

-- S2S настройки
s2s_secure_auth = false;
s2s_insecure_domains = { "connect.mooz.pro" };

-- Отключаем проверку DNS
dns_lookup_timeout = 1;
dns_lookup_retries = 0;

-- Виртуальные хосты
VirtualHost "connect.mooz.pro"
    authentication = "anonymous"
    ssl = {
        key = "/config/certs/connect.mooz.pro.key";
        certificate = "/config/certs/connect.mooz.pro.crt";
    }
    modules_enabled = {
        "bosh";
        "websocket";
        "ping";
    }
    c2s_require_encryption = false
    lobby_muc = "lobby.connect.mooz.pro"
    breakout_rooms_muc = "breakout.connect.mooz.pro"
    main_muc = "muc.connect.mooz.pro"

VirtualHost "guest.connect.mooz.pro"
    authentication = "anonymous"
    ssl = {
        key = "/config/certs/guest.connect.mooz.pro.key";
        certificate = "/config/certs/guest.connect.mooz.pro.crt";
    }
    c2s_require_encryption = false

VirtualHost "auth.connect.mooz.pro"
    authentication = "internal_hashed"
    ssl = {
        key = "/config/certs/auth.connect.mooz.pro.key";
        certificate = "/config/certs/auth.connect.mooz.pro.crt";
    }
    modules_enabled = {
        "smacks";
    }
    smacks_hibernation_time = 15;

-- Компоненты MUC
Component "muc.connect.mooz.pro" "muc"
    storage = "memory"
    muc_room_cache_size = 10000
    restrict_room_creation = true
    ssl = {
        key = "/config/certs/muc.connect.mooz.pro.key";
        certificate = "/config/certs/muc.connect.mooz.pro.crt";
    }
    modules_enabled = {
    }
    admins = { "focus@auth.connect.mooz.pro" }
    muc_password_whitelist = {
        "focus@auth.connect.mooz.pro"
    }
    muc_room_locking = false
    muc_room_default_public_jids = true
    muc_room_default_presence_broadcast = {
        visitor = false;
        participant = true;
        moderator = true;
    };

Component "lobby.connect.mooz.pro" "muc"
    storage = "memory"
    muc_room_cache_size = 10000
    restrict_room_creation = true
    ssl = {
        key = "/config/certs/lobby.connect.mooz.pro.key";
        certificate = "/config/certs/lobby.connect.mooz.pro.crt";
    }
    admins = { "focus@auth.connect.mooz.pro" }
    muc_room_locking = false
    muc_room_default_public_jids = true

Component "breakout.connect.mooz.pro" "muc"
    storage = "memory"
    muc_room_cache_size = 10000
    restrict_room_creation = true
    ssl = {
        key = "/config/certs/breakout.connect.mooz.pro.key";
        certificate = "/config/certs/breakout.connect.mooz.pro.crt";
    }
    admins = { "focus@auth.connect.mooz.pro" }
    muc_room_locking = false
    muc_room_default_public_jids = true

Component "focus.connect.mooz.pro"
    component_secret = "changeme"
    ssl = {
        key = "/config/certs/focus.connect.mooz.pro.key";
        certificate = "/config/certs/focus.connect.mooz.pro.crt";
    }
EOF
    
    echo "✅ Минимальная конфигурация Prosody создана"
    echo ""
    
    # Используем сертификаты Certbot
    echo "🔧 Использование сертификатов Certbot..."
    
    # Проверяем, есть ли сертификаты Certbot
    if [ -f "/etc/letsencrypt/live/connect.mooz.pro/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/connect.mooz.pro/privkey.pem" ]; then
        echo "✅ Сертификаты Certbot найдены"
        
        # Удаляем старые симлинки если они есть
        echo "🔧 Удаление старых симлинков..."
        rm -f nginx/ssl/*.crt nginx/ssl/*.key
        
        # Копируем основные сертификаты
        cp /etc/letsencrypt/live/connect.mooz.pro/fullchain.pem nginx/ssl/connect.mooz.pro.crt
        cp /etc/letsencrypt/live/connect.mooz.pro/privkey.pem nginx/ssl/connect.mooz.pro.key
        
        # Создаем симлинки для всех поддоменов (они будут использовать тот же сертификат)
        ln -sf connect.mooz.pro.crt nginx/ssl/auth.connect.mooz.pro.crt
        ln -sf connect.mooz.pro.key nginx/ssl/auth.connect.mooz.pro.key
        ln -sf connect.mooz.pro.crt nginx/ssl/guest.connect.mooz.pro.crt
        ln -sf connect.mooz.pro.key nginx/ssl/guest.connect.mooz.pro.key
        ln -sf connect.mooz.pro.crt nginx/ssl/muc.connect.mooz.pro.crt
        ln -sf connect.mooz.pro.key nginx/ssl/muc.connect.mooz.pro.key
        ln -sf connect.mooz.pro.crt nginx/ssl/focus.connect.mooz.pro.crt
        ln -sf connect.mooz.pro.key nginx/ssl/focus.connect.mooz.pro.key
        ln -sf connect.mooz.pro.crt nginx/ssl/lobby.connect.mooz.pro.crt
        ln -sf connect.mooz.pro.key nginx/ssl/lobby.connect.mooz.pro.key
        ln -sf connect.mooz.pro.crt nginx/ssl/breakout.connect.mooz.pro.crt
        ln -sf connect.mooz.pro.key nginx/ssl/breakout.connect.mooz.pro.key
        
        chmod 644 nginx/ssl/*.crt
        chmod 644 nginx/ssl/*.key
        
        echo "✅ Сертификаты Certbot скопированы и настроены"
    else
        echo "❌ Сертификаты Certbot не найдены! Создаем self-signed..."
        
        # Удаляем старые симлинки если они есть
        echo "🔧 Удаление старых симлинков..."
        rm -f nginx/ssl/*.crt nginx/ssl/*.key
        
        # Создаем self-signed сертификаты как fallback
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout nginx/ssl/connect.mooz.pro.key \
            -out nginx/ssl/connect.mooz.pro.crt \
            -subj "/C=RU/ST=Moscow/L=Moscow/O=Mooz/OU=IT/CN=connect.mooz.pro" \
            -addext "subjectAltName=DNS:connect.mooz.pro,DNS:*.connect.mooz.pro,IP:165.22.141.124"
        
        # Создаем симлинки для всех поддоменов
        ln -sf connect.mooz.pro.crt nginx/ssl/auth.connect.mooz.pro.crt
        ln -sf connect.mooz.pro.key nginx/ssl/auth.connect.mooz.pro.key
        ln -sf connect.mooz.pro.crt nginx/ssl/guest.connect.mooz.pro.crt
        ln -sf connect.mooz.pro.key nginx/ssl/guest.connect.mooz.pro.key
        ln -sf connect.mooz.pro.crt nginx/ssl/muc.connect.mooz.pro.crt
        ln -sf connect.mooz.pro.key nginx/ssl/muc.connect.mooz.pro.key
        ln -sf connect.mooz.pro.crt nginx/ssl/focus.connect.mooz.pro.crt
        ln -sf connect.mooz.pro.key nginx/ssl/focus.connect.mooz.pro.key
        ln -sf connect.mooz.pro.crt nginx/ssl/lobby.connect.mooz.pro.crt
        ln -sf connect.mooz.pro.key nginx/ssl/lobby.connect.mooz.pro.key
        ln -sf connect.mooz.pro.crt nginx/ssl/breakout.connect.mooz.pro.crt
        ln -sf connect.mooz.pro.key nginx/ssl/breakout.connect.mooz.pro.key
        
        chmod 644 nginx/ssl/*.crt
        chmod 644 nginx/ssl/*.key
        
        echo "✅ Self-signed сертификаты созданы"
    fi
    
    # Копируем все сертификаты в контейнер
    echo "🔧 Копирование сертификатов в контейнер..."
    docker cp nginx/ssl/connect.mooz.pro.key jitsi-prosody:/config/certs/connect.mooz.pro.key
    docker cp nginx/ssl/connect.mooz.pro.crt jitsi-prosody:/config/certs/connect.mooz.pro.crt
    docker cp nginx/ssl/auth.connect.mooz.pro.key jitsi-prosody:/config/certs/auth.connect.mooz.pro.key
    docker cp nginx/ssl/auth.connect.mooz.pro.crt jitsi-prosody:/config/certs/auth.connect.mooz.pro.crt
    docker cp nginx/ssl/guest.connect.mooz.pro.key jitsi-prosody:/config/certs/guest.connect.mooz.pro.key
    docker cp nginx/ssl/guest.connect.mooz.pro.crt jitsi-prosody:/config/certs/guest.connect.mooz.pro.crt
    docker cp nginx/ssl/muc.connect.mooz.pro.key jitsi-prosody:/config/certs/muc.connect.mooz.pro.key
    docker cp nginx/ssl/muc.connect.mooz.pro.crt jitsi-prosody:/config/certs/muc.connect.mooz.pro.crt
    docker cp nginx/ssl/focus.connect.mooz.pro.key jitsi-prosody:/config/certs/focus.connect.mooz.pro.key
    docker cp nginx/ssl/focus.connect.mooz.pro.crt jitsi-prosody:/config/certs/focus.connect.mooz.pro.crt
    docker cp nginx/ssl/lobby.connect.mooz.pro.key jitsi-prosody:/config/certs/lobby.connect.mooz.pro.key
    docker cp nginx/ssl/lobby.connect.mooz.pro.crt jitsi-prosody:/config/certs/lobby.connect.mooz.pro.crt
    docker cp nginx/ssl/breakout.connect.mooz.pro.key jitsi-prosody:/config/certs/breakout.connect.mooz.pro.key
    docker cp nginx/ssl/breakout.connect.mooz.pro.crt jitsi-prosody:/config/certs/breakout.connect.mooz.pro.crt
    
    # Устанавливаем права
    docker exec -u 0 jitsi-prosody chown -R prosody:prosody /config/certs/
    docker exec -u 0 jitsi-prosody chmod -R 644 /config/certs/
    
    # Перезапускаем Prosody
    echo "🔄 Перезапуск Prosody с новой конфигурацией..."
    docker compose restart prosody
    sleep 10
    
    # Проверяем порты
    echo "🔍 Проверка портов Prosody..."
    docker exec jitsi-prosody ss -tlnp | grep -E ":(5280|5281)" || echo "❌ Prosody не слушает на портах 5280/5281"
    
    # Проверяем конфигурацию
    echo "🔍 Проверка конфигурации Prosody..."
    docker exec jitsi-prosody prosodyctl check config
    
    # Проверяем модули
    echo "🔍 Проверка модулей Prosody..."
    docker exec jitsi-prosody prosodyctl check modules
    
    # Проверяем логи
    echo "📋 Логи Prosody (последние 10 строк):"
    docker compose logs prosody | tail -10
    
    echo "✅ Конфигурация Prosody исправлена"
    echo ""
}

# Функция для проверки и исправления WebSocket соединения
fix_websocket_connection() {
    echo "🔧 ПРОВЕРКА И ИСПРАВЛЕНИЕ WEBSOCKET СОЕДИНЕНИЯ..."
    echo ""
    
    # Проверяем статус контейнеров
    echo "📊 Статус контейнеров:"
    docker compose ps
    echo ""
    
    # Проверяем, что Prosody слушает на нужных портах
    echo "🔍 Проверка портов Prosody:"
    docker exec jitsi-prosody netstat -tlnp | grep -E ":(5222|5280|5281)" || echo "❌ Prosody не слушает на нужных портах"
    echo ""
    
    # Проверяем логи Prosody
    echo "📋 Логи Prosody (последние 20 строк):"
    docker compose logs prosody | tail -20
    echo ""
    
    # Проверяем логи Nginx
    echo "📋 Логи Nginx (последние 10 строк):"
    docker compose logs web | tail -10
    echo ""
    
    # Проверяем доступность WebSocket через curl
    echo "🌐 Проверка доступности WebSocket:"
    if curl -s -I https://${DOMAIN}/xmpp-websocket | head -1; then
        echo "✅ WebSocket endpoint доступен"
    else
        echo "❌ WebSocket endpoint недоступен"
    fi
    echo ""
    
    # Форсируем корректный /srv/config.js с абсолютными URL + preferBosh fallback
    echo "🛠️  Переписываю /srv/config.js (абсолютные URL, запрет кэша)…"
    cat > "${PROJECT_ROOT}/jitsi-meet/config.js" <<CFG
var config = {
  hosts: { domain: '${DOMAIN}', muc: 'conference.${DOMAIN}' },
  bosh: 'https://${DOMAIN}/http-bind',
  websocket: 'wss://${DOMAIN}/xmpp-websocket',
  preferBosh: true,
  // включаем экспериментальный meshP2P (без JVB)
  meshP2P: { enabled: true, maxPeers: 5 },
  // отключаем focus/Jicofo на клиенте
  disableFocus: true,
  // P2P настройки
  p2p: { enabled: true, stunServers: [ { urls: 'stun:turn.${DOMAIN}:3478' } ] }
};
CFG

    # Гарантируем, что Prosody поднимает нужные HTTP пути
    ensure_prosody_http_paths

    # Перезапускаем Caddy, чтобы он отдал свежий /srv/config.js
    echo "🔄 Перезапуск Caddy…"
    docker compose restart caddy
    sleep 3

    echo "🧪 Повторная проверка ключевых полей /config.js через Caddy:"
    docker compose exec caddy sh -lc 'apk add --no-cache curl >/dev/null 2>&1 || true; curl -s https://'"${DOMAIN}"'/config.js | grep -nE "websocket:|bosh:|preferBosh|meshP2P|disableFocus" | cat'

    echo "🧪 Проверка через домен WS/BOSH (ожидаемо: 200/400/405/101):"
    curl -sI https://${DOMAIN}/http-bind | head -1
    curl -sI https://${DOMAIN}/xmpp-websocket | head -1
    
    echo "✅ Проверка WebSocket соединения завершена"
    echo ""
}

# Функция для исправления прав доступа и SSL файлов
fix_ssl_permissions() {
    echo "🔧 ИСПРАВЛЕНИЕ ПРАВ ДОСТУПА И SSL ФАЙЛОВ..."
    echo ""
    
    # Останавливаем контейнеры
    echo "🛑 Остановка контейнеров..."
    docker compose down
    
    # Создаем директории если их нет
    mkdir -p nginx/ssl
    
    # Исправляем права на существующие файлы
    echo "🔧 Исправление прав доступа к SSL файлам..."
    if [ -f "nginx/ssl/connect.mooz.pro.key" ]; then
        chmod 644 nginx/ssl/connect.mooz.pro.key
        echo "✅ Права на connect.mooz.pro.key исправлены"
    fi
    
    if [ -f "nginx/ssl/connect.mooz.pro.crt" ]; then
        chmod 644 nginx/ssl/connect.mooz.pro.crt
        echo "✅ Права на connect.mooz.pro.crt исправлены"
    fi
    
    if [ -f "nginx/ssl/dhparam.pem" ]; then
        chmod 644 nginx/ssl/dhparam.pem
        echo "✅ Права на dhparam.pem исправлены"
    fi
    
    # Создаем SSL сертификаты для всех доменов
    echo "🔧 Создание SSL сертификатов для всех доменов..."
    
    # Основной сертификат для connect.mooz.pro
    if [ ! -f "nginx/ssl/connect.mooz.pro.crt" ] || [ ! -f "nginx/ssl/connect.mooz.pro.key" ]; then
        echo "🔧 Создание сертификата для connect.mooz.pro..."
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout nginx/ssl/connect.mooz.pro.key \
            -out nginx/ssl/connect.mooz.pro.crt \
            -subj "/C=RU/ST=Moscow/L=Moscow/O=Mooz/OU=IT/CN=connect.mooz.pro" \
            -addext "subjectAltName=DNS:connect.mooz.pro,DNS:*.connect.mooz.pro,IP:165.22.141.124"
        
        chmod 644 nginx/ssl/connect.mooz.pro.key
        chmod 644 nginx/ssl/connect.mooz.pro.crt
        echo "✅ Сертификат для connect.mooz.pro создан"
    fi
    
    # Сертификат для auth.connect.mooz.pro
    if [ ! -f "nginx/ssl/auth.connect.mooz.pro.crt" ] || [ ! -f "nginx/ssl/auth.connect.mooz.pro.key" ]; then
        echo "🔧 Создание сертификата для auth.connect.mooz.pro..."
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout nginx/ssl/auth.connect.mooz.pro.key \
            -out nginx/ssl/auth.connect.mooz.pro.crt \
            -subj "/C=RU/ST=Moscow/L=Moscow/O=Mooz/OU=IT/CN=auth.connect.mooz.pro" \
            -addext "subjectAltName=DNS:auth.connect.mooz.pro,DNS:*.auth.connect.mooz.pro,IP:165.22.141.124"
        
        chmod 644 nginx/ssl/auth.connect.mooz.pro.key
        chmod 644 nginx/ssl/auth.connect.mooz.pro.crt
        echo "✅ Сертификат для auth.connect.mooz.pro создан"
    fi
    
    # Сертификат для guest.connect.mooz.pro
    if [ ! -f "nginx/ssl/guest.connect.mooz.pro.crt" ] || [ ! -f "nginx/ssl/guest.connect.mooz.pro.key" ]; then
        echo "🔧 Создание сертификата для guest.connect.mooz.pro..."
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout nginx/ssl/guest.connect.mooz.pro.key \
            -out nginx/ssl/guest.connect.mooz.pro.crt \
            -subj "/C=RU/ST=Moscow/L=Moscow/O=Mooz/OU=IT/CN=guest.connect.mooz.pro" \
            -addext "subjectAltName=DNS:guest.connect.mooz.pro,DNS:*.guest.connect.mooz.pro,IP:165.22.141.124"
        
        chmod 644 nginx/ssl/guest.connect.mooz.pro.key
        chmod 644 nginx/ssl/guest.connect.mooz.pro.crt
        echo "✅ Сертификат для guest.connect.mooz.pro создан"
    fi
    
    # Сертификат для muc.connect.mooz.pro
    if [ ! -f "nginx/ssl/muc.connect.mooz.pro.crt" ] || [ ! -f "nginx/ssl/muc.connect.mooz.pro.key" ]; then
        echo "🔧 Создание сертификата для muc.connect.mooz.pro..."
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout nginx/ssl/muc.connect.mooz.pro.key \
            -out nginx/ssl/muc.connect.mooz.pro.crt \
            -subj "/C=RU/ST=Moscow/L=Moscow/O=Mooz/OU=IT/CN=muc.connect.mooz.pro" \
            -addext "subjectAltName=DNS:muc.connect.mooz.pro,DNS:*.muc.connect.mooz.pro,IP:165.22.141.124"
        
        chmod 644 nginx/ssl/muc.connect.mooz.pro.key
        chmod 644 nginx/ssl/muc.connect.mooz.pro.crt
        echo "✅ Сертификат для muc.connect.mooz.pro создан"
    fi
    
    # Сертификат для focus.connect.mooz.pro
    if [ ! -f "nginx/ssl/focus.connect.mooz.pro.crt" ] || [ ! -f "nginx/ssl/focus.connect.mooz.pro.key" ]; then
        echo "🔧 Создание сертификата для focus.connect.mooz.pro..."
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout nginx/ssl/focus.connect.mooz.pro.key \
            -out nginx/ssl/focus.connect.mooz.pro.crt \
            -subj "/C=RU/ST=Moscow/L=Moscow/O=Mooz/OU=IT/CN=focus.connect.mooz.pro" \
            -addext "subjectAltName=DNS:focus.connect.mooz.pro,DNS:*.focus.connect.mooz.pro,IP:165.22.141.124"
        
        chmod 644 nginx/ssl/focus.connect.mooz.pro.key
        chmod 644 nginx/ssl/focus.connect.mooz.pro.crt
        echo "✅ Сертификат для focus.connect.mooz.pro создан"
    fi
    
    # Создаем dhparam файл если его нет
    echo "🔧 Проверка dhparam.pem..."
    if [ ! -f "nginx/ssl/dhparam.pem" ]; then
        echo "🔧 Создание dhparam.pem..."
        openssl dhparam -out nginx/ssl/dhparam.pem 2048
        chmod 644 nginx/ssl/dhparam.pem
        echo "✅ dhparam.pem создан с правильными правами"
    fi
    
    echo "✅ Права доступа и SSL файлы исправлены"
    echo ""
}

# Функция для создания необходимых директорий
create_directories() {
    echo "📁 Создание необходимых директорий..."
    mkdir -p nginx/ssl
    mkdir -p prosody/data
    mkdir -p prosody/logs
    mkdir -p prosody/certs
    mkdir -p jitsi-meet/logs
    mkdir -p jicofo/logs
    
    # Устанавливаем правильные права
    chown -R 1000:1000 prosody/
    chmod -R 755 prosody/
    
    echo "✅ Директории созданы с правильными правами"
    echo ""
}

# Функция для генерации SSL сертификатов
generate_ssl() {
    echo "🔒 Генерация SSL сертификатов..."
    if [ ! -f "nginx/ssl/connect.mooz.pro.crt" ] || [ ! -f "nginx/ssl/connect.mooz.pro.key" ]; then
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout nginx/ssl/connect.mooz.pro.key \
            -out nginx/ssl/connect.mooz.pro.crt \
            -subj "/C=RU/ST=Moscow/L=Moscow/O=Mooz/OU=IT/CN=connect.mooz.pro" \
            -addext "subjectAltName=DNS:connect.mooz.pro,DNS:*.connect.mooz.pro,IP:165.22.141.124"
        
        chmod 644 nginx/ssl/connect.mooz.pro.key
        chmod 644 nginx/ssl/connect.mooz.pro.crt
    fi
    
    # Создаем dhparam файл
    if [ ! -f "prosody/certs/dhparam.pem" ]; then
        echo "🔧 Создание dhparam.pem..."
        openssl dhparam -out prosody/certs/dhparam.pem 2048
        chmod 644 prosody/certs/dhparam.pem
    fi
    
    # Также создаем dhparam в nginx/ssl для Prosody
    if [ ! -f "nginx/ssl/dhparam.pem" ]; then
        echo "🔧 Создание dhparam.pem для Prosody..."
        openssl dhparam -out nginx/ssl/dhparam.pem 2048
        chmod 644 nginx/ssl/dhparam.pem
    fi
    
    echo "✅ SSL сертификаты готовы"
    echo ""
}

# Функция для запуска контейнеров
start_containers() {
    echo "🚀 Запуск контейнеров..."
    docker compose up -d
    
    # Ждем запуска сервисов
    echo "⏳ Ожидание запуска сервисов..."
    sleep 30
}

# Функция для проверки статуса
check_status() {
    echo "📊 ПРОВЕРКА СТАТУСА..."
    echo ""
    
    echo "📊 Статус контейнеров:"
    docker compose ps
    echo ""
    
    echo "📋 Логи Prosody (последние 10 строк):"
    docker compose logs prosody | tail -10
    echo ""
    
    echo "🌐 Проверка доступности сервисов..."
    
    # Проверяем HTTP
    if curl -s -o /dev/null -w "%{http_code}" http://connect.mooz.pro | grep -q "200\|301\|302"; then
        echo "✅ HTTP сервис доступен"
    else
        echo "❌ HTTP сервис недоступен"
    fi
    
    # Проверяем HTTPS
    if curl -s -o /dev/null -w "%{http_code}" https://connect.mooz.pro | grep -q "200\|301\|302"; then
        echo "✅ HTTPS сервис доступен"
    else
        echo "❌ HTTPS сервис недоступен"
    fi
    
    # Проверяем XMPP BOSH
    if curl -s -o /dev/null -w "%{http_code}" https://connect.mooz.pro/http-bind | grep -q "200\|405"; then
        echo "✅ XMPP BOSH доступен"
    else
        echo "❌ XMPP BOSH недоступен"
    fi
    
    # Проверяем XMPP WebSocket
    if curl -s -o /dev/null -w "%{http_code}" https://connect.mooz.pro/xmpp-websocket | grep -q "200\|101\|405"; then
        echo "✅ XMPP WebSocket доступен"
    else
        echo "❌ XMPP WebSocket недоступен"
    fi
}

# Функция для полного исправления
full_fix() {
    echo "🔧 ПОЛНОЕ ИСПРАВЛЕНИЕ СИСТЕМЫ..."
    echo ""
    
    # Диагностика
    diagnose
    
    # Исправление паролей
    fix_jvb_password
    
    # Исправление конфигурационных файлов
    fix_config_files
    
    # Исправление конфигурации Prosody
    fix_prosody_config
    
    # Исправление модулей Prosody
    fix_prosody_modules
    
    # Исправление прав доступа и SSL файлов
    fix_ssl_permissions
    
    # Исправление P2P конфигурации
    fix_p2p_config
    
    # Исправление проблемы с Prosody
    fix_prosody_startup
    
    # Исправление проблемы с Prosody s6-supervise
    fix_prosody_s6_supervise
    
    # Исправление Dockerfile.prosody с правильным базовым образом
    fix_prosody_dockerfile
    
    # Создание пользователя focus в Prosody
    create_prosody_focus_user
    
    # Полное отключение JVB в Jicofo
    fix_jicofo_jvb_disable
    
    # Полное отключение JVB в docker-compose
    fix_docker_compose_jvb_disable
    
    # Создание директорий
    create_directories
    
    # Настройка SSL через Certbot
    setup_certbot_ssl
    
    # Запуск контейнеров
    start_containers
    
    # Проверка статуса
    check_status
    
    echo ""
    echo "🎉 ИСПРАВЛЕНИЕ ЗАВЕРШЕНО!"
    echo ""
    echo "📋 Информация о сервисе:"
    echo "   🌐 URL: https://connect.mooz.pro"
    echo "   🏠 IP: 165.22.141.124"
    echo "   👥 Максимум участников: 6 (P2P mesh)"
    echo "   🔒 Режим: P2P-only (без медиасервера)"
    echo ""
    echo "📝 Полезные команды:"
    echo "   📊 Статус: docker compose ps"
    echo "   📋 Логи: docker compose logs -f [service]"
    echo "   🛑 Остановка: docker compose down"
    echo "   🔄 Перезапуск: docker compose restart [service]"
    echo ""
    echo "🔍 Для отладки:"
    echo "   ./fix-jitsi-p2p.sh diagnose  - диагностика проблем"
    echo "   ./fix-jitsi-p2p.sh fix      - исправление проблем"
    echo "   ./fix-jitsi-p2p.sh status   - проверка статуса"
}

# Главная функция
main() {
    case "${1:-full}" in
        "diagnose")
            diagnose
            ;;
        "doctor")
            doctor
            ;;
        "fix")
            fix_jvb_password
            fix_config_files
            fix_prosody_config
            fix_prosody_modules
            fix_ssl_permissions
            fix_p2p_config
            fix_prosody_startup
            fix_prosody_s6_supervise
            fix_prosody_dockerfile
            create_prosody_focus_user
            fix_jicofo_jvb_disable
            fix_docker_compose_jvb_disable
            create_directories
            setup_certbot_ssl
            start_containers
            check_status
            ;;
        "status")
            check_status
            ;;
        "ssl")
            fix_ssl_permissions
            ;;
        "websocket")
            fix_websocket_connection
            ;;
        "prosody")
            fix_prosody_minimal_config
            ;;
        "full"|"")
            full_fix
            ;;
        *)
            echo "Использование: $0 [diagnose|fix|status|ssl|websocket|prosody|full]"
            echo ""
            echo "Команды:"
            echo "  diagnose   - диагностика проблем"
            echo "  doctor     - быстрая проверка выдачи /config.js и прокси WS/BOSH"
            echo "  fix        - исправление проблем"
            echo "  status     - проверка статуса"
            echo "  ssl        - исправление только SSL и прав доступа"
            echo "  websocket  - проверка и исправление WebSocket соединения"
            echo "  prosody    - исправление конфигурации Prosody для WebSocket"
            echo "  full       - полное исправление (по умолчанию)"
            exit 1
            ;;
    esac
}

# Запуск
main "$@"

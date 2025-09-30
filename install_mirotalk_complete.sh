#!/bin/bash

# Полный автоматический скрипт установки MiroTalk
# Выполняет всю установку одной командой без остановок

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Функции для вывода сообщений
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

# Проверка прав root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Этот скрипт должен быть запущен с правами root (sudo)"
        exit 1
    fi
}

# Создание всех необходимых файлов и директорий
setup_complete() {
    log_info "Создание полной структуры MiroTalk..."
    
    # Создание директорий
    mkdir -p /opt/mirotalk/{nginx/conf.d,ssl,certbot/{conf,www},logs,data,recordings}
    
    # Клонирование MiroTalk
    cd /opt/mirotalk
    if [[ -d "mirotalk" ]]; then
        cd mirotalk
        git pull origin master
        cd ..
    else
        git clone https://github.com/miroslavpejic85/mirotalk.git
        cd mirotalk
        git checkout master
        cd ..
    fi
    
    # Создание .env файла
    cat > /opt/mirotalk/.env << 'EOF'
# Основные настройки
DOMAIN=connect.mooz.pro
PORT=3000
NODE_ENV=production

# Настройки SSL
SSL_ENABLED=true
SSL_CERT_PATH=/etc/nginx/ssl/fullchain.pem
SSL_KEY_PATH=/etc/nginx/ssl/privkey.pem

# Настройки P2P
P2P_ENABLED=true
STUN_SERVERS=stun:stun.l.google.com:19302,stun:stun1.l.google.com:19302
TURN_SERVERS=

# Настройки комнат
MAX_PARTICIPANTS=10
ROOM_NAME_LENGTH=10
ROOM_EXPIRY_TIME=24

# Настройки логирования
LOG_LEVEL=info
LOG_FILE=/app/logs/mirotalk.log

# Настройки безопасности
CORS_ORIGIN=*
RATE_LIMIT=true
RATE_LIMIT_WINDOW=15
RATE_LIMIT_MAX=100

# Настройки уведомлений
ENABLE_NOTIFICATIONS=true
NOTIFICATION_SOUND=true

# Настройки записи (опционально)
ENABLE_RECORDING=false
RECORDING_PATH=/app/recordings
EOF

    # Создание docker-compose.yml
    cat > /opt/mirotalk/docker-compose.yml << 'EOF'
version: '3.8'

services:
  # Основной сервис MiroTalk
  mirotalk:
    image: node:18-alpine
    container_name: mirotalk
    restart: unless-stopped
    working_dir: /app
    volumes:
      - ./mirotalk:/app
      - /app/node_modules
    ports:
      - "3000:3000"
    environment:
      - NODE_ENV=production
      - DOMAIN=connect.mooz.pro
      - PORT=3000
    command: sh -c "npm install && npm start"
    networks:
      - mirotalk-network

  # Nginx для проксирования и SSL
  nginx:
    image: nginx:alpine
    container_name: mirotalk-nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - ./ssl:/etc/nginx/ssl:ro
      - ./certbot/conf:/etc/letsencrypt:ro
      - ./certbot/www:/var/www/certbot:ro
    depends_on:
      - mirotalk
    networks:
      - mirotalk-network

  # Certbot для SSL сертификатов
  certbot:
    image: certbot/certbot
    container_name: mirotalk-certbot
    volumes:
      - ./certbot/conf:/etc/letsencrypt
      - ./certbot/www:/var/www/certbot
    command: certonly --webroot --webroot-path=/var/www/certbot --email admin@mooz.pro --agree-tos --no-eff-email -d connect.mooz.pro
    networks:
      - mirotalk-network

networks:
  mirotalk-network:
    driver: bridge

volumes:
  mirotalk-data:
EOF

    # Создание nginx.conf
    cat > /opt/mirotalk/nginx/nginx.conf << 'EOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log notice;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
    use epoll;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # Логирование
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';

    access_log /var/log/nginx/access.log main;

    # Основные настройки
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    client_max_body_size 100M;

    # Gzip сжатие
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types
        text/plain
        text/css
        text/xml
        text/javascript
        application/json
        application/javascript
        application/xml+rss
        application/atom+xml
        image/svg+xml;

    # Безопасность
    server_tokens off;
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";

    # Подключение конфигураций сайтов
    include /etc/nginx/conf.d/*.conf;
}
EOF

    # Создание временной конфигурации nginx (без SSL)
    cat > /opt/mirotalk/nginx/conf.d/mirotalk.conf << 'EOF'
# HTTP сервер для редиректа на HTTPS и Let's Encrypt
server {
    listen 80;
    server_name connect.mooz.pro;

    # Let's Encrypt challenge
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # Временный прокси на MiroTalk (пока нет SSL)
    location / {
        proxy_pass http://mirotalk:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
        proxy_read_timeout 86400;
    }

    # Статические файлы
    location /static/ {
        proxy_pass http://mirotalk:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # Кэширование статических файлов
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    # API endpoints
    location /api/ {
        proxy_pass http://mirotalk:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # CORS headers
        add_header Access-Control-Allow-Origin *;
        add_header Access-Control-Allow-Methods "GET, POST, OPTIONS";
        add_header Access-Control-Allow-Headers "DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range";
    }

    # Логирование
    access_log /var/log/nginx/mirotalk.access.log;
    error_log /var/log/nginx/mirotalk.error.log;
}
EOF

    log_success "Структура файлов создана"
}

# Настройка firewall
setup_firewall() {
    log_info "Настройка firewall..."
    
    if command -v ufw &> /dev/null; then
        ufw --force reset
        ufw default deny incoming
        ufw default allow outgoing
        ufw allow ssh
        ufw allow 80/tcp
        ufw allow 443/tcp
        ufw --force enable
        log_success "UFW настроен"
    elif command -v firewall-cmd &> /dev/null; then
        systemctl start firewalld
        systemctl enable firewalld
        firewall-cmd --permanent --add-service=ssh
        firewall-cmd --permanent --add-service=http
        firewall-cmd --permanent --add-service=https
        firewall-cmd --reload
        log_success "Firewalld настроен"
    else
        log_warning "Firewall не найден. Убедитесь, что порты 80 и 443 открыты"
    fi
}

# Запуск сервисов
start_services() {
    log_info "Запуск сервисов MiroTalk..."
    
    cd /opt/mirotalk
    
    # Остановка существующих контейнеров
    docker compose down 2>/dev/null || true
    
    # Запуск MiroTalk
    log_info "Запуск MiroTalk..."
    docker compose up -d mirotalk
    
    # Ожидание запуска MiroTalk
    log_info "Ожидание запуска MiroTalk (это может занять несколько минут)..."
    sleep 60
    
    # Запуск nginx
    log_info "Запуск Nginx..."
    docker compose up -d nginx
    
    # Ожидание запуска nginx
    sleep 10
    
    # Проверка статуса
    log_info "Статус сервисов:"
    docker compose ps
    
    log_success "Основные сервисы запущены"
}

# Настройка SSL (опционально)
setup_ssl() {
    log_info "Попытка получения SSL сертификата..."
    
    cd /opt/mirotalk
    
    # Получение SSL сертификата
    if docker compose run --rm certbot certonly \
        --webroot \
        --webroot-path=/var/www/certbot \
        --email admin@mooz.pro \
        --agree-tos \
        --no-eff-email \
        -d connect.mooz.pro 2>/dev/null; then
        
        log_success "SSL сертификат получен"
        
        # Обновление конфигурации nginx для HTTPS
        cat > /opt/mirotalk/nginx/conf.d/mirotalk.conf << 'EOF'
# HTTP сервер для редиректа на HTTPS и Let's Encrypt
server {
    listen 80;
    server_name connect.mooz.pro;

    # Let's Encrypt challenge
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # Редирект всего остального на HTTPS
    location / {
        return 301 https://$server_name$request_uri;
    }
}

# HTTPS сервер
server {
    listen 443 ssl http2;
    server_name connect.mooz.pro;

    # SSL сертификаты
    ssl_certificate /etc/letsencrypt/live/connect.mooz.pro/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/connect.mooz.pro/privkey.pem;

    # SSL настройки
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # HSTS
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # WebSocket поддержка
    location / {
        proxy_pass http://mirotalk:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
        proxy_read_timeout 86400;
    }

    # Статические файлы
    location /static/ {
        proxy_pass http://mirotalk:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    # API endpoints
    location /api/ {
        proxy_pass http://mirotalk:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        add_header Access-Control-Allow-Origin *;
        add_header Access-Control-Allow-Methods "GET, POST, OPTIONS";
        add_header Access-Control-Allow-Headers "DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range";
    }

    access_log /var/log/nginx/mirotalk.access.log;
    error_log /var/log/nginx/mirotalk.error.log;
}
EOF

        # Перезагрузка nginx
        docker compose exec nginx nginx -s reload
        
        log_success "HTTPS настроен"
    else
        log_warning "Не удалось получить SSL сертификат"
        log_info "MiroTalk будет доступен по HTTP: http://connect.mooz.pro"
    fi
}

# Создание systemd сервиса
create_systemd_service() {
    log_info "Создание systemd сервиса..."
    
    cat > /etc/systemd/system/mirotalk.service << EOF
[Unit]
Description=MiroTalk Video Conference Service
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/mirotalk
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable mirotalk.service
    
    log_success "Systemd сервис создан"
}

# Финальная проверка
final_check() {
    log_info "Финальная проверка..."
    
    cd /opt/mirotalk
    docker compose ps
    
    # Проверка доступности
    log_info "Проверка доступности..."
    
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:3000 | grep -q "200"; then
        log_success "MiroTalk доступен на порту 3000"
    fi
    
    if curl -s -o /dev/null -w "%{http_code}" http://localhost | grep -q "200"; then
        log_success "Nginx прокси работает"
    fi
    
    log_success "Установка завершена!"
    log_info "MiroTalk доступен по адресу: http://connect.mooz.pro"
    log_info "Для HTTPS настройте SSL сертификат вручную позже"
}

# Основная функция
main() {
    log_info "🚀 Начинаем полную установку MiroTalk для домена connect.mooz.pro"
    
    check_root
    setup_complete
    setup_firewall
    start_services
    setup_ssl
    create_systemd_service
    final_check
    
    log_success "🎉 Установка MiroTalk завершена успешно!"
    log_info "Управление сервисами:"
    log_info "  systemctl start mirotalk   - запуск"
    log_info "  systemctl stop mirotalk    - остановка"
    log_info "  docker compose logs -f     - логи"
}

# Запуск
main "$@"

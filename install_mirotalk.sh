#!/bin/bash

# Скрипт установки MiroTalk для сервера
# Домен: connect.mooz.pro
# Автор: DevOps Expert

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функция для вывода сообщений
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Проверка прав root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Этот скрипт должен быть запущен с правами root (sudo)"
        exit 1
    fi
}

# Проверка операционной системы
check_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$NAME
        VER=$VERSION_ID
    else
        log_error "Не удалось определить операционную систему"
        exit 1
    fi
    
    log_info "Обнаружена ОС: $OS $VER"
}

# Обновление системы
update_system() {
    log_info "Обновление системы..."
    
    if [[ $OS == *"Ubuntu"* ]] || [[ $OS == *"Debian"* ]]; then
        apt update && apt upgrade -y
        apt install -y curl wget git unzip software-properties-common apt-transport-https ca-certificates gnupg lsb-release
    elif [[ $OS == *"CentOS"* ]] || [[ $OS == *"Red Hat"* ]]; then
        yum update -y
        yum install -y curl wget git unzip
    else
        log_warning "Неподдерживаемая ОС. Продолжаем с базовыми пакетами..."
    fi
    
    log_success "Система обновлена"
}

# Проверка и установка Docker
install_docker() {
    log_info "Проверка установки Docker..."
    
    if command -v docker &> /dev/null; then
        log_success "Docker уже установлен"
        docker --version
    else
        log_info "Установка Docker..."
        
        if [[ $OS == *"Ubuntu"* ]] || [[ $OS == *"Debian"* ]]; then
            # Удаление старых версий
            apt remove -y docker docker-engine docker.io containerd runc
            
            # Установка зависимостей
            apt install -y apt-transport-https ca-certificates curl gnupg lsb-release
            
            # Добавление GPG ключа Docker
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
            
            # Добавление репозитория Docker
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
            
            # Установка Docker
            apt update
            apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        elif [[ $OS == *"CentOS"* ]] || [[ $OS == *"Red Hat"* ]]; then
            yum install -y yum-utils
            yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        fi
        
        # Запуск и включение Docker
        systemctl start docker
        systemctl enable docker
        
        # Проверка установки
        docker --version
        docker compose version
        
        log_success "Docker установлен успешно"
    fi
}

# Проверка и установка Docker Compose
install_docker_compose() {
    log_info "Проверка Docker Compose..."
    
    if docker compose version &> /dev/null; then
        log_success "Docker Compose уже установлен"
        docker compose version
    else
        log_info "Установка Docker Compose..."
        
        # Определение архитектуры
        ARCH=$(uname -m)
        case $ARCH in
            x86_64) ARCH="x86_64" ;;
            aarch64) ARCH="aarch64" ;;
            armv7l) ARCH="armv7" ;;
            *) log_error "Неподдерживаемая архитектура: $ARCH"; exit 1 ;;
        esac
        
        # Загрузка и установка Docker Compose
        COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d\" -f4)
        curl -L "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-${ARCH}" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
        
        # Создание символической ссылки
        ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
        
        log_success "Docker Compose установлен: $COMPOSE_VERSION"
    fi
}

# Создание необходимых директорий
create_directories() {
    log_info "Создание необходимых директорий..."
    
    mkdir -p /opt/mirotalk/{nginx/conf.d,ssl,certbot/{conf,www},logs,data,recordings}
    mkdir -p /var/log/mirotalk
    
    log_success "Директории созданы"
}

# Клонирование MiroTalk
clone_mirotalk() {
    log_info "Клонирование MiroTalk..."
    
    cd /opt/mirotalk
    
    if [[ -d "mirotalk" ]]; then
        log_warning "Директория mirotalk уже существует. Обновляем..."
        cd mirotalk
        git pull origin master
    else
        git clone https://github.com/miroslavpejic85/mirotalk.git
        cd mirotalk
        git checkout master
    fi
    
    log_success "MiroTalk клонирован/обновлен"
}

# Настройка конфигурационных файлов
setup_config() {
    log_info "Настройка конфигурационных файлов..."
    
    cd /opt/mirotalk
    
    # Копирование файлов конфигурации
    cp /opt/mirotalk/mirotalk/.env.template .env 2>/dev/null || echo "Файл .env.template не найден, создаем базовый .env"
    
    # Настройка .env файла
    cat > .env << EOF
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

    # Копирование nginx конфигурации
    cp nginx/nginx.conf /opt/mirotalk/nginx/
    cp nginx/conf.d/mirotalk.conf /opt/mirotalk/nginx/conf.d/
    
    log_success "Конфигурационные файлы настроены"
}

# Настройка firewall
setup_firewall() {
    log_info "Настройка firewall..."
    
    # Проверка наличия ufw
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
        log_warning "Firewall не найден. Убедитесь, что порты 80 и 443 открыты в вашем облачном провайдере"
    fi
}

# Получение SSL сертификата
setup_ssl() {
    log_info "Настройка SSL сертификата..."
    
    # Временный запуск nginx для получения сертификата
    docker compose up -d nginx
    
    # Ожидание запуска nginx
    sleep 10
    
    # Получение сертификата через certbot
    docker compose run --rm certbot certonly \
        --webroot \
        --webroot-path=/var/www/certbot \
        --email admin@mooz.pro \
        --agree-tos \
        --no-eff-email \
        -d connect.mooz.pro
    
    if [[ $? -eq 0 ]]; then
        log_success "SSL сертификат получен успешно"
    else
        log_error "Не удалось получить SSL сертификат"
        log_warning "Убедитесь, что домен connect.mooz.pro указывает на IP этого сервера"
        log_warning "Попробуйте получить сертификат вручную позже"
    fi
}

# Запуск всех сервисов
start_services() {
    log_info "Запуск всех сервисов..."
    
    cd /opt/mirotalk
    
    # Остановка существующих контейнеров
    docker compose down 2>/dev/null || true
    
    # Запуск всех сервисов
    docker compose up -d
    
    # Ожидание запуска
    sleep 15
    
    # Проверка статуса
    docker compose ps
    
    log_success "Сервисы запущены"
}

# Настройка автоматического обновления сертификатов
setup_ssl_renewal() {
    log_info "Настройка автоматического обновления SSL сертификатов..."
    
    # Создание cron задачи для обновления сертификатов
    cat > /etc/cron.d/mirotalk-ssl-renewal << EOF
# Обновление SSL сертификатов MiroTalk
0 12 * * * root cd /opt/mirotalk && docker compose run --rm certbot renew && docker compose exec nginx nginx -s reload
EOF

    log_success "Автоматическое обновление SSL сертификатов настроено"
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
    
    log_success "Systemd сервис создан и включен"
}

# Финальная проверка
final_check() {
    log_info "Выполнение финальной проверки..."
    
    # Проверка статуса контейнеров
    cd /opt/mirotalk
    docker compose ps
    
    # Проверка доступности сервиса
    log_info "Проверка доступности сервиса..."
    
    # Проверка HTTP (должен редиректить на HTTPS)
    if curl -s -o /dev/null -w "%{http_code}" http://connect.mooz.pro | grep -q "301\|302"; then
        log_success "HTTP редирект работает"
    else
        log_warning "HTTP редирект не работает"
    fi
    
    # Проверка HTTPS
    if curl -s -o /dev/null -w "%{http_code}" https://connect.mooz.pro | grep -q "200"; then
        log_success "HTTPS доступен"
    else
        log_warning "HTTPS недоступен"
    fi
    
    log_success "Установка завершена!"
    log_info "MiroTalk доступен по адресу: https://connect.mooz.pro"
}

# Основная функция
main() {
    log_info "Начинаем установку MiroTalk для домена connect.mooz.pro"
    
    check_root
    check_os
    update_system
    install_docker
    install_docker_compose
    create_directories
    clone_mirotalk
    setup_config
    setup_firewall
    setup_ssl
    start_services
    setup_ssl_renewal
    create_systemd_service
    final_check
    
    log_success "Установка MiroTalk завершена успешно!"
    log_info "Для управления сервисом используйте:"
    log_info "  systemctl start mirotalk   - запуск"
    log_info "  systemctl stop mirotalk    - остановка"
    log_info "  systemctl status mirotalk  - статус"
    log_info "  docker compose logs -f     - логи"
}

# Запуск основной функции
main "$@"


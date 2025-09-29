#!/bin/bash

# Скрипт настройки TURN сервера для MiroTalk
# Улучшает P2P соединения через NAT

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функции для вывода сообщений
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

# Переменные
DOMAIN="connect.mooz.pro"
TURN_USERNAME="mirotalk"
TURN_PASSWORD=""
TURN_REALM="connect.mooz.pro"
TURN_PORT=3478
TURN_TLS_PORT=5349

# Проверка прав root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Этот скрипт должен быть запущен с правами root (sudo)"
        exit 1
    fi
}

# Генерация пароля для TURN
generate_turn_password() {
    TURN_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    log_info "Сгенерирован пароль для TURN сервера"
}

# Установка coturn
install_coturn() {
    log_info "Установка coturn (TURN сервер)..."
    
    if command -v turnserver &> /dev/null; then
        log_success "coturn уже установлен"
        return 0
    fi
    
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$NAME
    fi
    
    if [[ $OS == *"Ubuntu"* ]] || [[ $OS == *"Debian"* ]]; then
        apt update
        apt install -y coturn
    elif [[ $OS == *"CentOS"* ]] || [[ $OS == *"Red Hat"* ]]; then
        yum install -y coturn
    else
        log_error "Неподдерживаемая ОС для установки coturn"
        exit 1
    fi
    
    systemctl enable coturn
    log_success "coturn установлен"
}

# Настройка конфигурации TURN
configure_turn() {
    log_info "Настройка конфигурации TURN сервера..."
    
    generate_turn_password
    
    # Создание конфигурационного файла
    cat > /etc/turnserver.conf << EOF
# Основные настройки
listening-port=${TURN_PORT}
tls-listening-port=${TURN_TLS_PORT}
listening-ip=0.0.0.0
external-ip=$(curl -s ifconfig.me)

# Домен
realm=${TURN_REALM}

# Аутентификация
user=${TURN_USERNAME}:${TURN_PASSWORD}

# SSL/TLS сертификаты (будут созданы позже)
cert=/etc/ssl/certs/turn.crt
pkey=/etc/ssl/private/turn.key

# Безопасность
no-multicast-peers
no-cli
no-tlsv1
no-tlsv1_1

# Логирование
log-file=/var/log/turnserver.log
verbose

# Производительность
total-quota=100
stale-nonce=600

# P2P настройки
no-tcp-relay
no-udp-relay
no-tcp
udp-only

# Ограничения
denied-peer-ip=0.0.0.0-0.255.255.255
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255

# Разрешенные IP
allowed-peer-ip=0.0.0.0-255.255.255.255
EOF

    log_success "Конфигурация TURN сервера создана"
}

# Создание SSL сертификатов для TURN
create_turn_ssl() {
    log_info "Создание SSL сертификатов для TURN сервера..."
    
    # Создание директорий
    mkdir -p /etc/ssl/certs /etc/ssl/private
    
    # Создание самоподписанного сертификата
    openssl req -x509 -newkey rsa:4096 -keyout /etc/ssl/private/turn.key \
        -out /etc/ssl/certs/turn.crt -days 365 -nodes \
        -subj "/C=RU/ST=Moscow/L=Moscow/O=MiroTalk/OU=IT/CN=${DOMAIN}"
    
    # Установка прав доступа
    chmod 600 /etc/ssl/private/turn.key
    chmod 644 /etc/ssl/certs/turn.crt
    
    log_success "SSL сертификаты для TURN созданы"
}

# Настройка firewall для TURN
setup_turn_firewall() {
    log_info "Настройка firewall для TURN сервера..."
    
    # Проверка наличия ufw
    if command -v ufw &> /dev/null; then
        ufw allow ${TURN_PORT}/udp
        ufw allow ${TURN_TLS_PORT}/tcp
        ufw allow 49152:65535/udp  # Диапазон портов для реле
        log_success "UFW настроен для TURN"
    elif command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --add-port=${TURN_PORT}/udp
        firewall-cmd --permanent --add-port=${TURN_TLS_PORT}/tcp
        firewall-cmd --permanent --add-port=49152-65535/udp
        firewall-cmd --reload
        log_success "Firewalld настроен для TURN"
    else
        log_warning "Firewall не найден. Убедитесь, что порты ${TURN_PORT}/udp и ${TURN_TLS_PORT}/tcp открыты"
    fi
}

# Запуск TURN сервера
start_turn_server() {
    log_info "Запуск TURN сервера..."
    
    systemctl start coturn
    systemctl status coturn --no-pager
    
    if systemctl is-active --quiet coturn; then
        log_success "TURN сервер запущен"
    else
        log_error "Не удалось запустить TURN сервер"
        exit 1
    fi
}

# Обновление конфигурации MiroTalk
update_mirotalk_config() {
    log_info "Обновление конфигурации MiroTalk для использования TURN сервера..."
    
    local mirotalk_env="/opt/mirotalk/.env"
    
    if [[ -f "$mirotalk_env" ]]; then
        # Обновление TURN серверов в .env
        sed -i "s|TURN_SERVERS=.*|TURN_SERVERS=turn:${DOMAIN}:${TURN_PORT}:${TURN_USERNAME}:${TURN_PASSWORD}|" "$mirotalk_env"
        
        # Добавление TURN конфигурации если её нет
        if ! grep -q "TURN_SERVERS" "$mirotalk_env"; then
            echo "TURN_SERVERS=turn:${DOMAIN}:${TURN_PORT}:${TURN_USERNAME}:${TURN_PASSWORD}" >> "$mirotalk_env"
        fi
        
        log_success "Конфигурация MiroTalk обновлена"
    else
        log_warning "Файл конфигурации MiroTalk не найден: $mirotalk_env"
    fi
}

# Создание скрипта мониторинга TURN
create_turn_monitor() {
    log_info "Создание скрипта мониторинга TURN сервера..."
    
    cat > /usr/local/bin/turn-monitor.sh << 'EOF'
#!/bin/bash

# Мониторинг TURN сервера
log_file="/var/log/turnserver.log"

if [[ ! -f "$log_file" ]]; then
    echo "Лог файл TURN сервера не найден"
    exit 1
fi

echo "=== Статус TURN сервера ==="
systemctl status coturn --no-pager

echo ""
echo "=== Последние подключения ==="
tail -20 "$log_file" | grep -E "(allocate|relay)" || echo "Нет активных подключений"

echo ""
echo "=== Статистика ==="
netstat -an | grep ":3478\|:5349" | wc -l | xargs echo "Активные соединения:"
EOF

    chmod +x /usr/local/bin/turn-monitor.sh
    
    log_success "Скрипт мониторинга создан: /usr/local/bin/turn-monitor.sh"
}

# Сохранение конфигурации
save_config() {
    log_info "Сохранение конфигурации TURN сервера..."
    
    local config_file="/opt/mirotalk/turn_config.txt"
    
    cat > "$config_file" << EOF
# Конфигурация TURN сервера для MiroTalk
# Создано: $(date)

Домен: ${DOMAIN}
Порт UDP: ${TURN_PORT}
Порт TLS: ${TURN_TLS_PORT}
Пользователь: ${TURN_USERNAME}
Пароль: ${TURN_PASSWORD}
Realm: ${TURN_REALM}

# Настройки для MiroTalk .env
TURN_SERVERS=turn:${DOMAIN}:${TURN_PORT}:${TURN_USERNAME}:${TURN_PASSWORD}

# Команды управления
systemctl start coturn    # Запуск
systemctl stop coturn     # Остановка
systemctl restart coturn  # Перезапуск
systemctl status coturn   # Статус
turn-monitor.sh           # Мониторинг
EOF

    log_success "Конфигурация сохранена в: $config_file"
}

# Тестирование TURN сервера
test_turn_server() {
    log_info "Тестирование TURN сервера..."
    
    # Проверка статуса службы
    if ! systemctl is-active --quiet coturn; then
        log_error "TURN сервер не запущен"
        return 1
    fi
    
    # Проверка портов
    if netstat -tuln | grep -q ":${TURN_PORT}"; then
        log_success "TURN сервер слушает порт ${TURN_PORT}"
    else
        log_warning "TURN сервер не слушает порт ${TURN_PORT}"
    fi
    
    if netstat -tuln | grep -q ":${TURN_TLS_PORT}"; then
        log_success "TURN сервер слушает порт ${TURN_TLS_PORT}"
    else
        log_warning "TURN сервер не слушает порт ${TURN_TLS_PORT}"
    fi
    
    # Тест с помощью turnutils
    if command -v turnutils_stunclient &> /dev/null; then
        log_info "Тестирование STUN..."
        turnutils_stunclient ${DOMAIN} 2>/dev/null && log_success "STUN тест прошел успешно" || log_warning "STUN тест не прошел"
    fi
}

# Основная функция
main() {
    log_info "Настройка TURN сервера для MiroTalk"
    log_info "Домен: $DOMAIN"
    
    check_root
    install_coturn
    configure_turn
    create_turn_ssl
    setup_turn_firewall
    start_turn_server
    update_mirotalk_config
    create_turn_monitor
    save_config
    test_turn_server
    
    log_success "TURN сервер настроен успешно!"
    log_info "Пользователь: $TURN_USERNAME"
    log_info "Пароль: $TURN_PASSWORD"
    log_info "Порты: UDP ${TURN_PORT}, TLS ${TURN_TLS_PORT}"
    log_info "Для мониторинга используйте: turn-monitor.sh"
}

# Запуск основной функции
main "$@"

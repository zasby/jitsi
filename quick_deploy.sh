#!/bin/bash

# Быстрое развертывание MiroTalk
# Использование: ./quick_deploy.sh [IP_СЕРВЕРА]

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
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Переменные
SERVER_IP="${1:-}"
DOMAIN="connect.mooz.pro"
SSH_USER="root"
SSH_KEY=""
LOCAL_FILES_DIR="/Users/moozapp/Desktop/project/jitsi"

# Проверка аргументов
check_arguments() {
    if [[ -z "$SERVER_IP" ]]; then
        log_error "Не указан IP адрес сервера"
        log_info "Использование: $0 <IP_СЕРВЕРА> [SSH_KEY_PATH]"
        log_info "Пример: $0 192.168.1.100"
        log_info "Пример: $0 192.168.1.100 ~/.ssh/id_rsa"
        exit 1
    fi
    
    if [[ -n "$2" ]]; then
        SSH_KEY="$2"
    fi
    
    log_info "Сервер: $SERVER_IP"
    log_info "Домен: $DOMAIN"
}

# Проверка SSH соединения
check_ssh_connection() {
    log_info "Проверка SSH соединения с сервером..."
    
    local ssh_cmd="ssh"
    if [[ -n "$SSH_KEY" ]]; then
        ssh_cmd="ssh -i $SSH_KEY"
    fi
    
    if ! $ssh_cmd -o ConnectTimeout=10 -o BatchMode=yes $SSH_USER@$SERVER_IP "echo 'SSH connection successful'" 2>/dev/null; then
        log_error "Не удалось подключиться к серверу по SSH"
        log_info "Убедитесь, что:"
        log_info "1. Сервер доступен по IP $SERVER_IP"
        log_info "2. SSH сервис запущен"
        log_info "3. Пользователь $SSH_USER имеет доступ"
        log_info "4. SSH ключ корректный (если указан)"
        exit 1
    fi
    
    log_success "SSH соединение установлено"
}

# Загрузка файлов на сервер
upload_files() {
    log_info "Загрузка файлов на сервер..."
    
    local ssh_cmd="ssh"
    local scp_cmd="scp"
    
    if [[ -n "$SSH_KEY" ]]; then
        ssh_cmd="ssh -i $SSH_KEY"
        scp_cmd="scp -i $SSH_KEY"
    fi
    
    # Создание временной директории на сервере
    $ssh_cmd $SSH_USER@$SERVER_IP "mkdir -p /tmp/mirotalk-deploy"
    
    # Загрузка основных файлов
    $scp_cmd $LOCAL_FILES_DIR/install_mirotalk.sh $SSH_USER@$SERVER_IP:/tmp/mirotalk-deploy/
    $scp_cmd $LOCAL_FILES_DIR/manage_mirotalk.sh $SSH_USER@$SERVER_IP:/tmp/mirotalk-deploy/
    $scp_cmd $LOCAL_FILES_DIR/setup_turn_server.sh $SSH_USER@$SERVER_IP:/tmp/mirotalk-deploy/
    $scp_cmd $LOCAL_FILES_DIR/docker-compose.yml $SSH_USER@$SERVER_IP:/tmp/mirotalk-deploy/
    $scp_cmd $LOCAL_FILES_DIR/env.template $SSH_USER@$SERVER_IP:/tmp/mirotalk-deploy/
    $scp_cmd $LOCAL_FILES_DIR/Dockerfile $SSH_USER@$SERVER_IP:/tmp/mirotalk-deploy/
    $scp_cmd $LOCAL_FILES_DIR/README_MIROTALK.md $SSH_USER@$SERVER_IP:/tmp/mirotalk-deploy/
    
    # Загрузка nginx конфигурации
    $ssh_cmd $SSH_USER@$SERVER_IP "mkdir -p /tmp/mirotalk-deploy/nginx/conf.d"
    $scp_cmd -r $LOCAL_FILES_DIR/nginx/ $SSH_USER@$SERVER_IP:/tmp/mirotalk-deploy/
    
    log_success "Файлы загружены на сервер"
}

# Установка MiroTalk на сервере
install_mirotalk() {
    log_info "Установка MiroTalk на сервере..."
    
    local ssh_cmd="ssh"
    if [[ -n "$SSH_KEY" ]]; then
        ssh_cmd="ssh -i $SSH_KEY"
    fi
    
    # Копирование файлов в рабочую директорию
    $ssh_cmd $SSH_USER@$SERVER_IP "
        mkdir -p /opt/mirotalk
        cp -r /tmp/mirotalk-deploy/* /opt/mirotalk/
        chmod +x /opt/mirotalk/*.sh
        cd /opt/mirotalk
        ./install_mirotalk.sh
    "
    
    if [[ $? -eq 0 ]]; then
        log_success "MiroTalk установлен успешно"
    else
        log_error "Ошибка при установке MiroTalk"
        exit 1
    fi
}

# Проверка развертывания
verify_deployment() {
    log_info "Проверка развертывания..."
    
    local ssh_cmd="ssh"
    if [[ -n "$SSH_KEY" ]]; then
        ssh_cmd="ssh -i $SSH_KEY"
    fi
    
    # Проверка статуса сервисов
    $ssh_cmd $SSH_USER@$SERVER_IP "
        cd /opt/mirotalk
        docker compose ps
    "
    
    # Проверка доступности HTTP
    log_info "Проверка доступности HTTP..."
    if curl -s -o /dev/null -w "%{http_code}" http://$SERVER_IP | grep -q "301\|302"; then
        log_success "HTTP редирект работает"
    else
        log_warning "HTTP редирект не работает"
    fi
    
    # Проверка доступности HTTPS (если домен настроен)
    log_info "Проверка доступности HTTPS..."
    if curl -s -o /dev/null -w "%{http_code}" https://$DOMAIN | grep -q "200"; then
        log_success "HTTPS доступен по домену $DOMAIN"
    else
        log_warning "HTTPS недоступен по домену $DOMAIN"
        log_info "Убедитесь, что домен настроен в DNS и указывает на IP $SERVER_IP"
    fi
}

# Показ информации о развертывании
show_deployment_info() {
    log_success "Развертывание MiroTalk завершено!"
    echo ""
    log_info "=== Информация о развертывании ==="
    log_info "Сервер: $SERVER_IP"
    log_info "Домен: https://$DOMAIN"
    log_info "HTTP: http://$SERVER_IP (редирект на HTTPS)"
    echo ""
    log_info "=== Управление сервисами ==="
    log_info "SSH подключение: $ssh_cmd $SSH_USER@$SERVER_IP"
    log_info "Переход в директорию: cd /opt/mirotalk"
    log_info "Управление: ./manage_mirotalk.sh [start|stop|restart|status|logs]"
    echo ""
    log_info "=== Полезные команды ==="
    log_info "Просмотр статуса: ./manage_mirotalk.sh status"
    log_info "Просмотр логов: ./manage_mirotalk.sh logs"
    log_info "Создание бэкапа: ./manage_mirotalk.sh backup"
    log_info "Мониторинг: ./manage_mirotalk.sh monitor"
    echo ""
    log_warning "=== Важно ==="
    log_warning "Убедитесь, что домен $DOMAIN настроен в DNS и указывает на IP $SERVER_IP"
    log_warning "SSL сертификаты будут получены автоматически через Let's Encrypt"
    log_warning "Для улучшения P2P соединений рекомендуется настроить TURN сервер:"
    log_warning "  ./setup_turn_server.sh"
}

# Основная функция
main() {
    log_info "Начинаем быстрое развертывание MiroTalk"
    log_info "Домен: $DOMAIN"
    
    check_arguments
    check_ssh_connection
    upload_files
    install_mirotalk
    verify_deployment
    show_deployment_info
    
    log_success "Развертывание завершено успешно!"
}

# Запуск основной функции
main "$@"


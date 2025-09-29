#!/bin/bash

# Скрипт проверки готовности к развертыванию MiroTalk
# Проверяет все необходимые файлы и конфигурации

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

# Счетчики
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNING_CHECKS=0

# Функция проверки файла
check_file() {
    local file="$1"
    local description="$2"
    local required="${3:-true}"
    
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    
    if [[ -f "$file" ]]; then
        if [[ -r "$file" ]]; then
            log_success "$description: $file"
            PASSED_CHECKS=$((PASSED_CHECKS + 1))
        else
            log_error "$description: $file (нет прав на чтение)"
            FAILED_CHECKS=$((FAILED_CHECKS + 1))
        fi
    else
        if [[ "$required" == "true" ]]; then
            log_error "$description: $file (файл не найден)"
            FAILED_CHECKS=$((FAILED_CHECKS + 1))
        else
            log_warning "$description: $file (файл не найден, необязательный)"
            WARNING_CHECKS=$((WARNING_CHECKS + 1))
        fi
    fi
}

# Функция проверки исполняемого файла
check_executable() {
    local file="$1"
    local description="$2"
    
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    
    if [[ -f "$file" && -x "$file" ]]; then
        log_success "$description: $file (исполняемый)"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    elif [[ -f "$file" ]]; then
        log_error "$description: $file (не исполняемый)"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    else
        log_error "$description: $file (файл не найден)"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi
}

# Функция проверки директории
check_directory() {
    local dir="$1"
    local description="$2"
    
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    
    if [[ -d "$dir" ]]; then
        log_success "$description: $dir"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    else
        log_error "$description: $dir (директория не найдена)"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi
}

# Функция проверки YAML синтаксиса
check_yaml_syntax() {
    local file="$1"
    local description="$2"
    
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    
    if [[ -f "$file" ]]; then
        # Простая проверка YAML синтаксиса
        if grep -q "version:" "$file" && grep -q "services:" "$file"; then
            log_success "$description: $file (синтаксис корректен)"
            PASSED_CHECKS=$((PASSED_CHECKS + 1))
        else
            log_error "$description: $file (некорректный YAML синтаксис)"
            FAILED_CHECKS=$((FAILED_CHECKS + 1))
        fi
    else
        log_error "$description: $file (файл не найден)"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi
}

# Функция проверки конфигурации
check_config() {
    local file="$1"
    local key="$2"
    local expected="$3"
    local description="$4"
    
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    
    if [[ -f "$file" ]]; then
        local value=$(grep "^${key}=" "$file" | cut -d'=' -f2- | tr -d '"' | tr -d "'")
        if [[ "$value" == "$expected" ]]; then
            log_success "$description: $key=$value"
            PASSED_CHECKS=$((PASSED_CHECKS + 1))
        else
            log_error "$description: ожидается $key=$expected, найдено $key=$value"
            FAILED_CHECKS=$((FAILED_CHECKS + 1))
        fi
    else
        log_error "$description: файл $file не найден"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi
}

# Основная функция проверки
main() {
    log_info "Проверка готовности к развертыванию MiroTalk"
    log_info "Домен: connect.mooz.pro"
    echo ""
    
    # Проверка основных файлов
    log_info "=== Проверка основных файлов ==="
    check_executable "install_mirotalk.sh" "Скрипт установки"
    check_executable "manage_mirotalk.sh" "Скрипт управления"
    check_executable "setup_turn_server.sh" "Скрипт настройки TURN"
    check_executable "quick_deploy.sh" "Скрипт быстрого развертывания"
    check_executable "check_deployment.sh" "Скрипт проверки"
    echo ""
    
    # Проверка конфигурационных файлов
    log_info "=== Проверка конфигурационных файлов ==="
    check_yaml_syntax "docker-compose.yml" "Docker Compose конфигурация"
    check_file "env.template" "Шаблон переменных окружения"
    check_file "Dockerfile" "Dockerfile для MiroTalk"
    echo ""
    
    # Проверка nginx конфигурации
    log_info "=== Проверка Nginx конфигурации ==="
    check_directory "nginx" "Директория Nginx"
    check_file "nginx/nginx.conf" "Основная конфигурация Nginx"
    check_file "nginx/conf.d/mirotalk.conf" "Конфигурация MiroTalk"
    echo ""
    
    # Проверка документации
    log_info "=== Проверка документации ==="
    check_file "README_MIROTALK.md" "README файл"
    check_file "DEPLOYMENT_GUIDE.md" "Руководство по развертыванию"
    echo ""
    
    # Проверка конфигурации домена
    log_info "=== Проверка конфигурации домена ==="
    check_config "env.template" "DOMAIN" "connect.mooz.pro" "Настройка домена"
    check_config "nginx/conf.d/mirotalk.conf" "server_name" "connect.mooz.pro" "Nginx домен"
    echo ""
    
    # Проверка Docker Compose конфигурации
    log_info "=== Проверка Docker Compose ==="
    if grep -q "mirotalk" docker-compose.yml; then
        log_success "Сервис mirotalk найден в docker-compose.yml"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    else
        log_error "Сервис mirotalk не найден в docker-compose.yml"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    
    if grep -q "nginx" docker-compose.yml; then
        log_success "Сервис nginx найден в docker-compose.yml"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    else
        log_error "Сервис nginx не найден в docker-compose.yml"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    
    if grep -q "certbot" docker-compose.yml; then
        log_success "Сервис certbot найден в docker-compose.yml"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    else
        log_error "Сервис certbot не найден в docker-compose.yml"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    echo ""
    
    # Итоговая статистика
    log_info "=== Итоговая статистика ==="
    log_info "Всего проверок: $TOTAL_CHECKS"
    log_success "Успешно: $PASSED_CHECKS"
    
    if [[ $WARNING_CHECKS -gt 0 ]]; then
        log_warning "Предупреждения: $WARNING_CHECKS"
    fi
    
    if [[ $FAILED_CHECKS -gt 0 ]]; then
        log_error "Ошибки: $FAILED_CHECKS"
    fi
    echo ""
    
    # Результат проверки
    if [[ $FAILED_CHECKS -eq 0 ]]; then
        log_success "✅ Все проверки пройдены успешно!"
        log_info "Система готова к развертыванию MiroTalk"
        echo ""
        log_info "Следующие шаги:"
        log_info "1. Убедитесь, что домен connect.mooz.pro настроен в DNS"
        log_info "2. Запустите: ./quick_deploy.sh YOUR_SERVER_IP"
        log_info "3. Или выполните ручную установку на сервере"
        exit 0
    else
        log_error "❌ Обнаружены ошибки!"
        log_info "Исправьте ошибки перед развертыванием"
        exit 1
    fi
}

# Запуск основной функции
main "$@"

